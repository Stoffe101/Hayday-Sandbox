#!/usr/bin/env python3
"""One-command reproduction of the PRIVATE Hay Day art pack (Windows, Linux, macOS).

Runs the documented tools in order, each as a subprocess, with resume:

  fankit   tools/private_assets/fetch_fankit.py --out <root>                 (Supercell Fan Kit, public portal)
  wiki     tools/private_assets/fetch_wiki.py   --out <root> --wiki en --resume   (Hay Day Wiki, public API)
  wiki_ru  tools/private_assets/fetch_wiki.py   --out <root> --wiki ru --resume
  apk      tools/private_assets/extract_from_apk.py extract <file> --out <root>  (ONLY with --apk: an APK/XAPK
           you already have, e.g. pulled from your own phone; nothing is downloaded)
  build    tools/private_assets/build_pack.py   --root <root> --install-dir <install dir>
           (+ --build-world when client tables were extracted: map v2 world, landmarks, catalogue overrides;
           + --terrain when the client's background art and the terrain placement file exist: pack terrain;
           if build_pack.py has no --install-dir option, the built pack is installed with install_pack.py)

Defaults
  <root>         %USERPROFILE%\\hayday-sandbox-private-assets (Windows), ~/hayday-sandbox-private-assets elsewhere,
                 or $HAYDAY_PRIVATE_ASSETS. Must NOT be inside a git work tree (refused).
  install dir    %APPDATA%\\HaydaySandbox\\asset_packs\\hayday_original (Windows),
                 ~/.local/share/HaydaySandbox/asset_packs/hayday_original (Linux, honours $XDG_DATA_HOME),
                 ~/Library/Application Support/HaydaySandbox/asset_packs/hayday_original (macOS)

Python packages: Pillow, numpy and requests, plus whatever the step scripts import (read from their source at
run time, so a newer build_pack.py's dependencies are picked up), plus --pip extras; missing ones are installed
with ``python -m pip install``. On a system Python that forbids that (PEP 668) use --venv (creates <root>/.venv).

Resume: state is kept in <root>/acquire_state.json. Re-running the same command skips finished steps and resumes
unfinished ones (the fetchers keep verified files and continue partial downloads). --refresh re-runs finished
fetch steps to pick up new files (still incremental); --steps chooses steps. Logs: <root>/logs/acquire_*.log.

Limits honoured by the tools: public endpoints only, no logins, no bot-challenge bypass (a challenged source is
recorded and skipped), no game servers, <= 3 concurrent requests with delays and backoff.

LEGAL: the result is proprietary Supercell art for the user's PERSONAL use in this app. Never commit, share,
upload or redistribute it. See docs/PRIVATE_ASSETS.md.

Examples
  python tools/private_assets/acquire.py                      # everything, with defaults
  python tools/private_assets/acquire.py --dry-run            # show the plan, touch nothing
  python tools/private_assets/acquire.py --steps build        # rebuild + reinstall the pack only
  python tools/private_assets/acquire.py --apk D:\\phone\\hayday.xapk
"""
from __future__ import annotations

import argparse
import ast
import datetime as dt
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
STATE_FILE = "acquire_state.json"
LOCK_FILE = ".acquire.lock"
ALL_STEPS = ("fankit", "wiki", "wiki_ru", "apk", "build")
FETCH_STEPS = ("fankit", "wiki", "wiki_ru", "apk")
BASE_PIP = ("Pillow", "numpy", "requests")
PIP_NAMES = {
	"PIL": "Pillow", "cv2": "opencv-python-headless", "skimage": "scikit-image", "sklearn": "scikit-learn",
	"yaml": "PyYAML", "bs4": "beautifulsoup4", "imagehash": "ImageHash", "pyasn1_modules": "pyasn1-modules",
	"Levenshtein": "python-Levenshtein", "dateutil": "python-dateutil", "Crypto": "pycryptodome",
}
KNOWN_OPTIONAL = {"lzham"}          # no dependable wheels; only needed for rare legacy files
MIN_PY = (3, 10)


# ------------------------------------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------------------------------------

def default_root() -> Path:
	env = os.environ.get("HAYDAY_PRIVATE_ASSETS")
	if env:
		return Path(env).expanduser()
	if os.name == "nt":
		return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "hayday-sandbox-private-assets"
	return Path.home() / "hayday-sandbox-private-assets"


