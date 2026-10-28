#!/usr/bin/env bash
_start_stub_token_server() {
  local port="$1"
  python3 -c "
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'value': 'FAKE.JWT.TOKEN'}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $port), H).serve_forever()
" >/tmp/stub_token_server.log 2>&1 &
  echo $!
}

test_request_oidc_token_reports_absence_cleanly() {
  (
    unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
    source ../report-relay.sh
    request_oidc_token "test-audience"
  )
  assert_failure "$?" "missing ACTIONS_ID_TOKEN_REQUEST_TOKEN must be a clean exit-1 signal, not an unbound-variable crash"
}

test_request_oidc_token_fetches_and_masks() {
  local port=18765
  local pid
  pid=$(_start_stub_token_server "$port")
  sleep 0.5

  local out
  out=$(
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN="fake-runner-token"
    export ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/?"
    source ../report-relay.sh
    set +e  # report-relay.sh's own set -euo pipefail must not leak into this subshell
    request_oidc_token "test-audience" 2>/tmp/oidc_stderr
  )
  # No `wait "$pid"` here (round-2 review fix): the stub server was started
  # in a background subshell via command substitution, so it's reparented —
  # this shell is not its parent, and `wait` on a non-child PID returns 127
  # and, worse, does so under whatever `set -e` the sourced library left
  # active, aborting the test before the assertions below ever run.
  kill "$pid" 2>/dev/null

  assert_eq "$out" "FAKE.JWT.TOKEN" "token value is extracted from the stub response"
  if ! grep -q "::add-mask::FAKE.JWT.TOKEN" /tmp/oidc_stderr; then
    echo "FAIL: ::add-mask:: was not emitted for the token" >&2
    TESTS_FAILED=1
  fi
}
