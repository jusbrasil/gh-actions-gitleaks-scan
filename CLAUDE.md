# CLAUDE.md

This repository is **public**. Everything committed here, including branches, commit messages, PR titles and descriptions, and comments, is visible to anyone and may be indexed or cloned permanently.

## Review every PR carefully

Before opening or approving a PR, review the whole diff, not only the files you meant to change:

- **No secrets or internal data.** No credentials, tokens, private keys, internal hostnames, project or account IDs, internal URLs, ticket links, or names of private repositories. Test fixtures must use obviously synthetic values.
- **Commit messages and PR text count too.** They are public and permanent. Keep them free of internal context.
- **Fail closed.** A misconfiguration or an unexpected input must keep the gate blocking, never silently pass. Execution errors must never be reported as a clean scan.
- **Callers control the inputs.** Treat every workflow input as untrusted. Pass them to scripts through `env:`, quote them, and do not interpolate `${{ }}` of caller-supplied values inside `run:`.
- **Pin what you depend on.** Pin third-party actions and downloaded binaries by commit SHA or checksum, and consumers should pin this repo by immutable tag or SHA. Never advise a branch or a moving tag.
- **Mind the contract.** Changing a workflow or action input, default or output affects every caller. Existing behavior must not change unless the PR says so.
- **Tests.** Add or update tests for every behavior change. Run `cd .github/actions/gitleaks-scan && ./tests/run.sh` and `shellcheck -x *.sh`.
- **Ask for an independent review** of the diff before merging, and do not merge your own PR without one.
