#!/usr/bin/env bash
SCAN_RANGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib-scan-range.sh"
# shellcheck source=/dev/null
source "$SCAN_RANGE_LIB"
set +e  # lib-scan-range.sh's own set -euo pipefail must not leak into every test function below (round-2 review)

_make_test_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  echo "one" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m "commit 1"
  echo "two" >> "$dir/f.txt"
  git -C "$dir" commit -qam "commit 2"
  echo "$dir"
}

test_push_normal_delta() {
  local dir before after
  dir=$(_make_test_repo)
  before=$(git -C "$dir" rev-parse HEAD~1)
  after=$(git -C "$dir" rev-parse HEAD)
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts push "$before" "$after" "" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "0" "normal push delta does not trigger the fallback"
  assert_eq "$log_opts" "--no-merges $before..$after" "normal push delta uses before..after"
}

test_push_new_branch_falls_back_to_default_branch_range() {
  local dir after
  dir=$(_make_test_repo)
  git -C "$dir" checkout -qb feature
  echo "three" >> "$dir/f.txt"
  git -C "$dir" commit -qam "commit 3 on feature"
  after=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse feature~1)"
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts push "0000000000000000000000000000000000000000" "$after" "" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "0" "branch-new push with real commits ahead of default is not the empty-range case"
  assert_eq "$log_opts" "--no-merges origin/main..$after" "before=zero falls back to origin/<default>..after"
}

test_push_force_push_on_default_branch_falls_back_to_single_commit() {
  local dir after
  dir=$(_make_test_repo)
  after=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" update-ref refs/remotes/origin/main "$after"  # origin/main == HEAD: range would be empty
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts push "0000000000000000000000000000000000000000" "$after" "" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "1" "empty range must set the fallback flag"
  assert_eq "$log_opts" "-1 $after" "empty range (force-push on default branch) falls back to a single-commit scan of the actual pushed tip, without --no-merges (round-2 review fix: --no-merges here would walk past a merge-commit tip to an already-scanned ancestor)"
}

test_push_merge_only_range_is_treated_as_empty() {
  # A push whose only new commit is a merge commit: git rev-list --count
  # WITHOUT --no-merges would report >0, but the actual scan (--no-merges)
  # would see zero — the guard has to count with --no-merges too.
  # Fixed by round-2 review: an earlier fixture used `before` = the tip
  # BEFORE the side branch existed, which made the range also contain the
  # side branch's own non-merge commit (verified empirically: rev-list
  # --count --no-merges on that range was 1, not 0 — the guard correctly
  # did NOT fire, but the test asserted that it should). The only range that
  # is genuinely "only merge commits" is side..merge — before must be the
  # tip of the side branch itself, not the commit it was created from.
  local dir side_tip after
  dir=$(_make_test_repo)
  git -C "$dir" checkout -qb side
  echo "side" >> "$dir/f.txt"
  git -C "$dir" commit -qam "side commit"
  side_tip=$(git -C "$dir" rev-parse side)
  git -C "$dir" checkout -q main
  git -C "$dir" merge -q --no-ff side -m "merge side"
  after=$(git -C "$dir" rev-parse HEAD)
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts push "$side_tip" "$after" "" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "1" "a range containing only the merge commit must be treated as empty under --no-merges"
  assert_eq "$log_opts" "-1 $after" "merge-only range falls back to single-commit scan of the merge commit itself, no --no-merges"
}

test_pull_request_merge_base_range() {
  local dir
  dir=$(_make_test_repo)
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" checkout -qb pr-branch
  echo "pr change" >> "$dir/f.txt"
  git -C "$dir" commit -qam "pr commit"
  local out fallback log_opts expected_base
  out=$(cd "$dir" && compute_log_opts pull_request "" "" "main" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  expected_base=$(git -C "$dir" merge-base origin/main HEAD)
  assert_eq "$fallback" "0" "normal PR range does not trigger the fallback"
  assert_eq "$log_opts" "${expected_base}..HEAD" "pull_request uses merge-base..HEAD"
}

test_pull_request_already_merged_falls_back_to_single_commit() {
  local dir
  dir=$(_make_test_repo)
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  local out fallback log_opts head_sha
  out=$(cd "$dir" && compute_log_opts pull_request "" "" "main" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  head_sha=$(cd "$dir" && git rev-parse HEAD)
  assert_eq "$fallback" "1" "merge-base succeeding with a zero-commit range must still set the fallback flag"
  assert_eq "$log_opts" "-1 $head_sha" "falls back to single-commit scan"
}

test_merge_group_uses_base_sha_directly() {
  local dir base_sha
  dir=$(_make_test_repo)
  base_sha=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" checkout -qb queue
  echo "queued change" >> "$dir/f.txt"
  git -C "$dir" commit -qam "queued commit"
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts merge_group "" "" "" "$base_sha" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "0" "merge_group with real commits ahead of base_sha is not empty"
  assert_eq "$log_opts" "${base_sha}..HEAD" "merge_group uses base_sha..HEAD directly — base_ref would be a full ref like refs/heads/main and never resolve as origin/refs/heads/main"
}

test_schedule_full_history() {
  local out fallback log_opts
  out=$(compute_log_opts schedule "" "" "" "" "main")
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "0" "schedule never triggers the fallback"
  assert_eq "$log_opts" "" "schedule/workflow_dispatch scan full history — no --log-opts restriction at all"
}

test_unknown_event_degrades_to_single_commit_not_abort_and_not_full_history() {
  # round-4 review: this function backs the gate (the required check),
  # which must never hard-fail just because an adopter's workflow triggers
  # on an event outside the known list (release, workflow_run,
  # pull_request_target, ...).
  # round-5 review: it also must NOT fall back to full-history — that would
  # make the gate block merge forever on a pre-existing historical secret
  # outside the baseline for an event the report side already skips
  # sending, with the SOC never hearing about it (spec §3.1's silent-drift
  # failure mode). Single-commit (-1 HEAD) still catches anything new.
  local dir head_sha
  dir=$(_make_test_repo)
  head_sha=$(git -C "$dir" rev-parse HEAD)
  local out fallback log_opts
  out=$(cd "$dir" && compute_log_opts release "" "" "" "" "main" 2>/dev/null)
  fallback=$(echo "$out" | sed -n 1p)
  log_opts=$(echo "$out" | sed -n 2p)
  assert_eq "$fallback" "1" "unknown event sets the fallback flag (scan is an approximation, not a decision to trust blindly)"
  assert_eq "$log_opts" "-1 $head_sha" "unknown event degrades to a single-commit scan of HEAD, not full history and not an abort"
}
