# Windows equivalent of the CI checks. Usage (from anywhere):
#   powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1 [-Perf] [-SkipImport] [-Tag name]
# Logs go to artifacts\checks\[name\]. Godot children run headless against a throw-away APPDATA.
param([switch] $Perf, [switch] $SkipImport, [string] $Tag = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_common.ps1')
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

$godot = Resolve-Godot
$python = Resolve-Python
$logs = 'artifacts\checks'
if ($Tag) { $logs = Join-Path $logs $Tag }
New-Item -ItemType Directory -Force -Path $logs | Out-Null
if (-not (Test-Path 'artifacts\.gdignore')) { New-Item -ItemType File -Path 'artifacts\.gdignore' | Out-Null }

$results = New-Object System.Collections.ArrayList
$iso = New-IsolatedDataDir
$lock = Enter-GodotLock

function Step {
	# A script that fails to parse can leave a selftest waiting forever, so keep timeouts short.
	param([string] $Name, [string] $Exe, [string[]] $Arguments, [string] $MustMatch = '', [switch] $Isolate, [int] $Timeout = 300)
	$log = Join-Path $logs "$Name.log"
	$sw = [Diagnostics.Stopwatch]::StartNew()
	$data = ''
	if ($Isolate) { $data = $iso }
	$rc = Invoke-Logged -Exe $Exe -Arguments $Arguments -Log $log -AppData $data -TimeoutSec $Timeout
	$sw.Stop()
	$ok = ($rc -eq 0)
	if ($MustMatch) { $ok = $ok -and [bool](Select-String -LiteralPath $log -Pattern $MustMatch -Quiet) }
	$status = 'FAIL'
	if ($ok) { $status = 'PASS' }
	[void] $results.Add([pscustomobject] @{ Check = $Name; Status = $status; Exit = $rc; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) })
}

try {
	if (-not $SkipImport) {
		# Godot imports everything under the project folder, so a private folder here
		# would end up in the .godot cache. It belongs outside the repository.
		if (Test-Path -LiteralPath 'hayday-sandbox-private-assets') {
			throw 'hayday-sandbox-private-assets is inside the repository; move it out before importing.'
		}
		# The editor import rewrites project.godot (drops comments and default values).
		$projectBytes = [IO.File]::ReadAllBytes((Join-Path (Get-Location).Path 'project.godot'))
		Step 'import' $godot @('--headless', '--path', '.', '--import') -Isolate
		[IO.File]::WriteAllBytes((Join-Path (Get-Location).Path 'project.godot'), $projectBytes)
	}
	Step 'check_scripts' $godot @('--headless', '--path', '.', '--script', 'res://tools/ci/check_scripts.gd') -Isolate
	Step 'unit_tests' $godot @('--headless', '--path', '.', '--script', 'res://tests/run_tests.gd') -Isolate
	Step 'selftest' $godot @('--headless', '--path', '.', '--', '--selftest') -MustMatch 'SELFTEST PASS' -Isolate
	if ($Perf) {
		Step 'selftest_perf' $godot @('--headless', '--path', '.', '--', '--selftest=perf') -MustMatch 'SELFTEST PASS' -Isolate -Timeout 1800
	}
	Step 'validate_data' $python @('tools/ci/validate_data.py')
	Step 'leak_guard_selftest' $python @('tools/ci/check_private_leaks.py', '--self-test')
	Step 'export_check_selftest' $python @('tools/ci/check_export_contents.py', '--self-test')
	Step 'leak_guard' $python @('tools/ci/check_private_leaks.py')
	Step 'coverage_report' $python @('tools/catalog/coverage_report.py')
	Step 'coverage_diff' 'git' @('diff', '--exit-code', '--ignore-space-at-eol', 'docs/CATALOG_COVERAGE.md')
}
finally {
	Exit-GodotLock $lock
	Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize | Out-String -Width 120 | Write-Output
if ($results | Where-Object { $_.Status -ne 'PASS' }) { exit 1 }
exit 0
