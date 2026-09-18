# Godot CLI validation on Windows: --no-window + Start-Process redirects

Godot 3.6.2-stable's Windows exe is GUI-subsystem and has neither `--headless` nor `--script-check`. A direct `godot --script-check file.gd` call makes Godot treat the `.gd` path as a project path and silently opens the Project Manager, blocking forever; piping stdout instead of capturing it makes both output and exit code vanish. Every automated Godot invocation in this repo (`mod/tests/check.ps1` for script checks, `mod/tests/run.ps1` for the GhostDb suite) therefore uses `--no-window` with an explicit `--path`, captures output through `Start-Process -RedirectStandardOutput/-RedirectStandardError -Wait -PassThru`, and judges parse failures by `SCRIPT ERROR` / `Parse Error` text because Godot exits 0 even on failed parses.

## Considered options

- Direct exe call with piped stdout: rejected — GUI-subsystem hides stdout and exit code.
- `--headless`: rejected — flag does not exist in 3.6.2 (Godot 4+); silently ignored, opens a real window on every run.
- `--script-check`: rejected — flag does not exist in 3.6.2; triggers the Project Manager trap.
