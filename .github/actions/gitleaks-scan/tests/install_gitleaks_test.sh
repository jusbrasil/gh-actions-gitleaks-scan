#!/usr/bin/env bash
test_install_gitleaks_rejects_wrong_checksum() {
  local dir tarball
  dir=$(mktemp -d)
  tarball="$dir/gitleaks_8.30.1_linux_x64.tar.gz"
  echo "not a real tarball" > "$tarball"
  local out
  out=$(../install-gitleaks.sh 8.30.1 "0000000000000000000000000000000000000000000000000000000000000000" "$tarball" 2>&1)
  local code=$?
  assert_failure "$code" "wrong checksum must abort before extracting"
  if ! echo "$out" | grep -qi "FAILED"; then
    echo "FAIL: expected sha256sum's own FAILED message in output, got: $out" >&2
    TESTS_FAILED=1
  fi
}
