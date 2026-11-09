# Shared helpers for the Hayday Sandbox git hooks (sourced; not a hook itself).
# Finds a Python 3.8+ interpreter: python3, python, or the Windows "py -3" launcher (Git for Windows' sh).

find_python() {
	for cand in python3 python "py -3"; do
		# shellcheck disable=SC2086
		if $cand -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >/dev/null 2>&1; then
			PY="$cand"
			return 0
		fi
	done
	return 1
}

leak_checker() {
	top=$(git rev-parse --show-toplevel) || return 2
	CHECKER="$top/tools/ci/check_private_leaks.py"
	if [ ! -f "$CHECKER" ]; then
		echo "$HOOK_NAME: $CHECKER is missing; refusing to continue without the private-art leak check." >&2
		return 2
	fi
	if ! find_python; then
		echo "$HOOK_NAME: Python 3 not found, so the private-art leak check cannot run and this is blocked." >&2
		echo "$HOOK_NAME: install Python 3 (https://www.python.org/downloads/ or: winget install -e --id Python.Python.3.12)." >&2
		return 2
	fi
	return 0
}
