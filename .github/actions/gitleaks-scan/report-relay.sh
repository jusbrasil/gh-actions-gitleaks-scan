#!/usr/bin/env bash
# report-relay.sh — OIDC token acquisition + relay HTTP calls (spec §6, §9).
# This file grows in Task 6 with the batch/run-report POST logic.
set -euo pipefail

# request_oidc_token <audience>
# Prints the raw JWT to stdout. Applies ::add-mask:: on stderr before
# printing, so it never appears unmasked downstream. Exits 1 with nothing on
# stdout if OIDC isn't available — the caller (Task 8) branches on this exit
# code; it is not itself an error to log loudly here.
request_oidc_token() {
  local audience="$1"

  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    return 1
  fi

  local encoded_audience resp token
  encoded_audience=$(jq -rn --arg a "$audience" '$a|@uri')
  # --connect-timeout/--max-time (round-4 review fix): same class of hang
  # that motivated the identical fix in _post_with_retry (Task 6) — this
  # call happens before anything else in report mode, so a hung GitHub
  # token endpoint would burn the job's entire timeout right here, with no
  # retry loop and no deadline check to catch it.
  resp=$(curl -sSf --connect-timeout 10 --max-time 30 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded_audience}") || return 1
  token=$(echo "$resp" | jq -r '.value')

  # Guard against a malformed/empty response — without this, a null/empty
  # token gets masked and sent anyway as "Bearer null", surfacing as a
  # confusing 401 later instead of a clear failure here.
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "::error::resposta do endpoint de token OIDC não tem .value válido: ${resp}" >&2
    return 1
  fi

  echo "::add-mask::${token}" >&2
  echo "$token"
}

# chunk_items <items_json_array> <max_per_chunk>
# Prints one JSON array per line, each with at most <max_per_chunk> items.
# Uses `range(0; length; $max)` slicing (public jq API, documented since
# 1.5) rather than `_nwise` — an earlier draft used `_nwise`, jq's internal
# chunking generator: real and correctly used (each output was one chunk
# per line, not a single array-of-arrays), but it's an undocumented builtin
# whose availability isn't part of jq's public API contract across majors.
chunk_items() {
  local items="$1" max="$2"
  jq -c --argjson max "$max" '[range(0; length; $max) as $i | .[$i:$i+$max]] | .[]' <<<"$items"
}