def godot_user_dir() -> Path:
	if os.name == "nt":
		return Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))) / "HaydaySandbox"
	if sys.platform == "darwin":
		return Path.home() / "Library" / "Application Support" / "HaydaySandbox"
	return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "HaydaySandbox"


def default_install_dir() -> Path:
	return godot_user_dir() / "asset_packs" / "hayday_original"


def git_worktree_of(p: Path) -> Path | None:
	"""The git work tree containing p (or its nearest existing ancestor), else None."""
	p = p.expanduser().resolve()
	for parent in [p, *p.parents]:
		if (parent / ".git").exists():
			return parent
	return None


def refuse_in_git(p: Path, what: str) -> None:
	wt = git_worktree_of(p)
	rp = p.expanduser().resolve()
	if wt is not None or rp == REPO_ROOT or REPO_ROOT in rp.parents:
		sys.exit(f"acquire: refusing to use {rp} as {what}: it is inside a git work tree ({wt or REPO_ROOT}). "
			"Private art must live outside any repository.")


# ------------------------------------------------------------------------------------------------------------
# Dependencies (read from the step scripts' source)
# ------------------------------------------------------------------------------------------------------------

def script_imports(path: Path) -> tuple[set[str], set[str]]:
	"""(required, optional) third-party top-level modules imported by a script. Imports inside a try whose
	ImportError handler neither exits nor raises are optional; ``need("x")`` / ``import_module("x")`` count."""
	tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
	parents: dict[ast.AST, ast.AST] = {}
	for node in ast.walk(tree):
		for child in ast.iter_child_nodes(node):
			parents[child] = node

	def optional(node: ast.AST) -> bool:
		cur = node
		while cur in parents:
			par = parents[cur]
			if isinstance(par, ast.Try) and cur in par.body:
				for h in par.handlers:
					names = []
					if isinstance(h.type, ast.Name):
						names = [h.type.id]
					elif isinstance(h.type, ast.Tuple):
						names = [e.id for e in h.type.elts if isinstance(e, ast.Name)]
					if h.type is None or {"ImportError", "ModuleNotFoundError", "Exception"} & set(names):
						fatal = any(isinstance(n, ast.Raise) or (isinstance(n, ast.Call) and (
							getattr(n.func, "attr", None) == "exit" or getattr(n.func, "id", None) in ("exit", "quit")))
							for b in h.body for n in ast.walk(b))
						return not fatal
			cur = par
		return False

	req: set[str] = set()
	opt: set[str] = set()
	for node in ast.walk(tree):
		mods: list[str] = []
		if isinstance(node, ast.Import):
			mods = [a.name.split(".")[0] for a in node.names]
		elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
			mods = [node.module.split(".")[0]]
		elif isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant) \
				and isinstance(node.args[0].value, str):
			fn = getattr(node.func, "id", None) or getattr(node.func, "attr", None)
			if fn in ("need", "import_module", "__import__") and re.match(r"^[A-Za-z_][\w.]*$", node.args[0].value):
				mods = [node.args[0].value.split(".")[0]]
		for m in mods:
			if m in sys.stdlib_module_names or m == "__future__" or (path.parent / f"{m}.py").exists() \
					or (path.parent / m / "__init__.py").exists():
				continue
			(opt if (m in KNOWN_OPTIONAL or optional(node)) else req).add(m)
	return req, opt - req


def missing_modules(python: str, mods: set[str]) -> set[str]:
	if not mods:
		return set()
	code = ("import importlib.util, json, sys\n"
		"print(json.dumps([m for m in sys.argv[1:] if importlib.util.find_spec(m) is None]))")
	out = subprocess.run([python, "-c", code, *sorted(mods)], capture_output=True, text=True)
	if out.returncode != 0:
		return set(mods)
	return set(json.loads(out.stdout.strip() or "[]"))


