#!/usr/bin/env bash
# Opt-in git pre-commit hook: runs `tools/build.sh lint` (Dart format check, shellcheck, actionlint,
# a few seconds in the container) before each commit. Not the full test suite.
#
#   tools/install-hooks.sh              install (or update) the hook
#   tools/install-hooks.sh --uninstall  remove it
#
# Skip it for one commit with `git commit --no-verify`. The hook checks the working tree, not only staged changes.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$(git rev-parse --git-path hooks)/pre-commit"
marker="installed by tools/install-hooks.sh"

if [[ -e "$hook" ]] && ! grep -q "$marker" "$hook"; then
  echo "$hook exists and was not installed by this script; leaving it alone." >&2
  exit 1
fi
if [[ "${1:-}" == --uninstall ]]; then
  rm -f "$hook"; echo "removed $hook"; exit
fi

mkdir -p "$(dirname "$hook")"
cat > "$hook" <<EOF
#!/usr/bin/env bash
# $marker: quick lint before each commit (skip once: git commit --no-verify)
exec "\$(git rev-parse --show-toplevel)/tools/build.sh" lint
EOF
chmod +x "$hook"
echo "installed $hook (runs tools/build.sh lint)"