# _post_with_retry <url> <token> <body> <deadline_epoch_seconds>
# Shared retry loop: honors Retry-After on 429/503/500 (capped so it never
# sleeps past the deadline, and falls back to a fixed delay if Retry-After
# isn't a plain integer — an HTTP-date value would otherwise be passed
# straight to `sleep` and fail), bounded by the given deadline (SECONDS-
# based, same clock the caller measured it from). Prints the final HTTP
# status code as its last line of stdout; the response body (if any) is
# left in $RELAY_RESP_FILE for the caller to inspect.
#
# The token goes into a curl -K config file (mode 600, removed immediately
# after each call), never into argv — curl has no -H @file form, so this is
# the only way to keep the Authorization header out of `ps`.
RELAY_RESP_FILE="$(mktemp)"
trap 'rm -f "$RELAY_RESP_FILE"' EXIT
_post_with_retry() {
  local url="$1" token="$2" body="$3" deadline="$4"
  # Normalize a trailing slash on relay_url once, at the caller (post_run_report/
  # post_findings_batch build "$relay_url/v1/..." — a trailing slash there
  # would produce "//v1/...").
  while :; do
    local headers_file curl_config
    headers_file=$(mktemp)
    curl_config=$(mktemp)
    chmod 600 "$curl_config"
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_config"
    local code
    # `|| true` (round-3 review fix): a curl TRANSPORT failure (DNS, refused
    # connection, TLS, timeout — exit 7 and friends) still prints "000" to
    # stdout via -w, but curl's own non-zero exit means `code=$(curl ...)`
    # is itself a failing command — under the derive/run-report step's
    # set -euo pipefail, that aborted the WHOLE step before this function
    # ever got to its own retry logic, and in the run-report step (called as
    # `post_run_report ... || true`) that abort silently ate the heartbeat
    # entirely instead of retrying. --connect-timeout/--max-time bound how
    # long a single hung attempt can burn before the retry loop even sees it.
    code=$(curl -sS --connect-timeout 10 --max-time 60 -K "$curl_config" -D "$headers_file" -o "$RELAY_RESP_FILE" -w '%{http_code}' \
      -X POST --data "$body" \
      "$url") || code="000"
    rm -f "$curl_config"
    case "$code" in
      200|201|202) rm -f "$headers_file"; echo "$code"; return ;;
      000|429|503|500)
        local remaining=$((deadline - SECONDS))
        if [ "$remaining" -le 0 ]; then
          echo "::warning::relay respondeu ${code} repetidamente contra ${url}, desistindo após o prazo" >&2
          rm -f "$headers_file"; echo "$code"; return
        fi
        local retry_after
        # `|| true` (round-4 review fix): under this shell's set -euo
        # pipefail, `grep` finding no Retry-After header (the normal case
        # for a 503 from a plain Cloud Run/LB blip, and ALWAYS the case for
        # the transport-failure "000" path just above — there's no response
        # at all, so $headers_file is empty) exits 1, pipefail propagates,
        # and the assignment itself aborts this function's caller — never
        # reaching the `if ! [[ ... ]]` fallback two lines down that exists
        # specifically to handle a missing header. That silently turned
        # every retryable failure into an immediate abort, which in the
        # run-report step (called as `... || true`) meant the heartbeat was
        # dropped instead of retried — exactly what the round-3 "000" fix
        # was supposed to prevent, undone by this one line.
        retry_after=$(grep -i '^retry-after:' "$headers_file" 2>/dev/null | tr -d '\r' | cut -d' ' -f2) || true
        rm -f "$headers_file"
        if ! [[ "$retry_after" =~ ^[0-9]+$ ]]; then
          retry_after=2  # missing, or an HTTP-date form sleep can't parse
        fi
        [ "$retry_after" -gt "$remaining" ] && retry_after="$remaining"
        sleep "$retry_after"
        ;;
      401)
        echo "::error::relay respondeu 401 (não autorizado) contra ${url}: $(cat "$RELAY_RESP_FILE" 2>/dev/null) (causas possíveis: token OIDC expirado, audience errada em relay-audience, ou claims do token não batem o que o relay espera)" >&2
        rm -f "$headers_file"; echo "$code"; return
        ;;
      403)
        echo "::error::relay respondeu 403 (proibido) contra ${url}: $(cat "$RELAY_RESP_FILE" 2>/dev/null) (causa mais provável: este repo/workflow_ref não está no allowlist do relay — ver runbook de allowlist; allowlist é carregado só no boot do relay, sem hot-reload)" >&2
        rm -f "$headers_file"; echo "$code"; return
        ;;
      404)
        echo "::error::relay respondeu 404 contra ${url}: $(cat "$RELAY_RESP_FILE" 2>/dev/null) (causa mais provável: relay-url está errada — confira a var FINDINGS_RELAY_URL)" >&2
        rm -f "$headers_file"; echo "$code"; return
        ;;
      413)
        echo "::error::relay respondeu 413 (payload grande demais) contra ${url}: $(cat "$RELAY_RESP_FILE" 2>/dev/null) (item acima de 1024 bytes deveria ter ido pro endpoint singular — isto é um bug no script, não na configuração do caller)" >&2
        rm -f "$headers_file"; echo "$code"; return
        ;;
      *)
        echo "::error::relay respondeu ${code} inesperado contra ${url}: $(cat "$RELAY_RESP_FILE" 2>/dev/null) (causas possíveis: Content-Type incorreto, payload malformado, URL errada)" >&2
        rm -f "$headers_file"; echo "$code"; return
        ;;
    esac
  done
}

# post_run_report <relay_url> <token> <status> <findings_count> <commit> <deadline_epoch_seconds>
post_run_report() {
  local relay_url="${1%/}" token="$2" status="$3" count="$4" commit="$5" deadline="$6"
  local body
  body=$(jq -cn --arg status "$status" --argjson count "$count" --arg commit "$commit" \
    '{status: $status, findings_count: $count, commit: $commit}')
  local code
  code=$(_post_with_retry "${relay_url}/v1/run-report" "$token" "$body" "$deadline")
  case "$code" in
    200|202) echo "unavailable_count=0" ;;
    *) echo "unavailable_count=1" ;;
  esac
}

