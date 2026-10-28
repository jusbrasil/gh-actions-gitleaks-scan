#!/usr/bin/env bash
_start_stub_relay() {
  local port="$1" behavior="$2"
  python3 -c "
import http.server, json, sys
behavior = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    hits = 0
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        # Records which path was actually hit — round-3 review found the
        # oversized-item test below didn't check this, so it passed
        # identically whether the item went to /v1/findings (correct) or
        # /v1/findings:batch (wrong — the real relay 400s the WHOLE batch
        # for one oversized item, internal/httpapi/batch.go).
        with open('/tmp/stub_relay_last_path.txt', 'w') as f:
            f.write(self.path)
        ctype = self.headers.get('Content-Type', '')
        if ctype != 'application/json':
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error':'invalid_payload'}).encode())
            return
        if behavior == 'created':
            self.send_response(201)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
        elif behavior == 'run_report_ok':
            # /v1/run-report never responds 201 (that's the singular
            # /v1/findings endpoint's code) — it responds 202 for a new
            # report or 200 {"status":"duplicate"} for a repeat
            # (internal/httpapi/runreport.go). A stub that answers 201 here
            # makes post_run_report's own 'case 200|202' correctly reject it,
            # which used to look like a test failure but was actually the
            # stub being wrong, not the code under test.
            self.send_response(202)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
        elif behavior == 'batch_partial':
            self.send_response(202)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'results':[{'index':0,'status':'created'},{'index':1,'status':'invalid','error':'invalid_payload'}]}).encode())
        elif behavior == 'batch_unavailable_then_singular_created':
            # index 0 lands, index 1 comes back "unavailable" (spec §6.4:
            # distinct from "invalid" — must be retried, not just counted).
            # A retry of that one item hits POST /v1/findings (singular,
            # not the batch endpoint again) and must succeed.
            if self.path == '/v1/findings':
                self.send_response(201)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
            else:
                self.send_response(202)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'results':[{'index':0,'status':'created'},{'index':1,'status':'unavailable','error':'gcs_unavailable'}]}).encode())
        elif behavior == 'rate_limited_once':
            H.hits += 1
            if H.hits == 1:
                self.send_response(429)
                self.send_header('Retry-After', '1')
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error':'rate_limited'}).encode())
            else:
                self.send_response(201)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[2])), H).serve_forever()
" "$behavior" "$port" >/tmp/stub_relay.log 2>&1 &
  echo $!
}

_fake_item() {
  jq -cn --arg n "$1" '{commit:("0"*39+$n), file:"f", start_line:1, end_line:1, start_column:1, end_column:2, rule:"r", secret_sha256:("0"*63+$n)}'
}

test_post_run_report_sends_content_type_header_and_gets_202() {
  local port=18766 pid
  pid=$(_start_stub_relay "$port" run_report_ok)
  sleep 0.5
  source ../report-relay.sh
  set +e  # report-relay.sh's own set -euo pipefail must not leak into this test
  local out
  out=$(post_run_report "http://127.0.0.1:$port" "fake-token" "success" 0 "$(printf '%040d' 1)" "$((SECONDS + 30))")
  kill "$pid" 2>/dev/null  # no `wait`: the stub is reparented by the command substitution that started it, so this shell is never its parent
  echo "$out" | grep -q "unavailable_count=0" || { echo "FAIL: expected unavailable_count=0, got: $out" >&2; TESTS_FAILED=1; }
}

test_post_findings_batch_retries_429_and_succeeds() {
  local port=18767 pid
  pid=$(_start_stub_relay "$port" rate_limited_once)
  sleep 0.5
  source ../report-relay.sh
  set +e
  local items
  items=$(jq -cs '.' <(_fake_item 1))
  local out
  out=$(post_findings_batch "http://127.0.0.1:$port" "fake-token" "$items" "$((SECONDS + 30))")
  kill "$pid" 2>/dev/null
  echo "$out" | grep -q "unavailable_count=0" || { echo "FAIL: 429 then 201 must count as fully delivered, got: $out" >&2; TESTS_FAILED=1; }
}

