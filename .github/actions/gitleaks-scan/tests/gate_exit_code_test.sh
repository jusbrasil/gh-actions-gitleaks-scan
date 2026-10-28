#!/usr/bin/env bash
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_EXIT_SH="${ACTION_DIR}/gate-exit-code.sh"
GATE_WORKFLOW="${ACTION_DIR}/../../workflows/secret-scan-gate.yml"

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

test_report_mode_never_fails_even_with_fail_on_finding_false() {
  assert_eq "$(gate_code 42 report false)" "0" "report mode must not fail on a finding with fail-on-finding false"
}

test_only_exit_42_is_suppressed() {
  local code
  for code in 2 3 126 127 255; do
    assert_eq "$(gate_code "$code" gate false)" "$code" "exit $code must propagate even with fail-on-finding false"
  done
}

test_stdout_is_only_the_code_when_warning_is_emitted() {
  local out
  out=$("$GATE_EXIT_SH" 42 gate false 2>/dev/null)
  assert_eq "$out" "0" "stdout must be exactly the exit code, the warning goes to stderr"
}

test_action_wires_fail_on_finding_input_and_env() {
  local action="${ACTION_DIR}/action.yml"
  grep -q '^  fail-on-finding:$' "$action"
  assert_success "$?" "action.yml must declare the fail-on-finding input"
  grep -A1 '^  fail-on-finding:$' "$action" | grep -q 'default: "true"'
  assert_success "$?" "fail-on-finding must default to true in action.yml"
  grep -q 'FAIL_ON_FINDING: ${{ inputs.fail-on-finding }}' "$action"
  assert_success "$?" "the gate step must pass inputs.fail-on-finding via env"
}

test_gate_workflow_wires_fail_on_finding_default_true() {
  grep -A2 '^      fail-on-finding:$' "$GATE_WORKFLOW" | grep -q 'type: boolean'
  assert_success "$?" "the gate workflow input must be boolean"
  grep -A3 '^      fail-on-finding:$' "$GATE_WORKFLOW" | grep -q 'default: true'
  assert_success "$?" "the gate workflow input must default to true"
  grep -q 'fail-on-finding: ${{ inputs.fail-on-finding }}' "$GATE_WORKFLOW"
  assert_success "$?" "the gate workflow must forward the input to the action"
}
