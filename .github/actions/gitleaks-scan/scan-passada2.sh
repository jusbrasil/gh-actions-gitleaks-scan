#!/usr/bin/env bash
# scan-passada2.sh — the unredacted pass (spec §6.1, §9), only invoked when
# Passada 1 (gate mode) found a new finding. --exit-code 0 deliberately:
# this pass runs exactly when there IS a finding, so gitleaks' default
# non-zero exit-on-finding would abort this script under set -euo pipefail
# on its own success path. Takes --config so a repo with custom rules
# produces the SAME set of findings here as in Passada 1 — otherwise the
# correlation in derive-findings.sh finds nothing and aborts the whole
# report via the anti-empty guard.
set -euo pipefail

log_opts="${1:-}"
config_path="${2:-}"
report_path="${3:?report_path obrigatório}"

log_opts_args=()
if [ -n "$log_opts" ]; then
  log_opts_args=(--log-opts "$log_opts")
fi
config_args=()
if [ -n "$config_path" ]; then
  # Same reasoning as scan.sh's CONFIG_PATH validation: a non-empty
  # config_path here is always the same value Passada 1 already validated
  # exists (both passes must scan under the identical config, or
  # derive-findings.sh's correlation finds nothing) — falling through
  # silently on a missing file would let this pass diverge from Passada 1
  # instead of failing loud.
  if [ ! -f "$config_path" ]; then
    echo "::error::config-path '$config_path' foi especificado mas o arquivo não existe — abortando antes de escanear" >&2
    exit 1
  fi
  config_args=(--config "$config_path")
fi

gitleaks git . --redact=0 --exit-code 0 --no-banner \
  --report-format=json --report-path="$report_path" \
  "${log_opts_args[@]+"${log_opts_args[@]}"}" \
  "${config_args[@]+"${config_args[@]}"}"
