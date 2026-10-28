#!/usr/bin/env bash
# install-gitleaks.sh — downloads gitleaks pinned by version + SHA-256
# checksum (not the release's own checksums.txt — that protects against
# transit corruption, not a compromised/republished release; same reasoning
# already applied in our other gitleaks workflows).
#
# Usage: install-gitleaks.sh <version> <sha256> [<local-tarball-path>]
# The 3rd argument, when given, is used instead of downloading — for tests.
set -euo pipefail

version="${1:?uso: install-gitleaks.sh <version> <sha256> [local-tarball-path]}"
sha256="${2:?uso: install-gitleaks.sh <version> <sha256> [local-tarball-path]}"
tarball="${3:-${RUNNER_TEMP:-$(mktemp -d)}/gitleaks_${version}_linux_x64.tar.gz}"

if [ "$#" -lt 3 ]; then
  curl -sSfL -o "$tarball" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"
fi

echo "${sha256}  ${tarball}" | sha256sum -c - || {
  echo "::error::checksum do tarball do gitleaks ${version} não confere com o sha256 esperado (${sha256}) — gitleaks-version e gitleaks-sha256 precisam ser atualizados JUNTOS ao fazer bump de versão" >&2
  exit 1
}
sudo tar -xzf "$tarball" -C /usr/local/bin gitleaks
gitleaks version