def ensure_deps(scripts: list[Path], extra: list[str], allow_install: bool, log) -> bool:
	req: set[str] = {"PIL", "numpy", "requests"}
	opt: set[str] = set()
	for s in scripts:
		if s.is_file():
			r, o = script_imports(s)
			req |= r
			opt |= o
	opt -= req
	miss_req = missing_modules(sys.executable, req)
	miss_opt = missing_modules(sys.executable, opt - KNOWN_OPTIONAL)
	pkgs = sorted({PIP_NAMES.get(m, m) for m in miss_req} | set(extra))
	log(f"python {sys.version.split()[0]} at {sys.executable}")
	log(f"required modules: {', '.join(sorted(req))}; missing: {', '.join(sorted(miss_req)) or 'none'}")
	if opt:
		log(f"optional modules: {', '.join(sorted(opt))}; missing: {', '.join(sorted(miss_opt)) or 'none'}")
	if not pkgs and not miss_opt:
		return True
	if not allow_install:
		if pkgs:
			log(f"missing packages (not installing, --no-pip): {' '.join(pkgs)}")
		return not miss_req
	ok = True
	if pkgs:
		ok = pip_install(pkgs, log)
	for m in sorted(miss_opt):
		if not pip_install([PIP_NAMES.get(m, m)], log, quiet_fail=True):
			log(f"optional package {PIP_NAMES.get(m, m)} could not be installed (features that need it are skipped)")
	if ok and missing_modules(sys.executable, req):
		log(f"still missing after pip: {', '.join(sorted(missing_modules(sys.executable, req)))}")
		ok = False
	return ok


def pip_install(pkgs: list[str], log, quiet_fail: bool = False) -> bool:
	cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", *pkgs]
	log("$ " + " ".join(shlex.quote(c) for c in cmd))
	r = subprocess.run(cmd, capture_output=True, text=True)
	if r.returncode == 0:
		return True
	if not quiet_fail:
		tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
		for line in tail:
			log("  pip: " + line)
		if "externally-managed-environment" in r.stdout + r.stderr or "externally managed" in r.stderr:
			log("this Python does not allow pip installs; re-run with --venv (creates <root>/.venv)")
	return False


def venv_python(venv: Path) -> Path:
	return venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def in_venv() -> bool:
	return sys.prefix != getattr(sys, "base_prefix", sys.prefix)


# ------------------------------------------------------------------------------------------------------------
# State / lock
# ------------------------------------------------------------------------------------------------------------

def now() -> str:
	return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(root: Path) -> dict:
	p = root / STATE_FILE
	if p.is_file():
		try:
			return json.loads(p.read_text(encoding="utf-8"))
		except (OSError, ValueError):
			pass
	return {"version": 1, "steps": {}, "runs": []}


def save_state(root: Path, state: dict) -> None:
	p = root / STATE_FILE
	tmp = p.with_suffix(f".tmp{os.getpid()}")
	tmp.write_text(json.dumps(state, indent=1), encoding="utf-8")
	os.replace(tmp, p)


def pid_alive(pid: int) -> bool:
	if pid <= 0:
		return False
	if os.name == "nt":
		try:
			import ctypes
			h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
			if h:
				ctypes.windll.kernel32.CloseHandle(h)
				return True
			return False
		except Exception:
			return True
	try:
		os.kill(pid, 0)
		return True
	except ProcessLookupError:
		return False
	except PermissionError:
		return True


def take_lock(root: Path) -> Path:
	lock = root / LOCK_FILE
	if lock.exists():
		try:
			pid = int(json.loads(lock.read_text()).get("pid", 0))
		except (OSError, ValueError):
			pid = 0
		if pid_alive(pid) and pid != os.getpid():
			sys.exit(f"acquire: another run (pid {pid}) is using {root}; wait for it, or delete {lock} if it is stale")
		lock.unlink(missing_ok=True)
	fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
	with os.fdopen(fd, "w") as fh:
		json.dump({"pid": os.getpid(), "started": now()}, fh)
	return lock


# ------------------------------------------------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------------------------------------------------

def help_text(script: Path) -> str:
	try:
		r = subprocess.run([sys.executable, str(script), "--help"], capture_output=True, text=True, timeout=120)
		return r.stdout + r.stderr
	except (OSError, subprocess.TimeoutExpired):
		return ""


