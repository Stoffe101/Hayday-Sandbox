# Shared helpers for the Windows check runners (windows_checks.ps1, visual_tests.ps1).
# Dot-source this file. Windows PowerShell 5.1 compatible.

function Resolve-Godot {
	## GODOT from the process or user environment, then `godot` on PATH.
	foreach ($c in @($env:GODOT, [Environment]::GetEnvironmentVariable('GODOT', 'User'))) {
		if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
	}
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw 'Godot not found. Set the GODOT environment variable to the Godot 4.7.2 executable.'
}

function Resolve-Python {
	$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
	$venv = Join-Path $root '.venv\Scripts\python.exe'
	if (Test-Path -LiteralPath $venv) { return $venv }
	$cmd = Get-Command python -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw 'Python 3 not found.'
}

function New-IsolatedDataDir {
	## A fresh folder to use as APPDATA for a child Godot, so the real user data
	## (layouts, settings, any installed asset pack) is neither read nor changed.
	$dir = Join-Path ([IO.Path]::GetTempPath()) ('hayday-iso-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $dir | Out-Null
	return $dir
}

function Enter-GodotLock {
	## Serialises Godot runs from parallel shells (an import rewrites the .godot cache that every
	## other run reads). Returns the held mutex; pass it to Exit-GodotLock.
	param([int] $TimeoutSec = 3600)
	$m = New-Object System.Threading.Mutex($false, 'Local\HaydaySandboxGodot')
	try {
		if (-not $m.WaitOne($TimeoutSec * 1000)) { $m.Dispose(); throw "Timed out after $TimeoutSec s waiting for another Godot run to finish." }
	} catch [System.Threading.AbandonedMutexException] {
		# The previous holder exited without releasing it; we own it now.
	}
	return $m
}

function Exit-GodotLock($m) {
	if ($m) { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
}

function Invoke-Logged {
	## Runs an executable with stdout+stderr captured to $Log. Returns the exit code,
	## or 124 on timeout. $AppData, when given, overrides APPDATA for the child only.
	param(
		[Parameter(Mandatory)] [string] $Exe,
		[Parameter(Mandatory)] [string[]] $Arguments,
		[Parameter(Mandatory)] [string] $Log,
		[string] $AppData = '',
		[int] $TimeoutSec = 900
	)
	# .NET resolves relative paths against the process folder, not the PowerShell location.
	$Log = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Log)
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = $Exe
	$psi.Arguments = (($Arguments | ForEach-Object {
		if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
	}) -join ' ')
	$psi.UseShellExecute = $false
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$psi.WorkingDirectory = (Get-Location).Path
	if ($AppData) { $psi.EnvironmentVariables['APPDATA'] = $AppData }
	$p = [System.Diagnostics.Process]::Start($psi)
	$out = $p.StandardOutput.ReadToEndAsync()
	$err = $p.StandardError.ReadToEndAsync()
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		try { $p.Kill() } catch { }
		$p.WaitForExit() | Out-Null
		[IO.File]::WriteAllText($Log, $out.Result + "`n" + $err.Result + "`nTIMEOUT after $TimeoutSec s`n")
		return 124
	}
	$p.WaitForExit()
	[IO.File]::WriteAllText($Log, $out.Result + "`n" + $err.Result)
	return $p.ExitCode
}
