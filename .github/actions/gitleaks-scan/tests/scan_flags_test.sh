#!/usr/bin/env bash
# scan.sh needs a real gitleaks binary and a real git repo to run end to end
# — that integration-level check happens in Task 7's live dispatch test.
# This test only exercises the pure bash flag-building logic in isolation by
# asserting against a real gitleaks run (gitleaks is required for this test
# — install it first via Task 4's install-gitleaks.sh in CI; skip locally if
# `command -v gitleaks` fails, printing a warning rather than a false FAIL).
#
# Fixed by round-2 review (recurrence of the same bug the round-1 review
# already found and fixed in scan_range_test.sh, but this file was written
# separately and missed it): resolve scan.sh via an absolute,
# $BASH_SOURCE-relative path — a mktemp -d directory's "../../../../scan.sh"
# never resolves to anything real.
SCAN_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scan.sh"

test_scan_omits_baseline_flag_when_file_missing() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "SKIP: gitleaks not installed locally, run in CI where install-gitleaks.sh (Task 4) has run" >&2
    return 0
  fi
  local dir output code
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo "clean file" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm "clean commit"
  output=$(
    cd "$dir"
    export EVENT_NAME=workflow_dispatch AFTER=HEAD REPORT_PATH="$dir/report.json"
    export BASELINE_PATH="$dir/does-not-exist-baseline.json"
    "$SCAN_SH" 2>&1
  )
  code=$?
  assert_success "$code" "missing baseline file must not abort the scan (flag omitted, not passed pointing nowhere)"
  # assert_success alone proves nothing here: verified empirically against
  # the locally-installed gitleaks 8.30.1 that --baseline-path pointing at a
  # missing/malformed file does NOT make gitleaks exit non-zero either way —
  # it just logs an ERR-level "Could not load baseline..." line and still
  # reports "no leaks found", exit 0. So this test must assert on gitleaks'
  # own diagnostic output, which appears ONLY when --baseline-path was
  # actually passed pointing at a path that doesn't exist — that's the
  # signal that distinguishes "guard omitted the flag" from "guard is
  # broken/reverted and passed it anyway".
  if echo "$output" | grep -qi "could not load baseline"; then
    echo "FAIL: gitleaks logged 'Could not load baseline' — scan.sh passed --baseline-path pointing at a missing file instead of omitting the flag" >&2
    TESTS_FAILED=1
  fi
}

test_scan_aborts_on_malformed_baseline_content() {
  # A baseline file that EXISTS but is not a valid JSON array must abort
  # loudly, before gitleaks even runs — without this check, gitleaks itself
  # silently treats an unparseable baseline the same as a missing one (same
  # "Could not load baseline" / exit-0 behavior verified above), which would
  # quietly disable the baseline's suppression instead of failing the scan.
  # Doesn't need a local gitleaks install: the jq validation this test
  # exercises runs, and aborts, before scan.sh ever invokes gitleaks.
  local dir code
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo "clean file" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm "clean commit"
  echo "not valid json at all" > "$dir/gitleaks-baseline.json"
  (
    cd "$dir"
    export EVENT_NAME=workflow_dispatch AFTER=HEAD REPORT_PATH="$dir/report.json"
    export BASELINE_PATH="$dir/gitleaks-baseline.json"
    "$SCAN_SH" >/dev/null 2>&1
  )
  code=$?
  assert_failure "$code" "malformed-but-present baseline must abort the scan, not be silently treated as absent"
}

test_scan_aborts_on_missing_config_path() {
  # Unlike BASELINE_PATH, CONFIG_PATH's own default is "" ("not
  # customizing"). A non-empty value is the caller explicitly asking for a
  # specific file, so — unlike a fresh adopter's not-yet-created baseline —
  # a missing file here is always a misconfiguration, and must abort loudly
  # instead of silently falling through to gitleaks' embedded ruleset.
  local dir code
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo "clean file" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm "clean commit"
  (
    cd "$dir"
    export EVENT_NAME=workflow_dispatch AFTER=HEAD REPORT_PATH="$dir/report.json"
    export CONFIG_PATH="$dir/does-not-exist.toml"
    "$SCAN_SH" >/dev/null 2>&1
  )
  code=$?
  assert_failure "$code" "explicitly-set but missing config-path must abort the scan, not fall through to default rules"
}
