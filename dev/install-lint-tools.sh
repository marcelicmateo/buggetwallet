#!/usr/bin/env bash
# Installs the pinned shell and workflow linters into <bindir> (default /usr/local/bin).
# Used by dev/Containerfile (local builds) and .github/workflows/ci.yml, so both run the same versions.
# Bump a version: change it here together with its sha256; the build image is rebuilt automatically.
set -euo pipefail

SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

bindir=${1:-/usr/local/bin}
[[ $(uname -m) == x86_64 ]] || { echo "install-lint-tools.sh: only x86_64 is supported" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() { # url sha256 file
  curl -fsSL -o "$tmp/$3" "$1"
  echo "$2  $tmp/$3" | sha256sum -c --quiet -
}

fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" \
  "$SHELLCHECK_SHA256" shellcheck.tar.xz
tar -xJf "$tmp/shellcheck.tar.xz" -C "$tmp"
fetch "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
  "$ACTIONLINT_SHA256" actionlint.tar.gz
tar -xzf "$tmp/actionlint.tar.gz" -C "$tmp" actionlint

mkdir -p "$bindir"
install -m 0755 "$tmp/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$tmp/actionlint" "$bindir/"
"$bindir/shellcheck" --version | grep '^version'
echo "actionlint $("$bindir/actionlint" -version | head -1)"
