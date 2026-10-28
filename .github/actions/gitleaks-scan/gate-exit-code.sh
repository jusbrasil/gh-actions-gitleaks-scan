#!/usr/bin/env bash
# gate-exit-code.sh — decides the gate step's exit code from gitleaks' exit
# code. Prints the code on stdout; any warning goes to stderr.
#
# Usage: gate-exit-code.sh <gitleaks-exit-code> <mode> <fail-on-finding>
#
# - mode "report": always 0 (the report job never fails on a finding).
# - gitleaks exit 42 (new finding) with fail-on-finding exactly "false": 0,
#   with a warning. Observation mode: findings are still printed, redacted,
#   by gitleaks itself, but do not fail the job.
# - anything else: the gitleaks exit code unchanged. Fail-closed on purpose:
#   an empty or mistyped fail-on-finding keeps the gate blocking, and an
#   execution error (exit 1) is never masked, since a scan that did not run
#   is not "no findings".
set -euo pipefail

status="${1:-}"
mode="${2:-}"
fail_on_finding="${3:-true}"

if ! [[ "$status" =~ ^[0-9]+$ ]]; then
  echo "1"
  exit 0
fi

if [ "$mode" = "report" ]; then
  echo "0"
elif [ "$status" = "42" ] && [ "$fail_on_finding" = "false" ]; then
  echo "::warning::gitleaks found secrets, but fail-on-finding is false: not failing this job" >&2
  echo "0"
else
  echo "$status"
fi
