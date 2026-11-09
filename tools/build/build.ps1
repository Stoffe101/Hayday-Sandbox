# Windows build: exports the portable app, bundles licences, checks that the export contains no private
# art, and smoke-tests the exported .exe headless with a throw-away APPDATA (no window, real data untouched).
#   powershell -ExecutionPolicy Bypass -File tools\build\build.ps1 [-Mode release|debug]
param([ValidateSet('release', 'debug')] [string] $Mode = 'release')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ci\windows_common.ps1')
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

$godot = Resolve-Godot
$python = Resolve-Python
# The GUI-subsystem exe only prints when its output is redirected.
$verLog = Join-Path ([IO.Path]::GetTempPath()) 'hayday-godot-version.txt'
[void] (Invoke-Logged -Exe $godot -Arguments @('--version') -Log $verLog -TimeoutSec 60)
$ver = ((Get-Content -LiteralPath $verLog | Where-Object { $_ -match '^\d+\.\d+' } | Select-Object -First 1) -split '\.stable')[0]
Remove-Item -LiteralPath $verLog -Force -ErrorAction SilentlyContinue
$tpl = Join-Path $env:APPDATA "Godot\export_templates\$ver.stable\windows_${Mode}_x86_64.exe"
if (-not (Test-Path -LiteralPath $tpl)) { throw "Export template missing: $tpl (Godot editor: Editor > Manage Export Templates)." }
if (Test-Path -LiteralPath 'override.cfg') { throw 'override.cfg exists (a visual test is running); it must not be exported.' }

$logs = 'artifacts\checks\build'
New-Item -ItemType Directory -Force -Path $logs, 'build\windows', 'build\smoke' | Out-Null
$iso = New-IsolatedDataDir
$fail = $false
function Check([string] $name, [bool] $ok, [string] $detail = '') {
	$s = 'FAIL'; if ($ok) { $s = 'PASS' } else { $script:fail = $true }
	Write-Output ('{0,-22} {1} {2}' -f $name, $s, $detail)
}
try {
	$projectBytes = [IO.File]::ReadAllBytes((Join-Path (Get-Location).Path 'project.godot'))
	# Import and export run the editor, which needs the real APPDATA for its export templates.
	# Neither runs the app, so no layouts or asset packs are read.
	[void] (Invoke-Logged -Exe $godot -Arguments @('--headless', '--path', '.', '--import') -Log "$logs\import.log")
	$exe = (Resolve-Path 'build\windows').Path + '\HaydaySandbox.exe'
	if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
	$rc = Invoke-Logged -Exe $godot -Arguments @('--headless', '--path', '.', "--export-$Mode", 'Windows Desktop', $exe) -Log "$logs\export.log"
	[IO.File]::WriteAllBytes((Join-Path (Get-Location).Path 'project.godot'), $projectBytes)
	$built = Test-Path -LiteralPath $exe
	$size = ''; if ($built) { $size = "{0:N1} MB" -f ((Get-Item -LiteralPath $exe).Length / 1MB) }
	Check 'export' ($rc -eq 0 -and $built) $size
	if (-not $built) { throw "Export failed; see $logs\export.log" }

	# Portable bundle
	Copy-Item README.md build\windows\README.md -Force
	New-Item -ItemType Directory -Force -Path build\windows\licenses | Out-Null
	Copy-Item assets\ui\fonts\OFL.txt build\windows\licenses\Nunito-OFL.txt -Force
	Copy-Item assets\ui\LUCIDE_LICENSE.txt build\windows\licenses\Lucide-ISC.txt -Force
	if (Test-Path LICENSE) { Copy-Item LICENSE build\windows\licenses\HaydaySandbox-LICENSE.txt -Force }
	if (Test-Path docs\THIRD_PARTY_NOTICES.md) { Copy-Item docs\THIRD_PARTY_NOTICES.md build\windows\licenses\ -Force }
	$zip = 'build\HaydaySandbox-windows-x86_64.zip'
	if (Test-Path $zip) { Remove-Item $zip -Force }
	Compress-Archive -Path build\windows -DestinationPath $zip

	# Export leak guard (docs/PRIVATE_ASSETS.md). A failure deletes the zip.
	$rc = Invoke-Logged -Exe $python -Arguments @('tools/ci/check_export_contents.py', $exe, $zip, 'build/windows') -Log "$logs\export_contents.log"
	if ($rc -ne 0) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
	Check 'export_contents' ($rc -eq 0) ((Get-Content "$logs\export_contents.log" | Where-Object { $_.Trim() } | Select-Object -Last 1))

	# Smoke test 1: the exported app starts headless and runs 300 frames without script errors.
	$rc = Invoke-Logged -Exe $exe -Arguments @('--headless', '--quit-after', '300') -Log "$logs\smoke_start.log" -AppData $iso -TimeoutSec 180
	$errs = @(Select-String -LiteralPath "$logs\smoke_start.log" -Pattern 'SCRIPT ERROR|Parse Error|Failed to load').Count
	Check 'smoke_start' ($rc -eq 0 -and $errs -eq 0) "exit $rc, $errs script errors"

	# Smoke test 2: the exported app installs an asset pack (synthetic, built from CC0 placeholders).
	$pack = (Resolve-Path 'build\smoke').Path + '\synthetic_pack.zip'
	[void] (Invoke-Logged -Exe $godot -Arguments @('--headless', '--path', '.', '--script', 'res://tools/build/make_synthetic_pack.gd', '--', $pack) -Log "$logs\synthetic_pack.log" -AppData $iso)
	$rc = Invoke-Logged -Exe $exe -Arguments @('--headless', '--', "--install-pack=$pack", '--quit-after-install') -Log "$logs\smoke_install.log" -AppData $iso -TimeoutSec 180
	$line = (Select-String -LiteralPath "$logs\smoke_install.log" -Pattern '^INSTALL-PACK ' | Select-Object -First 1).Line
	$installed = Test-Path (Join-Path $iso 'HaydaySandbox\asset_packs')
	Check 'smoke_install_pack' ($rc -eq 0 -and $installed) "exit $rc; $line"
}
finally {
	Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { exit 1 }
exit 0
