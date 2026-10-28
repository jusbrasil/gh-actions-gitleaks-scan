#!/usr/bin/env bash
# Tests for derive-findings.sh.

_golden_secret_b64() {
  awk -F'\t' -v name="$1" '$1==name {print $2}' ../testdata/golden-vectors.tsv
}
_golden_hash() {
  awk -F'\t' -v name="$1" '$1==name {print $3}' ../testdata/golden-vectors.tsv
}

# Builds a report.json/raw.json fixture pair and runs the script, printing
# ONLY the script's own stdout (no diagnostic text mixed in) so callers can
# safely pipe it into jq. Returns the script's real exit code.
_run_derive() {
  local secret_b64="$1" commit="${2:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
  local dir report raw secret_file
  dir=$(mktemp -d)
  report="$dir/report.json"
  raw="$dir/raw.json"
  secret_file="$dir/secret.b64"
  echo "$secret_b64" > "$secret_file"
  echo '[{"Fingerprint":"abc:file.env:aws-key:1","StartColumn":5,"EndColumn":20,"Commit":"IGNORED-BY-DESIGN","File":"file.env","RuleID":"aws-key","StartLine":1,"EndLine":1}]' > "$report"
  jq -n --rawfile secret_b64 "$secret_file" \
    '[{Fingerprint: "abc:file.env:aws-key:1", StartColumn: 5, EndColumn: 20, Secret: ($secret_b64 | rtrimstr("\n") | @base64d)}]' \
    > "$raw"
  ../derive-findings.sh "$report" "$raw" "$commit"
}

test_derive_findings_simple_secret() {
  local out code
  out=$(_run_derive "$(_golden_secret_b64 simple)" 2>/tmp/derive_stderr_simple)
  code=$?
  assert_success "$code" "simple secret must derive successfully"
  local got_hash
  got_hash=$(echo "$out" | jq -r '.[0].secret_sha256')
  assert_eq "$got_hash" "$(_golden_hash simple)" "simple secret hashes correctly"
  local got_commit
  got_commit=$(echo "$out" | jq -r '.[0].commit')
  assert_eq "$got_commit" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "commit field comes from the 3rd argument, never gitleaks' own .Commit"
}

test_derive_findings_trailing_newline_preserved() {
  # The fixture goes through base64 specifically so the trailing \n survives
  # the shell/JSON round-trip intact — this is the regression the whole
  # test exists to catch (spec §6.1: command substitution strips it).
  local out
  out=$(_run_derive "$(_golden_secret_b64 trailing_newline)")
  local got_hash
  got_hash=$(echo "$out" | jq -r '.[0].secret_sha256')
  assert_eq "$got_hash" "$(_golden_hash trailing_newline)" "trailing-newline secret preserves the newline byte in the hash"
}

test_derive_findings_utf8() {
  local out
  out=$(_run_derive "$(_golden_secret_b64 utf8)")
  local got_hash
  got_hash=$(echo "$out" | jq -r '.[0].secret_sha256')
  assert_eq "$got_hash" "$(_golden_hash utf8)" "utf8 secret hashes correctly"
}

test_derive_findings_double_quotes() {
  local out
  out=$(_run_derive "$(_golden_secret_b64 double_quotes)")
  local got_hash
  got_hash=$(echo "$out" | jq -r '.[0].secret_sha256')
  assert_eq "$got_hash" "$(_golden_hash double_quotes)" "secret containing double quotes hashes correctly"
}

test_derive_findings_empty_correlation_aborts() {
  local dir report raw
  dir=$(mktemp -d)
  report="$dir/report.json"
  raw="$dir/raw.json"
  echo '[{"Fingerprint":"nomatch:file.env:rule:1","StartColumn":1,"EndColumn":2,"Commit":"c","File":"f","RuleID":"r","StartLine":1,"EndLine":1}]' > "$report"
  echo '[]' > "$raw"
  ../derive-findings.sh "$report" "$raw" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >/dev/null 2>&1
  assert_failure "$?" "empty correlation must abort, never hash empty string"
}

test_derive_findings_empty_secret_string_aborts() {
  _run_derive "$(echo -n "" | base64)" >/dev/null 2>&1
  assert_failure "$?" "empty-string Secret must abort via the sentinel-hash check, not just the null/missing check"
}

test_derive_findings_disambiguates_by_column() {
  local dir report raw
  dir=$(mktemp -d)
  report="$dir/report.json"
  raw="$dir/raw.json"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1},
    {Fingerprint:"c:f:r:1", StartColumn:10, EndColumn:15, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1}
  ]' > "$report"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Secret:"first-secret"},
    {Fingerprint:"c:f:r:1", StartColumn:10, EndColumn:15, Secret:"second-secret"}
  ]' > "$raw"
  local out
  out=$(../derive-findings.sh "$report" "$raw" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
  local count
  count=$(echo "$out" | jq 'length')
  assert_eq "$count" "2" "two findings on the same fingerprint, disambiguated by column, both produce items"
  local h1 h2
  h1=$(echo "$out" | jq -r '.[0].secret_sha256')
  h2=$(echo "$out" | jq -r '.[1].secret_sha256')
  if [ "$h1" = "$h2" ]; then
    echo "FAIL: the two distinct secrets on the same line hashed identically" >&2
    TESTS_FAILED=1
  fi
}

test_derive_findings_truncates_to_max_before_correlating() {
  # post-PR-review fix, 3rd round: the 4th arg bounds correlation work to
  # the first N report entries, not just the OUTPUT. Two findings here;
  # max=1 must correlate/return only the first, and must NOT abort trying
  # to correlate the second (which this fixture deliberately gives no
  # matching raw entry for for entries beyond the 1st — proving the 2nd
  # entry was never even looked at).
  local dir report raw
  dir=$(mktemp -d)
  report="$dir/report.json"
  raw="$dir/raw.json"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1},
    {Fingerprint:"c:f:r:2", StartColumn:10, EndColumn:15, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1}
  ]' > "$report"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Secret:"first-secret"}
  ]' > "$raw"
  local out code
  out=$(../derive-findings.sh "$report" "$raw" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 1)
  code=$?
  assert_success "$code" "truncated correlation must succeed even though finding #2 has no raw match"
  local count
  count=$(echo "$out" | jq 'length')
  assert_eq "$count" "1" "max=1 must return exactly 1 item, not 2"
}

test_derive_findings_max_zero_means_unbounded() {
  local dir report raw
  dir=$(mktemp -d)
  report="$dir/report.json"
  raw="$dir/raw.json"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1},
    {Fingerprint:"c:f:r:2", StartColumn:10, EndColumn:15, Commit:"ignored", File:"f", RuleID:"r", StartLine:1, EndLine:1}
  ]' > "$report"
  jq -n '[
    {Fingerprint:"c:f:r:1", StartColumn:1, EndColumn:5, Secret:"first-secret"},
    {Fingerprint:"c:f:r:2", StartColumn:10, EndColumn:15, Secret:"second-secret"}
  ]' > "$raw"
  local out
  out=$(../derive-findings.sh "$report" "$raw" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 0)
  local count
  count=$(echo "$out" | jq 'length')
  assert_eq "$count" "2" "max=0 (or omitted) must correlate everything, unbounded"
}