# post_findings_batch <relay_url> <token> <items_json_array> <deadline_epoch_seconds>
# Prints "unavailable_count=<N>" as its last line — N > 0 means the caller
# must set run-report status to "partial".
post_findings_batch() {
  local relay_url="${1%/}" token="$2" items="$3" deadline="$4"
  local unavailable=0

  local small_items="[]" oversized_items="[]"
  while IFS= read -r item; do
    local size
    size=$(echo -n "$item" | wc -c | tr -d ' ')
    if [ "$size" -gt 1024 ]; then
      oversized_items=$(jq -c --argjson i "$item" '. + [$i]' <<<"$oversized_items")
    else
      small_items=$(jq -c --argjson i "$item" '. + [$i]' <<<"$small_items")
    fi
  done < <(jq -c '.[]' <<<"$items")

  # Oversized items go one at a time to the singular endpoint (spec §6.2).
  while IFS= read -r item; do
    [ "$item" = "null" ] && continue
    local code
    code=$(_post_with_retry "${relay_url}/v1/findings" "$token" "$item" "$deadline")
    case "$code" in 200|201) ;; *) unavailable=$((unavailable + 1)) ;; esac
  done < <(jq -c '.[]' <<<"$oversized_items")

  if [ "$(jq 'length' <<<"$small_items")" -gt 0 ]; then
    while IFS= read -r chunk; do
      local body code
      body=$(jq -cn --argjson items "$chunk" '{items: $items}')
      code=$(_post_with_retry "${relay_url}/v1/findings:batch" "$token" "$body" "$deadline")
      case "$code" in
        202)
          local invalid_count
          # `${invalid_count:-0}`, not just `|| echo 0` on the jq command
          # (post-PR-review fix, 3rd round): an empty $RELAY_RESP_FILE makes
          # jq print NOTHING while still exiting 0 (verified: it does not
          # fall into the jq-failed branch that `|| echo 0` guards), which
          # left invalid_count as an empty string — "$((unavailable + ))" is
          # a bash arithmetic SYNTAX error, aborting this whole step under
          # set -euo pipefail on what should be a harmless edge case.
          invalid_count=$(jq '[.results[]? | select(.status=="invalid")] | length' "$RELAY_RESP_FILE" 2>/dev/null || echo 0)
          unavailable=$((unavailable + ${invalid_count:-0}))
          # "unavailable" (spec §6.4, distinct from "invalid") is the
          # relay's own transient-storage-failure signal per item, not an
          # HTTP-level retry case — _post_with_retry already retried the
          # whole batch on transport/5xx failures, so this is the
          # 202-but-some-items-didn't-land case. Retried once, by index,
          # via the singular endpoint (results[].index maps back to
          # $chunk's own array position — spec batch.go assigns it, not
          # inferred from response ordering). One retry only: this is
          # spec §6.4's stated behavior, not an unbounded loop against a
          # relay that's still degraded.
          local retry_idx
          # Same empty-body edge case as invalid_count above, defended the
          # same way: fall back to the literal '[]' string, not just rely
          # on `|| echo '[]'` (which only fires on jq's own failure, not on
          # jq succeeding with empty output).
          retry_idx=$(jq -c '[.results[]? | select(.status=="unavailable") | .index]' "$RELAY_RESP_FILE" 2>/dev/null || echo '[]')
          retry_idx="${retry_idx:-[]}"
          local retry_count
          retry_count=$(jq 'length' <<<"$retry_idx")
          retry_count="${retry_count:-0}"
          if [ "$retry_count" -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; then
            local retry_item retry_code
            while IFS= read -r retry_item; do
              retry_code=$(_post_with_retry "${relay_url}/v1/findings" "$token" "$retry_item" "$deadline")
              case "$retry_code" in
                200|201) ;;
                *) unavailable=$((unavailable + 1)) ;;
              esac
            done < <(jq -c --argjson idx "$retry_idx" '. as $c | $idx[] as $i | $c[$i]' <<<"$chunk")
          else
            unavailable=$((unavailable + retry_count))
          fi
          ;;
        200|201) ;;
        *) unavailable=$((unavailable + $(jq 'length' <<<"$chunk"))) ;;
      esac
    done < <(chunk_items "$small_items" 500)
  fi

  echo "unavailable_count=${unavailable}"
}
