<#
.SYNOPSIS
  One command to (re)build the PRIVATE original-art pack for Hayday Sandbox on Windows.

.DESCRIPTION
  1. Finds Python 3.10+ (the "py" launcher, then python/python3 on PATH, then the usual install folders).
     With -InstallPython it installs Python 3.12 with winget when none is found; otherwise it prints the command.
  2. Creates a virtual environment in <Root>\.venv (so nothing is installed into your system Python).
  3. Runs tools\private_assets\acquire.py inside it: downloads the Fan Kit and Hay Day Wiki images politely and
     resumably into <Root>\raw, builds the pack and installs it into
     %APPDATA%\HaydaySandbox\asset_packs\hayday_original where the app finds it.
  Re-running the same command resumes; finished steps are skipped.

  The files are proprietary Supercell art for YOUR PERSONAL USE in this app only: never commit, share, upload or
  redistribute them. See docs\PRIVATE_ASSETS.md.

.PARAMETER Root
  Private storage folder (default: %USERPROFILE%\hayday-sandbox-private-assets). Must not be inside a git repository.

.PARAMETER InstallDir
  Where the app reads the pack (default: %APPDATA%\HaydaySandbox\asset_packs\hayday_original).

.PARAMETER InstallPython
  If no Python 3.10+ is found, install Python 3.12 for the current user with winget.

.PARAMETER Steps
  Comma list of steps for acquire.py: fankit, wiki, wiki_ru, apk, build (default: all that apply).

.PARAMETER Apk
  An APK / XAPK file (or folder) you already have, e.g. pulled from your own phone. Enables the "apk" step.

.PARAMETER DryRun
  Show what would run; download, install and write nothing (still creates the virtual environment).

.PARAMETER Refresh
  Re-run finished download steps (incremental) to pick up new files.

.PARAMETER AcquireArgs
  Anything else is passed to acquire.py unchanged, after a "--", e.g.  -- --keep-going --pip opencv-python-headless

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\private_assets\Acquire-HaydayAssets.ps1

.EXAMPLE
  .\tools\private_assets\Acquire-HaydayAssets.ps1 -InstallPython -DryRun

.EXAMPLE
  .\tools\private_assets\Acquire-HaydayAssets.ps1 -Steps build      # rebuild + reinstall the pack only
