# gh-actions-gitleaks-scan

Reusable GitHub Actions workflows and a composite action to run [Gitleaks](https://github.com/gitleaks/gitleaks) secret scanning on pull requests and pushes.

The scan is limited to the commit range of the event (PR `base..head`, or the pushed range). A scheduled run scans the full history.

## Workflows

| Workflow | What it does |
| --- | --- |
| `secret-scan-gate.yml` | Runs Gitleaks and fails the job (exit code 42) when it finds a secret that is not in the baseline. Meant to be a required check. |
| `secret-scan-report.yml` | Runs Gitleaks and sends the findings, with the secret redacted, to a findings relay authenticated with a GitHub OIDC token. Never fails the job because of a finding. Requires `relay-url` and `relay-audience`. |

The report workflow needs a relay that implements the expected API. Without one, use only the gate.

## Usage

```yaml
name: gitleaks
on:
  pull_request:

permissions:
  contents: read

jobs:
  gate:
    uses: jusbrasil/gh-actions-gitleaks-scan/.github/workflows/secret-scan-gate.yml@v1.0.0
```

To also report findings, add a second job. The calling job must grant `id-token: write`:

```yaml
  report:
    permissions:
      contents: read
      id-token: write
    uses: jusbrasil/gh-actions-gitleaks-scan/.github/workflows/secret-scan-report.yml@v1.0.0
    with:
      relay-url: https://relay.example.com
      relay-audience: relay-audience
```

Pin to an immutable tag or a commit SHA. Do not use a branch.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `baseline-path` | `gitleaks-baseline.json` | Gitleaks baseline file, relative to the repo root. |
| `config-path` | empty | Custom Gitleaks config. Empty means Gitleaks auto-discovers `.gitleaks.toml`. |
| `gitleaks-version` | `8.30.1` | Gitleaks release to install. |
| `gitleaks-sha256` | checksum of `8.30.1` | SHA-256 of the `linux_x64` tarball. Update it together with the version. |
| `relay-url`, `relay-audience` | none | Report workflow only. Required. |
| `max-findings-per-run` | `500` | Report workflow only. Cap on findings sent per run. |
| `job-timeout-minutes` | `15` | Job timeout. The gate also exposes `gate-timeout-minutes`. |

The Gitleaks tarball is verified against the SHA-256 above, not against the release's own checksum file.

## Development

```sh
cd .github/actions/gitleaks-scan
./tests/run.sh
shellcheck -x *.sh
```

CI runs both on every pull request.