def step_commands(step: str, args, tools: Path) -> tuple[list[list[str]], str | None]:
	"""Commands for a step, or ([], reason) when it cannot run."""
	py = [sys.executable, "-u"]
	root = str(args.root)
	if step == "fankit":
		s = tools / "fetch_fankit.py"
		return ([py + [str(s), "--out", root, *args.fankit_arg]], None) if s.is_file() else ([], f"{s} not found")
	if step in ("wiki", "wiki_ru"):
		s = tools / "fetch_wiki.py"
		lang = "en" if step == "wiki" else "ru"
		return ([py + [str(s), "--out", root, "--wiki", lang, "--resume", *args.wiki_arg]], None) if s.is_file() \
			else ([], f"{s} not found")
	if step == "apk":
		s = tools / "extract_from_apk.py"
		if not args.apk:
			return [], "no --apk file given"
		if not s.is_file():
			return [], f"{s} not found"
		return [py + [str(s), "extract", str(args.apk), "--out", root, *args.apk_arg]], None
	if step == "build":
		s = tools / "build_pack.py"
		if not s.is_file():
			return [], f"{s.name} not found in {tools} (update your checkout; the pack builder is required)"
		h = help_text(s)
		inst = tools / "install_pack.py"
		extra = []
		# world data (map v2, landmarks, catalogue overrides) needs the client tables the apk step extracts
		if "--build-world" in h and "--no-world" not in args.build_arg and "--build-world" not in args.build_arg \
				and any(Path(root).glob("raw/apk_extracted/*/assets/data/level_0.csv")):
			extra.append("--build-world")
		# terrain (ground tiles, edges, river, water clips) needs the client's background art and the private placement
		# file of the terrain research (anchors are not in the client tables)
		if "--terrain" in h and "--no-terrain" not in args.build_arg and "--terrain" not in args.build_arg \
				and any(Path(root).glob("raw/apk_extracted/*/assets/sc/background.sc")) \
				and (Path(root) / "research" / "terrain" / "terrain_manifest.json").is_file():
			extra.append("--terrain")
		if "--install-dir" in h or not h:
			return [py + [str(s), "--root", root, "--install-dir", str(args.install_dir), *extra, *args.build_arg]], None
		cmds = [py + [str(s), "--root", root, *args.build_arg]]
		if inst.is_file():
			cmds.append(py + [str(inst), "--find-in", root, "--dest", str(args.install_dir)])
		return cmds, None
	return [], f"unknown step {step}"


def run_logged(cmd: list[str], log_path: Path, env: dict, cwd: Path) -> int:
	log_path.parent.mkdir(parents=True, exist_ok=True)
	with open(log_path, "a", encoding="utf-8") as lf:
		lf.write(f"\n# {now()} $ {' '.join(shlex.quote(c) for c in cmd)}\n")
		lf.flush()
		proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, cwd=str(cwd),
			text=True, encoding="utf-8", errors="replace", bufsize=1)
		try:
			for line in proc.stdout:
				sys.stdout.write("    " + line)
				sys.stdout.flush()
				lf.write(line)
			return proc.wait()
		except KeyboardInterrupt:
			try:
				proc.wait(timeout=15)
			except subprocess.TimeoutExpired:
				proc.terminate()
				try:
					proc.wait(timeout=10)
				except subprocess.TimeoutExpired:
					proc.kill()
			raise


def step_notes(step: str, root: Path, install_dir: Path) -> str:
	def load(p: Path):
		try:
			return json.loads(p.read_text(encoding="utf-8"))
		except (OSError, ValueError):
			return None
	if step == "fankit":
		d = load(root / "raw" / "fankit" / "index.json")
		if isinstance(d, dict):
			return f"{d.get('downloaded_ok', '?')}/{d.get('listed', '?')} downloaded, {d.get('failed', '?')} failed"
	if step in ("wiki", "wiki_ru"):
		d = load(root / "raw" / ("wiki" if step == "wiki" else "wiki_ru") / "index.json")
		if isinstance(d, dict):
			return f"{len(d.get('files') or [])} files indexed, {len(d.get('skipped') or [])} skipped"
	if step == "apk":
		n = sum(1 for _ in (root / "raw" / "apk_sprites").rglob("*.png")) if (root / "raw" / "apk_sprites").is_dir() else 0
		return f"{n} rendered sprites in raw/apk_sprites"
	if step == "build":
		d = load(install_dir / "pack.json")
		if isinstance(d, dict):
			return f"pack '{d.get('id', '?')}' v{d.get('version', '?')}: {len(d.get('sprites') or {})} sprites installed"
		return "no pack.json in the install dir"
	return ""


