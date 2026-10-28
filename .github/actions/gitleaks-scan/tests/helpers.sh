#!/usr/bin/env bash
# Shared assertions for the hand-rolled test harness in this directory.
TESTS_FAILED=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $msg (got [$actual], want [$expected])" >&2
    TESTS_FAILED=1
    return 1
  fi
  return 0
}

assert_success() {
  local code="$1" msg="$2"
  if [ "$code" -ne 0 ]; then
    echo "FAIL: $msg (expected exit 0, got $code)" >&2
    TESTS_FAILED=1
    return 1
  fi
  return 0
}

assert_failure() {
  local code="$1" msg="$2"
  if [ "$code" -eq 0 ]; then
    echo "FAIL: $msg (expected non-zero exit, got 0)" >&2
    TESTS_FAILED=1
    return 1
  fi
  return 0
}
