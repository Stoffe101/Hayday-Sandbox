# Windows equivalent of visual_tests.sh: renders the real app with OpenGL at the given
# resolutions / UI scales and saves screenshots to artifacts\screens\.
# Usage: powershell -ExecutionPolicy Bypass -File tools\ci\visual_tests.ps1 [scenarios] [WxH:scale ...]
# Each configuration gets a fresh APPDATA, so an installed asset pack can never appear
# in these screenshots and the real user data is never touched.
param(
	[Parameter(Position = 0)] [string] $Scenarios = 'all',
	[Parameter()] [int] $TimeoutSec = 300,
	[Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Configs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_common.ps1')
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

if (-not $Configs -or $Configs.Count -eq 0) { $Configs = @('1920x1080:1', '2560x1440:1.25', '3440x1440:1', '3840x2160:2') }
$godot = Resolve-Godot
$out = 'artifacts\screens'
$logs = 'artifacts\checks'
New-Item -ItemType Directory -Force -Path $out, $logs | Out-Null
if (-not (Test-Path 'artifacts\.gdignore')) { New-Item -ItemType File -Path 'artifacts\.gdignore' | Out-Null }

# Keep the capture window out of the user's way: it never takes focus, opens tiny, and
# capture.gd moves it off-screen at startup (Godot clamps new windows onto a monitor).
# It can't be minimized instead, because a minimized Godot window stops drawing.
$lock = Enter-GodotLock
$overrideCfg = Join-Path (Get-Location).Path 'override.cfg'
if (Test-Path -LiteralPath $overrideCfg) { Exit-GodotLock $lock; throw 'override.cfg already exists in the project folder; remove it first.' }
[IO.File]::WriteAllText($overrideCfg, @'
[display]

window/size/mode=0
window/size/borderless=true
window/size/no_focus=true
window/size/window_width_override=64
window/size/window_height_override=64
'@)

$fail = 0
try {
foreach ($cfg in $Configs) {
	$res, $scale = $cfg -split ':'
	$iso = New-IsolatedDataDir
	$log = Join-Path $logs ("visual_{0}_{1}.log" -f $res, $scale)
	try {
		# capture.gd resizes the window itself: the project starts maximized, which
		# would otherwise clamp it to the monitor.
		$rc = Invoke-Logged -Exe $godot -Log $log -AppData $iso -TimeoutSec $TimeoutSec -Arguments @(
			'--path', '.', '--rendering-driver', 'opengl3', '--audio-driver', 'Dummy',
			'--', '--capture', "--window-size=$res", "--out=$($out -replace '\\', '/')", "--scale=$scale", "--scenarios=$Scenarios"
		)
		$lines = Select-String -LiteralPath $log -Pattern '^(SHOT|FAIL|EXPORT)|SCRIPT ERROR'
		$lines | ForEach-Object { Write-Output $_.Line }
		if ($rc -ne 0 -or (Select-String -LiteralPath $log -Pattern '^FAIL|SCRIPT ERROR' -Quiet)) { $fail = 1 }
	}
	finally {
		Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
	}
}
}
finally {
	Remove-Item -LiteralPath $overrideCfg -Force -ErrorAction SilentlyContinue
	Exit-GodotLock $lock
}
exit $fail