def fmt_secs(s: float) -> str:
	s = int(s)
	return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def main(argv: list[str] | None = None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
		formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
	ap.add_argument("--root", type=Path, default=None, help=f"private storage root (default {default_root()})")
	ap.add_argument("--install-dir", type=Path, default=None,
		help=f"where the app looks for the pack (default {default_install_dir()})")
	ap.add_argument("--steps", default=None, help=f"comma list from {','.join(ALL_STEPS)} "
		"(default: fankit,wiki,wiki_ru,build; +apk when --apk is given)")
	ap.add_argument("--apk", type=Path, help="an APK/XAPK/APKS file or folder you already have (enables the apk step)")
	ap.add_argument("--refresh", action="store_true", help="re-run finished steps (incremental) to pick up new files")
	ap.add_argument("--dry-run", action="store_true", help="print the plan; download, install and write nothing")
	ap.add_argument("--pip", nargs="*", default=[], metavar="PKG", help="extra pip packages to install")
	ap.add_argument("--no-pip", action="store_true", help="never run pip (fail if something is missing)")
	ap.add_argument("--venv", action="store_true", help="create/use <root>/.venv and re-run inside it")
	ap.add_argument("--fankit-arg", action="append", default=[], help="extra argument for fetch_fankit.py")
	ap.add_argument("--wiki-arg", action="append", default=[], help="extra argument for fetch_wiki.py")
	ap.add_argument("--apk-arg", action="append", default=[], help="extra argument for extract_from_apk.py extract")
	ap.add_argument("--build-arg", action="append", default=[], help="extra argument for build_pack.py")
	ap.add_argument("--keep-going", action="store_true", help="continue with later steps after a failed step")
	ap.add_argument("--tools-dir", type=Path, default=TOOLS_DIR, help=argparse.SUPPRESS)
	ap.add_argument("--self-test", action="store_true", help="run the offline self-test (stub tools) and exit")
	args = ap.parse_args(argv)
	if args.self_test:
		return self_test()
	if sys.version_info < MIN_PY:
		sys.exit(f"acquire: Python {MIN_PY[0]}.{MIN_PY[1]}+ is required (this is {sys.version.split()[0]})")

	args.root = (args.root or default_root()).expanduser().resolve()
	args.install_dir = (args.install_dir or default_install_dir()).expanduser().resolve()
	refuse_in_git(args.root, "the private storage root")
	refuse_in_git(args.install_dir, "the pack install folder")
	steps = [s.strip() for s in (args.steps or ",".join(
		["fankit", "wiki", "wiki_ru"] + (["apk"] if args.apk else []) + ["build"])).split(",") if s.strip()]
	bad = [s for s in steps if s not in ALL_STEPS]
	if bad:
		ap.error(f"unknown step(s): {', '.join(bad)}")
	tools = args.tools_dir.resolve()

	def log(msg: str) -> None:
		print(f"[acquire] {msg}", flush=True)

	scripts = [tools / n for n in ("fetch_fankit.py", "fetch_wiki.py", "build_pack.py", "install_pack.py")]
	if "apk" in steps:
		scripts.append(tools / "extract_from_apk.py")
	if args.dry_run:
		log(f"DRY RUN - nothing is downloaded, installed or written")
		log(f"root: {args.root}{'' if args.root.exists() else ' (would be created)'}")
		log(f"install dir: {args.install_dir}")
		state = load_state(args.root) if args.root.exists() else {"steps": {}}
		for s in scripts:
			if s.is_file():
				r, o = script_imports(s)
				log(f"{s.name}: imports {', '.join(sorted(r)) or '-'}" + (f" (optional: {', '.join(sorted(o))})" if o else ""))
		for st in steps:
			cmds, why = step_commands(st, args, tools)
			done = state.get("steps", {}).get(st, {}).get("status") == "done"
			label = "skip (done; --refresh to re-run)" if done and not args.refresh and st != "build" else "run"
			if why:
				log(f"{st:8} cannot run: {why}")
			for c in cmds:
				log(f"{st:8} {label}: {' '.join(shlex.quote(x) for x in c)}")
		return 0

	if args.venv and not in_venv() and not os.environ.get("HAYDAY_ACQUIRE_IN_VENV"):
		venv = args.root / ".venv"
		args.root.mkdir(parents=True, exist_ok=True)
		if not venv_python(venv).exists():
			log(f"creating virtual environment {venv}")
			subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
		env = dict(os.environ, HAYDAY_ACQUIRE_IN_VENV="1")
		rest = [a for a in (argv if argv is not None else sys.argv[1:]) if a != "--venv"]
		return subprocess.call([str(venv_python(venv)), str(Path(__file__).resolve()), *rest], env=env)

	args.root.mkdir(parents=True, exist_ok=True)
	usage = shutil.disk_usage(args.root)
	if usage.free < 5 * 1024 ** 3:
		log(f"warning: only {usage.free / 1024 ** 3:.1f} GB free at {args.root} (a full run needs several GB)")
	lock = take_lock(args.root)
	state = load_state(args.root)
	stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
	run_rec = {"started": now(), "steps": steps, "python": sys.executable, "argv": sys.argv[1:]}
	results: dict[str, dict] = {}
	rc_final = 0
	try:
		if not ensure_deps(scripts, args.pip, not args.no_pip, log):
			log("missing Python packages; nothing was run (see above)")
			rc_final = 1
			return 1
		env = dict(os.environ, HAYDAY_PRIVATE_ASSETS=str(args.root), PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
		failed = False
		for st in steps:
			prev = state["steps"].get(st, {})
			if failed and not args.keep_going:
				results[st] = {"status": "not run", "note": "an earlier step failed"}
				continue
			if prev.get("status") == "done" and st in FETCH_STEPS and not args.refresh:
				results[st] = {"status": "done (earlier)", "seconds": 0, "note": f"finished {prev.get('finished')}"}
				continue
			cmds, why = step_commands(st, args, tools)
			if why:
				results[st] = {"status": "FAILED", "note": why}
				state["steps"][st] = {"status": "failed", "finished": now(), "note": why}
				save_state(args.root, state)
				failed = True
				continue
			log_path = args.root / "logs" / f"acquire_{st}_{stamp}.log"
			log(f"step {st}: {len(cmds)} command(s), log {log_path}")
			t0 = time.time()
			state["steps"][st] = {"status": "running", "started": now(), "log": str(log_path)}
			save_state(args.root, state)
			rc = 0
			for c in cmds:
				rc = run_logged(c, log_path, env, args.root)
				if rc != 0:
					break
			secs = time.time() - t0
			status = "done" if rc == 0 else "failed"
			state["steps"][st] = {"status": status, "rc": rc, "started": state["steps"][st]["started"],
				"finished": now(), "seconds": round(secs, 1), "log": str(log_path)}
			save_state(args.root, state)
			results[st] = {"status": "done" if rc == 0 else f"FAILED (exit {rc})", "seconds": secs}
			if rc != 0:
				failed = True
		rc_final = 1 if failed else 0
	except KeyboardInterrupt:
		for st, rec in state["steps"].items():
			if rec.get("status") == "running":
				rec["status"] = "interrupted"
				results[st] = {"status": "INTERRUPTED"}
		rc_final = 130
	finally:
		run_rec.update({"finished": now(), "rc": rc_final})
		state.setdefault("runs", []).append(run_rec)
		state["runs"] = state["runs"][-50:]
		try:
			save_state(args.root, state)
		finally:
			lock.unlink(missing_ok=True)
		print_summary(args, steps, results, rc_final)
	return rc_final


def print_summary(args, steps: list[str], results: dict, rc: int) -> None:
	free = shutil.disk_usage(args.root).free / 1024 ** 3 if args.root.exists() else 0
	print("\n==== Hay Day private art: summary ====")
	print(f"root:         {args.root}  ({free:.1f} GB free)")
	print(f"install dir:  {args.install_dir}")
	for st in steps:
		r = results.get(st, {"status": "not run"})
		secs = r.get("seconds")
		notes = r.get("note") or step_notes(st, args.root, args.install_dir)
		print(f"  {st:8} {r['status']:<18} {fmt_secs(secs) if secs else '':>7}  {notes}")
	print(f"logs:         {args.root / 'logs'}  state: {args.root / STATE_FILE}")
	if rc == 130:
		print("Interrupted. Re-run the same command to resume where it stopped.")
	elif rc:
		print("Some steps failed. Fix the cause shown above and re-run the same command; finished steps are skipped.")
	else:
		print("Done. Start Hayday Sandbox: the pack appears in Settings / Asset Manager (Ctrl+Shift+A) -> Packs.")
	print("Personal use only: never commit, share, upload or redistribute these files.")


# ------------------------------------------------------------------------------------------------------------
# Self-test (offline: stub tools in a temporary folder)
# ------------------------------------------------------------------------------------------------------------

def self_test() -> int:
	fails: list[str] = []
	tmp = Path(tempfile.mkdtemp(prefix="acquire-selftest-"))
	try:
		tools = tmp / "tools"
		tools.mkdir()
		root = tmp / "private"
		inst = tmp / "user" / "asset_packs" / "hayday_original"
		(tools / "fetch_fankit.py").write_text(
			"import sys, json, os\nfrom pathlib import Path\nimport PIL\n"
			"o = Path(sys.argv[sys.argv.index('--out') + 1]) / 'raw' / 'fankit'\no.mkdir(parents=True, exist_ok=True)\n"
			"c = o / 'count'\nn = int(c.read_text()) + 1 if c.exists() else 1\nc.write_text(str(n))\n"
			"(o / 'index.json').write_text(json.dumps({'listed': 3, 'downloaded_ok': 3, 'failed': 0}))\nprint('fankit ok')\n")
		(tools / "fetch_wiki.py").write_text(
			"import sys, json\nfrom pathlib import Path\ntry:\n\timport requests\nexcept ImportError:\n\tsys.exit('need requests')\n"
			"a = sys.argv\nsub = 'wiki' if a[a.index('--wiki') + 1] == 'en' else 'wiki_ru'\nassert '--resume' in a\n"
			"o = Path(a[a.index('--out') + 1]) / 'raw' / sub\no.mkdir(parents=True, exist_ok=True)\n"
			"(o / 'index.json').write_text(json.dumps({'files': [{}, {}], 'skipped': []}))\nprint(sub, 'ok')\n")
		(tools / "build_pack.py").write_text(
			"import argparse, json, sys\nfrom pathlib import Path\nimport numpy\ntry:\n\timport zz_optional_mod\n"
			"except ImportError:\n\tzz_optional_mod = None\nimport helper_local\n"
			"ap = argparse.ArgumentParser()\nap.add_argument('--root')\nap.add_argument('--install-dir')\na = ap.parse_args()\n"
			"flag = Path(a.root) / 'fail_once'\n"
			"if not flag.exists():\n\tflag.write_text('x')\n\tprint('simulated build failure')\n\tsys.exit(3)\n"
			"d = Path(a.install_dir)\nd.mkdir(parents=True, exist_ok=True)\n"
			"(d / 'pack.json').write_text(json.dumps({'format': 'hayday-sandbox-asset-pack', 'id': 'hayday_original', "
			"'version': '1', 'sprites': {'bakery': {'file': 'items/bakery.png'}}}))\nprint('built')\n")
		(tools / "helper_local.py").write_text("X = 1\n")
		req, opt = script_imports(tools / "build_pack.py")
		if req != {"numpy"} or opt != {"zz_optional_mod"}:
			fails.append(f"import scan build_pack: req={req} opt={opt}")
		req, opt = script_imports(tools / "fetch_wiki.py")
		if req != {"requests"}:
			fails.append(f"import scan fetch_wiki (exit in handler = required): req={req} opt={opt}")
		real = TOOLS_DIR / "extract_from_apk.py"
		if real.is_file():
			req, opt = script_imports(real)
			if not {"numpy", "PIL", "cryptography", "zstandard"} <= req or "lzham" in req or "pyasn1" in req:
				fails.append(f"import scan extract_from_apk: req={sorted(req)} opt={sorted(opt)}")
		env_args = ["--tools-dir", str(tools), "--root", str(root), "--install-dir", str(inst), "--no-pip"]
		me = [sys.executable, str(Path(__file__).resolve())]

		def run(extra: list[str]) -> subprocess.CompletedProcess:
			return subprocess.run(me + env_args + extra, capture_output=True, text=True, timeout=300)

		r = run(["--dry-run"])
		if r.returncode != 0 or root.exists() or "fetch_fankit.py" not in r.stdout:
			fails.append(f"dry run: rc={r.returncode} root_created={root.exists()} out={r.stdout[-400:]}")
		r = run([])
		if r.returncode != 1 or "simulated build failure" not in r.stdout or "FAILED" not in r.stdout:
			fails.append(f"first run must fail at build: rc={r.returncode} {r.stdout[-600:]}")
		st = json.loads((root / STATE_FILE).read_text())
		if [st["steps"][s]["status"] for s in ("fankit", "wiki", "wiki_ru", "build")] != ["done", "done", "done", "failed"]:
			fails.append(f"state after failure: {st['steps']}")
		if (root / LOCK_FILE).exists():
			fails.append("lock file left behind")
		r = run([])
		if r.returncode != 0 or "1 sprites installed" not in r.stdout or "done (earlier)" not in r.stdout:
			fails.append(f"resume run: rc={r.returncode} {r.stdout[-600:]}")
		if (root / "raw" / "fankit" / "count").read_text() != "1":
			fails.append("finished fankit step must be skipped on resume")
		r = run(["--refresh", "--steps", "fankit"])
		if r.returncode != 0 or (root / "raw" / "fankit" / "count").read_text() != "2":
			fails.append(f"--refresh must re-run fankit: rc={r.returncode}")
		if not list((root / "logs").glob("acquire_build_*.log")):
			fails.append("no step log written")
		r = run(["--steps", "apk"])
		if r.returncode != 1 or "no --apk file given" not in r.stdout:
			fails.append(f"apk without --apk must fail clearly: rc={r.returncode} {r.stdout[-300:]}")
		gitroot = tmp / "somerepo"
		(gitroot / ".git").mkdir(parents=True)
		r = subprocess.run(me + ["--tools-dir", str(tools), "--root", str(gitroot / "priv"), "--install-dir", str(inst),
			"--no-pip"], capture_output=True, text=True)
		if r.returncode == 0 or "refusing" not in (r.stdout + r.stderr) or (gitroot / "priv").exists():
			fails.append(f"root inside a git work tree must be refused: rc={r.returncode} {r.stderr[-300:]}")
		r = subprocess.run(me + ["--tools-dir", str(tools), "--root", str(root), "--install-dir",
			str(gitroot / "user" / "hayday_original"), "--no-pip", "--steps", "build"], capture_output=True, text=True)
		if r.returncode == 0 or "refusing" not in (r.stdout + r.stderr):
			fails.append(f"install dir inside a git work tree must be refused: rc={r.returncode}")
		# build step flags: --build-world / --terrain only when their private inputs exist
		t2 = tmp / "tools2"
		t2.mkdir()
		(t2 / "build_pack.py").write_text("import argparse\nap = argparse.ArgumentParser()\nfor f in ('--root', '--install-dir'):"
			"\n\tap.add_argument(f)\nfor f in ('--build-world', '--no-world', '--terrain', '--no-terrain'):\n\tap.add_argument(f, "
			"action='store_true')\nap.parse_args()\n")
		r2 = tmp / "private2"
		ns = argparse.Namespace(root=r2, install_dir=inst, build_arg=[])
		(r2 / "raw" / "apk_extracted" / "9.9" / "assets" / "sc").mkdir(parents=True)
		(r2 / "raw" / "apk_extracted" / "9.9" / "assets" / "sc" / "background.sc").write_bytes(b"x")
		cmd = step_commands("build", ns, t2)[0][0]
		if "--terrain" in cmd:
			fails.append(f"--terrain without the placement file: {cmd}")
		(r2 / "research" / "terrain").mkdir(parents=True)
		(r2 / "research" / "terrain" / "terrain_manifest.json").write_text("{}")
		cmd = step_commands("build", ns, t2)[0][0]
		if "--terrain" not in cmd or "--build-world" in cmd:
			fails.append(f"build step flags (terrain yes, world no): {cmd}")
		ns.build_arg = ["--no-terrain"]
		if "--terrain" in step_commands("build", ns, t2)[0][0]:
			fails.append("--build-arg --no-terrain must suppress --terrain")
	finally:
		shutil.rmtree(tmp, ignore_errors=True)
	for f in fails:
		print("SELF-TEST FAIL:", f)
	print(f"acquire self-test: {'OK' if not fails else f'{len(fails)} failure(s)'}")
	return 1 if fails else 0


if __name__ == "__main__":
	sys.exit(main())
