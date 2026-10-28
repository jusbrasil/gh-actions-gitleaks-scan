#!/usr/bin/env bash
GATE_EXIT_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate-exit-code.sh"

gate_code() {
  "$GATE_EXIT_SH" "$@" 2>/dev/null
}

test_default_gate_propagates_finding() {
  assert_eq "$(gate_code 42 gate true)" "42" "a finding must fail the gate by default"
}

test_clean_scan_is_zero() {
  assert_eq "$(gate_code 0 gate true)" "0" "a clean scan exits 0"
  assert_eq "$(gate_code 0 gate false)" "0" "a clean scan exits 0 with fail-on-finding false"
}

test_fail_on_finding_false_suppresses_finding() {
  assert_eq "$(gate_code 42 gate false)" "0" "fail-on-finding=false must not fail on a finding"
}

test_fail_on_finding_false_warns() {
  local err
  err=$("$GATE_EXIT_SH" 42 gate false 2>&1 >/dev/null)
  case "$err" in
    *"::warning::"*) ;;
    *) echo "FAIL: suppressed finding must leave a warning annotation (got [$err])" >&2; TESTS_FAILED=1 ;;
  esac
}

test_fail_on_finding_false_does_not_mask_execution_error() {
  assert_eq "$(gate_code 1 gate false)" "1" "an execution error must still fail, a scan that did not run is not clean"
}

test_only_exact_false_disables_the_gate() {
  local v
  for v in "" "False" "FALSE" "0" "no" "true" "yes"; do
    assert_eq "$(gate_code 42 gate "$v")" "42" "fail-on-finding [$v] must keep the gate blocking"
  done
}

test_missing_fail_on_finding_arg_keeps_gate_blocking() {
  assert_eq "$("$GATE_EXIT_SH" 42 gate 2>/dev/null)" "42" "omitted fail-on-finding must keep the gate blocking"
}

test_empty_or_unknown_mode_is_treated_as_gate() {
  assert_eq "$(gate_code 42 "" true)" "42" "empty mode must behave like gate"
  assert_eq "$(gate_code 42 typo true)" "42" "unknown mode must behave like gate"
}

test_report_mode_never_fails() {
  assert_eq "$(gate_code 42 report true)" "0" "report mode must not fail on a finding"
  assert_eq "$(gate_code 1 report true)" "0" "report mode must not fail on an execution error"
}

test_non_numeric_status_fails() {
  assert_eq "$(gate_code "" gate false)" "1" "empty status must fail"
  assert_eq "$(gate_code abc gate false)" "1" "non-numeric status must fail"
}
