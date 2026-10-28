#!/usr/bin/env bash
# lib-scan-range.sh — computes the --log-opts value scan.sh passes to
# gitleaks, per event, with the empty-range guard from the design spec §5:
# any computed range that covers zero commits (counted WITH --no-merges,
# since that's the flag the real scan uses too) falls back to a
# single-commit scan of the reference commit, never to "scanned nothing,
# reported success".
#
# compute_log_opts <event> <before> <after> <base_ref> <base_sha> <default_branch>
# Prints TWO lines to stdout: line 1 is "0" or "1" (whether the fallback
# fired — callers use this to downgrade run-report.status to "partial"),
# line 2 is the --log-opts value (may be empty for schedule/workflow_dispatch).
# Deliberately prints rather than sets a variable: a caller capturing this
# via $(...) runs it in a subshell, where a variable mutation would be lost.
set -euo pipefail

compute_log_opts() {
  local event="$1" before="$2" after="$3" base_ref="$4" base_sha="$5" default_branch="$6"
  local range

  case "$event" in
    push)
      if [ "$before" = "0000000000000000000000000000000000000000" ] || ! git rev-parse --verify -q "$before" >/dev/null 2>&1; then
        range="origin/${default_branch}..${after}"
      else
        range="${before}..${after}"
      fi
      if [ "$(git rev-list --count --no-merges "$range" 2>/dev/null || echo 0)" = "0" ]; then
        # Deliberately NOT --no-merges here (fixed by round-2 review): if
        # $after is itself a merge commit (the common case for a push to a
        # protected default branch), "git log --no-merges -1 <merge>" walks
        # PAST it to the nearest non-merge ancestor — which was almost
        # certainly already scanned by an earlier run. A plain "-1 $after"
        # scans the actual tip that was pushed, consistent with the
        # pull_request/merge_group fallbacks below, which never use
        # --no-merges either.
        printf '1\n-1 %s\n' "$after"
        return
      fi
      printf '0\n--no-merges %s\n' "$range"
      ;;
    pull_request)
      local base
      base=$(git merge-base "origin/${base_ref}" HEAD 2>/dev/null) || base=""
      if [ -z "$base" ] || [ "$(git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)" = "0" ]; then
        printf '1\n-1 %s\n' "$(git rev-parse HEAD)"
        return
      fi
      printf '0\n%s..HEAD\n' "$base"
      ;;
    merge_group)
      # base_sha is already a resolved commit SHA (github.event.merge_group.base_sha)
      # — NOT base_ref, which is a full ref (refs/heads/main) and never
      # resolves as origin/refs/heads/main.
      if [ -z "$base_sha" ] || [ "$(git rev-list --count "${base_sha}..HEAD" 2>/dev/null || echo 0)" = "0" ]; then
        printf '1\n-1 %s\n' "$(git rev-parse HEAD)"
        return
      fi
      printf '0\n%s..HEAD\n' "$base_sha"
      ;;
    schedule|workflow_dispatch)
      printf '0\n\n'
      ;;
    *)
      # Degrades rather than aborting (round-4 review fix): this same
      # function backs the GATE, which is the required check —
      # reusable.yml is the org's central workflow and will be called from
      # adopters with arbitrary `on:` triggers (release, workflow_run,
      # repository_dispatch, pull_request_target, ...). A hard failure here
      # would mean the required check goes red for any event this list
      # doesn't happen to name, which is exactly the failure mode §7
      # designed the gate/report split to avoid.
      #
      # Degrades to a SINGLE-COMMIT scan (-1 HEAD), not full history (round-5
      # review fix on top of round-4's fix): full history was every other
      # fallback's opposite choice for a reason — an unlisted-but-real event
      # like pull_request_target is common, and scanning full history there
      # means the gate blocks merge on a pre-existing historical secret
      # outside the baseline, forever, on every PR, for an event the REPORT
      # side (Task 8's `derive` step) already treats as "skip, don't send" —
      # gate blocks, SOC hears nothing, the exact silent-drift failure mode
      # spec §3.1 names. A single-commit scan still catches anything NEW
      # introduced by this specific run, which is what the gate is actually
      # for; it does not retroactively enforce the entire history against an
      # event nobody designed this pipeline around.
      echo "::warning::compute_log_opts: evento '${event}' fora da tabela conhecida — escaneando só o commit atual por segurança (fallback), não o histórico completo" >&2
      printf '1\n-1 %s\n' "$(git rev-parse HEAD)"
      ;;
  esac
}
