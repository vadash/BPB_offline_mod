# Compile-checks the mod's Core scripts by running the project's check scene
# (check.tscn -> check_scene.gd): copies the scripts in from mod.unpacked,
# loads and can_instance()s each, exits nonzero on any failure.
# Normal scene run mode is required: -s/--check-only script mode does not
# register global classes from the script class cache, and the adapter
# references the game classes RunDatabase/SteamHelper/RunData (the stubs and
# .godot cache make those resolvable in scene mode).
# Godot 3.6.2 has NO --headless flag (Godot 4+ only); --no-window hides the
# window instead. GUI-subsystem exe: piped stdout and exit code vanish, so
# Start-Process file redirects capture both. Godot exits 0 even on parse
# errors, so any "SCRIPT ERROR" in the output forces a failure.
$ErrorActionPreference = "Stop"

$out = Join-Path $env:TEMP "bpb-check-out.txt"
$err = Join-Path $env:TEMP "bpb-check-err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath 'C:\portable\godot\Godot_v3.6.2-stable_win64.exe' `
	-ArgumentList @('--no-window', '--path', "`"$PSScriptRoot`"") `
	-NoNewWindow -Wait -PassThru `
	-RedirectStandardOutput $out -RedirectStandardError $err

Get-Content $out
Get-Content $err

$combined = (Get-Content $out -Raw) + (Get-Content $err -Raw)
if ("$combined" -match "SCRIPT ERROR") {
	Write-Host "HARNESS FAIL: Godot reported a script error."
	exit 1
}
exit $proc.ExitCode
