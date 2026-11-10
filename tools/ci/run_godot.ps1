# Runs one headless Godot command for this project under the shared Godot lock (so parallel shells never
# import and test at the same time) with a throw-away APPDATA. Prints the log, returns Godot's exit code.
#   powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --script res://tests/run_tests.gd -- --filter=budget
#   powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --import
#   powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 -- --selftest
# "--headless --path ." is added in front. Leading "-Log <file>" and "-TimeoutSec <s>" are this script's own;
# everything else goes to Godot unchanged (no param() block: PowerShell would try to bind "--script" itself).
$Log = ''
$TimeoutSec = 900
$GodotArgs = @($args)
while ($GodotArgs.Count -ge 2 -and ($GodotArgs[0] -eq '-Log' -or $GodotArgs[0] -eq '-TimeoutSec')) {
	if ($GodotArgs[0] -eq '-Log') { $Log = [string] $GodotArgs[1] } else { $TimeoutSec = [int] $GodotArgs[1] }
	$GodotArgs = @($GodotArgs | Select-Object -Skip 2)
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_common.ps1')
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

$godot = Resolve-Godot
if (-not $GodotArgs) { $GodotArgs = @() }
$importing = $GodotArgs -contains '--import'
if ($importing -and (Test-Path -LiteralPath 'hayday-sandbox-private-assets')) {
	throw 'hayday-sandbox-private-assets is inside the repository; move it out before importing.'
}
$keep = $Log
if (-not $Log) { $Log = Join-Path ([IO.Path]::GetTempPath()) ('hayday-run-' + [Guid]::NewGuid().ToString('N') + '.log') }
$iso = New-IsolatedDataDir
$lock = Enter-GodotLock
try {
	$projectBytes = [IO.File]::ReadAllBytes((Join-Path (Get-Location).Path 'project.godot'))
	$rc = Invoke-Logged -Exe $godot -Arguments (@('--headless', '--path', '.') + $GodotArgs) -Log $Log -AppData $iso -TimeoutSec $TimeoutSec
	# An import rewrites project.godot (drops comments and default values); keep the file as it was.
	if ($importing) { [IO.File]::WriteAllBytes((Join-Path (Get-Location).Path 'project.godot'), $projectBytes) }
}
finally {
	Exit-GodotLock $lock
	Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
}
Get-Content -LiteralPath $Log | Write-Output
if (-not $keep) { Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue }
if ($rc -eq 124) { Write-Output "TIMEOUT after $TimeoutSec s" }
exit $rc
