#!/usr/bin/env bash
# derive-findings.sh — correlates Passada 1 (masked, --redact=100) findings
# with Passada 2 (raw, --redact=0) findings via Fingerprint+StartColumn+
# EndColumn, derives secret_sha256 per finding, and prints the resulting
# batch items as a JSON array to stdout. `commit` is ALWAYS the 3rd argument
# — never gitleaks' own per-finding .Commit, which won't match the relay's
# claim.sha cross-check for any scan that walks more than one commit.
#
# Usage: derive-findings.sh <passada1-report.json> <passada2-raw.json> <commit> [max-findings]
#
# max-findings (post-PR-review fix, 3rd round): truncates the Passada 1
# report to its first N entries BEFORE correlating, not after. Correlation
# is O(findings x raw_findings) (a full linear scan of raw_json per
# finding) — measured locally: 500 findings ~15s, 2000 ~80s, superlinear.
# The caller (action.yml) already truncates to max-findings-per-run once
# this script returns, which only bounds the OUTPUT — a legacy repo's
# first full-history schedule scan with thousands of pre-existing findings
# could blow through job-timeout-minutes inside THIS script, before a
# single item is ever sent, with the heartbeat left to whatever seconds of
# budget remain. Truncating here bounds the worst case to the measured,
# acceptable one. Omit (or pass 0) to correlate everything, unbounded —
# used by tests that don't care about this limit.
set -euo pipefail

report_json="${1:?uso: derive-findings.sh <passada1-report.json> <passada2-raw.json> <commit> [max-findings]}"
raw_json="${2:?uso: derive-findings.sh <passada1-report.json> <passada2-raw.json> <commit> [max-findings]}"
commit="${3:?uso: derive-findings.sh <passada1-report.json> <passada2-raw.json> <commit> [max-findings]}"
max_findings="${4:-0}"

# SHA-256 of the empty string. If secret_sha256 ever equals this, the
# correlation produced an empty/missing Secret and we are about to publish a
# fabricated finding — .Secret // empty below only catches null/missing keys,
# not an empty-but-present string, which is why this check is separate.
sentinel="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

item_lines=()
while IFS= read -r finding; do
  fp=$(jq -r '.Fingerprint' <<<"$finding")
  sc=$(jq -r '.StartColumn' <<<"$finding")
  ec=$(jq -r '.EndColumn' <<<"$finding")

  secret_sha256=$(jq -je --arg fp "$fp" --argjson sc "$sc" --argjson ec "$ec" \
    'first(.[] | select(.Fingerprint==$fp and .StartColumn==$sc and .EndColumn==$ec)) | .Secret // empty' \
    "$raw_json" | sha256sum | cut -d' ' -f1) || {
    echo "::error::Fingerprint ${fp} (col ${sc}-${ec}) sem Secret correspondente na Passada 2 — recusando derivar hash de valor vazio/nulo" >&2
    exit 1
  }
  if [ "$secret_sha256" = "$sentinel" ]; then
    echo "::error::secret_sha256 igual ao hash de string vazia (col ${sc}-${ec}) — Secret correlacionado veio vazio" >&2
    exit 1
  fi

  # Collected as individual JSON lines, combined via `jq -s` once at the
  # end (post-PR-review fix, 3rd round) — the previous `items = items + [item]`
  # re-parsed and re-serialized the WHOLE growing array on every iteration,
  # an unnecessary O(n) cost per finding on top of the O(n) correlation
  # scan above (O(n^2) total either way, but this half was free to remove).
  item_lines+=("$(jq -c --arg sha "$secret_sha256" --arg commit "$commit" \
    '{commit: $commit, file: .File, start_line: .StartLine, end_line: .EndLine, start_column: .StartColumn, end_column: .EndColumn, rule: .RuleID, secret_sha256: $sha}' \
    <<<"$finding")")
done < <(jq -c --argjson max "$max_findings" 'if $max > 0 then .[0:$max] else . end | .[]' "$report_json")

if [ "${#item_lines[@]}" -eq 0 ]; then
  echo "[]"
else
  printf '%s\n' "${item_lines[@]}" | jq -cs '.'
fi
