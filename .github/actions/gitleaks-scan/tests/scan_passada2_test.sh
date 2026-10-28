#!/usr/bin/env bash
# Fixed by round-2 review: same mktemp-relative-path bug the round-1 review
# already found and fixed in scan_range_test.sh, recurring here because this
# file was written separately.
SCAN_PASSADA2_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scan-passada2.sh"

test_scan_passada2_produces_unredacted_secret_and_exits_zero() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "SKIP: gitleaks not installed locally" >&2
    return 0
  fi
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo 'aws_secret_access_key = AKIAABCDEFGHIJKLMNOP' > "$dir/secrets.env"
  git -C "$dir" add secrets.env
  git -C "$dir" commit -qm "oops"
  (cd "$dir" && "$SCAN_PASSADA2_SH" "" "" "$dir/raw.json")
  local code=$?
  assert_success "$code" "Passada 2 must exit 0 even though a finding exists — --exit-code 0 is deliberate"
  local secret_value
  secret_value=$(jq -r '.[0].Secret' "$dir/raw.json")
  if [ "$secret_value" != "AKIAABCDEFGHIJKLMNOP" ]; then
    echo "FAIL: expected the real unredacted secret in raw.json, got: $secret_value" >&2
    TESTS_FAILED=1
  fi
}

test_scan_passada2_aborts_on_missing_config_path() {
  # Same reasoning as scan.sh's equivalent test: an explicitly-set but
  # missing config_path must abort, not silently diverge from what
  # Passada 1 already validated exists.
  local dir code
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo "clean file" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm "clean commit"
  (cd "$dir" && "$SCAN_PASSADA2_SH" "" "$dir/does-not-exist.toml" "$dir/raw.json" >/dev/null 2>&1)
  code=$?
  assert_failure "$code" "explicitly-set but missing config_path must abort scan-passada2.sh"
}
