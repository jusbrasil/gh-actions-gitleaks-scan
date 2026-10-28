#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ran=0
overall_failed=0

for f in *_test.sh; do
  [ -e "$f" ] || continue
  # List test_* function names defined in $f without executing anything else
  # from the shell that's iterating the loop.
  #
  # Post-PR-review fix (3rd round): the exit code of this discovery command
  # was silently discarded — a syntax error in a *_test.sh file (or any
  # other reason `source` fails) made $fn_names empty, the inner loop never
  # ran, and the script still printed "0 test functions ran / ALL TESTS
  # PASSED" with exit 0. Reproduced live: a deliberately broken test file
  # (trailing syntax error, functions defined earlier in the file still
  # intact) made this whole suite report success. The FIRST attempt at this
  # fix (a bare `|| { ...; exit 1; }` with no `set -e` inside the bash -c
  # string) did NOT catch it either — verified: `source` on a file with a
  # trailing syntax error itself returns exit 2, but without `set -e` that
  # failure doesn't propagate past the `;`-chain, and the command
  # substitution's own exit status is just whatever the LAST command
  # (`grep`) returned, which still succeeded on the functions defined
  # before the bad line. `set -e` inside the bash -c string is what makes
  # `source`'s own failure actually abort before reaching `declare -F`.
  fn_names=$(bash -c "set -e; source helpers.sh; source '$f'; declare -F | awk '{print \$3}' | grep '^test_'") || {
    echo "FAIL: could not discover tests in $f (syntax error in the file, or it defines zero test_ functions)" >&2
    exit 1
  }
  for fn in $fn_names; do
    ran=$((ran + 1))
    if bash -c "source helpers.sh; source '$f'; $fn; exit \$TESTS_FAILED"; then
      echo "PASS: $fn ($f)"
    else
      echo "FAIL: $fn ($f)"
      overall_failed=1
    fi
  done
done

echo "---"
echo "$ran test functions ran"
if [ "$ran" -eq 0 ]; then
  echo "NO TESTS RAN — treating as a failure, not a pass" >&2
  exit 1
fi
if [ "$overall_failed" -eq 1 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"
