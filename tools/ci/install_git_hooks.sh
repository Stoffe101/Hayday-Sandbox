#!/usr/bin/env bash
# Install this repository's git hooks for the current clone (run once per clone; Git Bash works on Windows):
#   tools/ci/install_git_hooks.sh            # git config core.hooksPath tools/git-hooks
#   tools/ci/install_git_hooks.sh --check    # only report whether they are installed
#   tools/ci/install_git_hooks.sh --uninstall
# The hooks (tools/git-hooks/pre-commit, pre-push) run tools/ci/check_private_leaks.py so that original Hay Day
# art, private indexes, archives and Fan Kit tokens can never be committed or pushed. See docs/PRIVATE_ASSETS.md.
set -euo pipefail
top="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$top"
HOOKS_DIR="tools/git-hooks"
current="$(git config --get core.hooksPath || true)"

case "${1:-}" in
  --check)
    if [ "$current" = "$HOOKS_DIR" ]; then echo "git hooks installed (core.hooksPath=$current)"; exit 0; fi
    echo "git hooks NOT installed (core.hooksPath=${current:-<unset>}); run tools/ci/install_git_hooks.sh" >&2
    exit 1 ;;
  --uninstall)
    git config --unset core.hooksPath || true
    echo "core.hooksPath unset: the private-art hooks no longer run in this clone."
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--check|--uninstall]" >&2; exit 2 ;;
esac

[ -f "$HOOKS_DIR/pre-commit" ] && [ -f "tools/ci/check_private_leaks.py" ] || {
  echo "missing $HOOKS_DIR/pre-commit or tools/ci/check_private_leaks.py" >&2; exit 1; }
chmod +x "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/pre-push" 2>/dev/null || true

if [ -n "$current" ] && [ "$current" != "$HOOKS_DIR" ]; then
  echo "note: replacing core.hooksPath=$current (hooks there will no longer run)"
fi
# Hooks in .git/hooks are ignored once core.hooksPath is set: tell the user about any real (non-sample) ones.
gitdir="$(git rev-parse --git-common-dir)"
for h in "$gitdir"/hooks/*; do
  [ -f "$h" ] || continue
  case "$h" in *.sample) continue ;; esac
  echo "note: $h will no longer run (core.hooksPath takes precedence); move it into $HOOKS_DIR if you need it"
done

git config core.hooksPath "$HOOKS_DIR"
echo "installed: core.hooksPath=$(git config --get core.hooksPath) (pre-commit + pre-push private-art leak checks)"

# Smoke test: the checker must run here (Python available) and the currently staged files must be clean.
. "$HOOKS_DIR/lib.sh"
if find_python; then
  # shellcheck disable=SC2086
  $PY tools/ci/check_private_leaks.py --staged || {
    echo "warning: files currently staged in this clone fail the leak check (see above)" >&2; exit 1; }
else
  echo "warning: no Python 3 found; the hooks will BLOCK commits until Python 3 is installed" >&2
  exit 1
fi