test_post_findings_batch_counts_invalid_items_as_unavailable() {
  local port=18768 pid
  pid=$(_start_stub_relay "$port" batch_partial)
  sleep 0.5
  source ../report-relay.sh
  set +e
  local items
  items=$(jq -cs '.' <(_fake_item 1) <(_fake_item 2))
  local out
  out=$(post_findings_batch "http://127.0.0.1:$port" "fake-token" "$items" "$((SECONDS + 30))")
  kill "$pid" 2>/dev/null
  echo "$out" | grep -q "unavailable_count=1" || { echo "FAIL: one 'invalid' item in results[] must count toward unavailable_count, got: $out" >&2; TESTS_FAILED=1; }
}

test_post_findings_batch_retries_unavailable_items_via_singular_endpoint() {
  # Post-PR-review fix: "unavailable" (transient server-side storage
  # failure per item) must be retried once via the singular endpoint, not
  # just counted like "invalid" (permanent, client-side bad data).
  local port=18770 pid
  pid=$(_start_stub_relay "$port" batch_unavailable_then_singular_created)
  sleep 0.5
  source ../report-relay.sh
  set +e
  local items
  items=$(jq -cs '.' <(_fake_item 1) <(_fake_item 2))
  local out
  out=$(post_findings_batch "http://127.0.0.1:$port" "fake-token" "$items" "$((SECONDS + 30))")
  kill "$pid" 2>/dev/null
  echo "$out" | grep -q "unavailable_count=0" || { echo "FAIL: a retried 'unavailable' item that succeeds (201) on retry must not count toward unavailable_count, got: $out" >&2; TESTS_FAILED=1; }
}

test_post_findings_batch_routes_oversized_item_to_singular_endpoint() {
  # spec §6.2/§11: an item >1024 bytes must go to POST /v1/findings, not be
  # dropped, not sent to /v1/findings:batch (which the real relay would 400
  # for the WHOLE chunk, internal/httpapi/batch.go), and not crash the loop.
  # "created" (201) is the singular endpoint's real success code.
  rm -f /tmp/stub_relay_last_path.txt
  local port=18769 pid
  pid=$(_start_stub_relay "$port" created)
  sleep 0.5
  source ../report-relay.sh
  set +e
  local huge_file oversized
  huge_file=$(python3 -c "print('a' * 2000)")
  oversized=$(jq -cn --arg f "$huge_file" '[{commit:("0"*40), file:$f, start_line:1, end_line:1, start_column:1, end_column:2, rule:"r", secret_sha256:("0"*64)}]')
  local out
  out=$(post_findings_batch "http://127.0.0.1:$port" "fake-token" "$oversized" "$((SECONDS + 30))")
  kill "$pid" 2>/dev/null
  echo "$out" | grep -q "unavailable_count=0" || { echo "FAIL: an oversized item routed to the singular endpoint and accepted (201) must count as delivered, got: $out" >&2; TESTS_FAILED=1; }
  local hit_path
  hit_path=$(cat /tmp/stub_relay_last_path.txt 2>/dev/null)
  assert_eq "$hit_path" "/v1/findings" "oversized item must hit the singular endpoint, not /v1/findings:batch (round-3 review: an earlier version of this test would have passed even if the item went to the wrong endpoint)"
}

test_chunk_items_splits_at_max() {
  source ../report-relay.sh
  set +e
  local items
  items=$(python3 -c "
import json
print(json.dumps([{'commit':'0'*40,'file':'f','start_line':1,'end_line':1,'start_column':1,'end_column':2,'rule':'r','secret_sha256':'0'*64} for _ in range(750)]))
")
  local n_chunks
  n_chunks=$(chunk_items "$items" 500 | wc -l | tr -d ' ')
  assert_eq "$n_chunks" "2" "750 items must split into exactly 2 chunks of <=500"
  local first_chunk_len
  first_chunk_len=$(chunk_items "$items" 500 | sed -n 1p | jq 'length')
  assert_eq "$first_chunk_len" "500" "first chunk has exactly 500 items, not nested arrays"
}