#>
[CmdletBinding()]
param(
	[string]$Root = "",
	[string]$InstallDir = "",
	[switch]$InstallPython,
	[string]$Steps = "",
	[string]$Apk = "",
	[switch]$DryRun,
	[switch]$Refresh,
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$AcquireArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$onWindows = ($env:OS -eq 'Windows_NT')

if (-not $Root) {
	if ($env:HAYDAY_PRIVATE_ASSETS) { $Root = $env:HAYDAY_PRIVATE_ASSETS }
	elseif ($onWindows) { $Root = Join-Path $env:USERPROFILE 'hayday-sandbox-private-assets' }
	else { $Root = Join-Path $HOME 'hayday-sandbox-private-assets' }
}
if (-not $InstallDir) {
	if ($onWindows) { $InstallDir = Join-Path $env:APPDATA 'HaydaySandbox\asset_packs\hayday_original' }
	else {
		$dataHome = $env:XDG_DATA_HOME
		if (-not $dataHome) { $dataHome = Join-Path $HOME '.local/share' }
		$InstallDir = Join-Path $dataHome 'HaydaySandbox/asset_packs/hayday_original'
	}
}
$acquire = Join-Path $PSScriptRoot 'acquire.py'
if (-not (Test-Path -LiteralPath $acquire)) { throw "acquire.py not found next to this script ($acquire)" }

function Test-PythonCandidate([string]$exe, [string[]]$pre) {
	# Returns the interpreter path for Python >= 3.10, else $null. The Microsoft Store "python" alias exits non-zero.
	try {
		$out = & $exe @pre -c "import sys; print('%d.%d|%s' % (sys.version_info[0], sys.version_info[1], sys.executable))" 2>$null
	} catch { return $null }
	if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
	$parts = ("$out".Trim()) -split '\|', 2
	$ver = $parts[0] -split '\.'
	if ([int]$ver[0] -eq 3 -and [int]$ver[1] -ge 10) { return $parts[1] }
	return $null
}

function Find-Python {
	$cands = @(@{exe = 'py'; pre = @('-3') }, @{exe = 'python'; pre = @() }, @{exe = 'python3'; pre = @() })
	foreach ($c in $cands) {
		if (Get-Command $c.exe -ErrorAction SilentlyContinue) {
			$p = Test-PythonCandidate $c.exe $c.pre
			if ($p) { return $p }
		}
	}
	# Fresh installs are not on PATH in this session yet: look in the default folders.
	$globs = @()
	if ($env:LOCALAPPDATA) { $globs += (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe') }
	if ($env:ProgramFiles) { $globs += (Join-Path $env:ProgramFiles 'Python3*\python.exe') }
	foreach ($g in $globs) {
		foreach ($f in @(Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
			$p = Test-PythonCandidate $f.FullName @()
			if ($p) { return $p }
		}
	}
	return $null
}

function Get-GitWorkTree([string]$path) {
	# The folder (or its nearest existing parent) inside a git work tree -> that tree's root, else $null.
	$p = [System.IO.Path]::GetFullPath($path)
	while ($p) {
		if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $p }
		$parent = [System.IO.Path]::GetDirectoryName($p)
		if (-not $parent -or $parent -eq $p) { break }
		$p = $parent
	}
	return $null
}

foreach ($pair in @(@{path = $Root; what = 'private root' }, @{path = $InstallDir; what = 'install dir' })) {
	$wt = Get-GitWorkTree $pair.path
	if ($wt) {
		Write-Host "Refusing: the $($pair.what) $($pair.path) is inside the git work tree $wt." -ForegroundColor Red
		Write-Host "Private art must live outside any repository (default: %USERPROFILE%\hayday-sandbox-private-assets)."
		exit 2
	}
}

Write-Host "Hayday Sandbox - private art pack (personal use only, never redistribute)"
Write-Host "  private root : $Root"
Write-Host "  install dir  : $InstallDir"

$py = Find-Python
if (-not $py) {
	if ($InstallPython -and (Get-Command winget -ErrorAction SilentlyContinue)) {
		Write-Host "Python 3.10+ not found - installing Python 3.12 for the current user with winget ..."
		& winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
		$py = Find-Python
	}
	if (-not $py) {
		Write-Host ""
		Write-Host "Python 3.10 or newer is required but was not found." -ForegroundColor Red
		Write-Host "Install it with:   winget install -e --id Python.Python.3.12 --scope user"
		Write-Host "or from https://www.python.org/downloads/ (tick 'Add python.exe to PATH'), then run this again."
		Write-Host "Or re-run with -InstallPython to let this script call winget for you."
		exit 1
	}
}
Write-Host "  python       : $py"

New-Item -ItemType Directory -Force -Path $Root | Out-Null
$venv = Join-Path $Root '.venv'
if ($onWindows) { $vpy = Join-Path $venv 'Scripts\python.exe' } else { $vpy = Join-Path $venv 'bin/python' }
if (-not (Test-Path -LiteralPath $vpy)) {
	Write-Host "Creating virtual environment $venv ..."
	& $py -m venv $venv
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vpy)) { throw "could not create the virtual environment in $venv" }
	& $vpy -m pip install --disable-pip-version-check --quiet --upgrade pip
}

$rest = @()
if ($Steps) { $rest += @('--steps', $Steps) }
if ($Apk) { $rest += @('--apk', $Apk) }
if ($DryRun) { $rest += '--dry-run' }
if ($Refresh) { $rest += '--refresh' }
if ($AcquireArgs) { $rest += @($AcquireArgs | Where-Object { $_ -ne '--' }) }
& $vpy $acquire --root $Root --install-dir $InstallDir @rest
$rc = $LASTEXITCODE
if ($rc -eq 0) { Write-Host "Done. Start Hayday Sandbox; the pack is listed in the Asset Manager (Ctrl+Shift+A) -> Packs." -ForegroundColor Green }
else { Write-Host "acquire.py exited with code $rc - re-run this command to resume." -ForegroundColor Yellow }
exit $rc
