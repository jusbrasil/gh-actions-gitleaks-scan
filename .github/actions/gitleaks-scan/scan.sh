#!/usr/bin/env bash
# scan.sh — Passada 1 (spec §5, §9): runs gitleaks fully redacted
# (--redact=100), decides scan scope per event via lib-scan-range.sh, and
# exits with gitleaks' own exit code (0 clean / 42 new finding / 1 execution
# error). This exit code IS the caller's signal — secret-scan-gate.yml lets
# it propagate directly as the job's exit code; secret-scan-report.yml
# captures it into a local shell variable instead (spec §7) and never
# propagates it as a job exit code or GITHUB_OUTPUT.
#
# Reads its parameters from environment variables (not positional args) —
# there are 8 of them, and named env vars avoid the quoting/ordering
# mistakes a 9-positional-argument call site invites.
#
# Required: EVENT_NAME, AFTER, REPORT_PATH
# Optional (empty string if not applicable to the event): BEFORE, BASE_REF,
#   BASE_SHA, DEFAULT_BRANCH, BASELINE_PATH, CONFIG_PATH
#
# Sets SCAN_RANGE_FALLBACK=0|1 as a side effect in the CALLING shell only if
# this script is sourced, not executed — when executed as a subprocess (the
# normal case), read the same information from stderr line
# "SCAN_RANGE_FALLBACK=<0|1>", emitted right before the gitleaks invocation.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-scan-range.sh
source "${script_dir}/lib-scan-range.sh"

: "${EVENT_NAME:?EVENT_NAME obrigatório}"
: "${AFTER:?AFTER obrigatório}"
: "${REPORT_PATH:?REPORT_PATH obrigatório}"
BEFORE="${BEFORE:-}"
BASE_REF="${BASE_REF:-}"
BASE_SHA="${BASE_SHA:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
BASELINE_PATH="${BASELINE_PATH:-}"
CONFIG_PATH="${CONFIG_PATH:-}"

range_output=$(compute_log_opts "$EVENT_NAME" "$BEFORE" "$AFTER" "$BASE_REF" "$BASE_SHA" "$DEFAULT_BRANCH")
SCAN_RANGE_FALLBACK=$(echo "$range_output" | sed -n 1p)
log_opts=$(echo "$range_output" | sed -n 2p)
echo "SCAN_RANGE_FALLBACK=${SCAN_RANGE_FALLBACK}" >&2
# "::" delimiter, not "=" — log_opts itself can contain spaces (e.g.
# "--no-merges sha1..sha2"); report mode (Task 8) reuses this exact value
# for Passada 2, so both passes scan the identical range.
echo "SCAN_LOG_OPTS::${log_opts}" >&2

baseline_args=()
# Missing baseline is treated as "no baseline" — spec §6.5's design choice,
# not a gitleaks quirk to work around: gitleaks itself, when pointed at a
# nonexistent --baseline-path, logs "Could not load baseline" and reports
# "no leaks found" (exit 0), it does NOT error (verified empirically against
# 8.30.1 — corrects an earlier, wrong assumption in this file's own history
# that it errors). Omitting the flag entirely when the file is absent keeps
# that same "no baseline" behavior without depending on gitleaks' own
# silent-ignore path, which is exactly what a MALFORMED (present but
# invalid) baseline would otherwise fall into unnoticed — that case is
# validated explicitly below and made loud on purpose, per spec §6.5:
# "presente mas malformado continua falha dura" (ausência is "adopting for
# the first time", corruption is "something broke" — different failure
# modes, deliberately not conflated).
if [ -n "$BASELINE_PATH" ] && [ -f "$BASELINE_PATH" ]; then
  if ! jq -e 'type == "array"' "$BASELINE_PATH" >/dev/null 2>&1; then
    echo "::error::baseline em '$BASELINE_PATH' existe mas não é um array JSON válido — abortando antes de escanear (arquivo ausente seria tratado como baseline vazio; arquivo corrompido não é o mesmo caso)" >&2
    exit 1
  fi
  baseline_args=(--baseline-path "$BASELINE_PATH")
fi

config_args=()
if [ -n "$CONFIG_PATH" ]; then
  # Unlike BASELINE_PATH, an empty CONFIG_PATH already means "not
  # customizing" (its input default is ""). A non-empty value is the
  # caller explicitly asking for a specific file, so — unlike a fresh
  # adopter's not-yet-created baseline — a missing file here is always a
  # misconfiguration (typo'd path), not a legitimate first-run state.
  # Falling through to gitleaks' embedded default ruleset silently would
  # be the same "wrong result, no signal" class of bug the baseline
  # validation above exists to prevent.
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "::error::config-path '$CONFIG_PATH' foi especificado mas o arquivo não existe — abortando antes de escanear" >&2
    exit 1
  fi
  config_args=(--config "$CONFIG_PATH")
fi

log_opts_args=()
if [ -n "$log_opts" ]; then
  log_opts_args=(--log-opts "$log_opts")
fi

# -v (post-PR-review fix, 3rd round): without it, a real finding on a
# required check gave the developer exactly "WRN leaks found: N" and
# nothing else — no file, no line, no rule ID, no path to remediation.
# Safe alongside --redact=100: verified live that -v's per-finding block
# (File/Line/RuleID/Fingerprint) still shows "Secret: REDACTED", never the
# raw value — redaction is applied to the value itself, not suppressed by
# verbosity. Deliberately NOT added to scan-passada2.sh, which runs
# --redact=0 — that pass's whole point is the derive step reading the
# unredacted secret from its JSON report, not from a human-facing log.
gitleaks git . --redact=100 --exit-code=42 --no-banner -v \
  --report-format=json --report-path="$REPORT_PATH" \
  "${baseline_args[@]+"${baseline_args[@]}"}" \
  "${config_args[@]+"${config_args[@]}"}" \
  "${log_opts_args[@]+"${log_opts_args[@]}"}"
