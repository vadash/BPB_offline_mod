# Runs the GhostDb test suite headless.
# Godot's Windows exe is GUI-subsystem: with piped stdout it runs but hides
# both output and exit code from PowerShell. Start-Process with file redirects
# captures both reliably. Godot also exits 0 even when the -s script fails to
# parse, so any "SCRIPT ERROR" in the output forces a failure.
$ErrorActionPreference = "Stop"

$out = Join-Path $env:TEMP "bpb-tests-out.txt"
$err = Join-Path $env:TEMP "bpb-tests-err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath 'C:\portable\godot\Godot_v3.6.2-stable_win64.exe' `
	-ArgumentList @('--no-window', '--path', "`"$PSScriptRoot`"", '-s', 'res://run_tests.gd') `
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
