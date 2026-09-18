# Game-level regression check for the mod (ADR 0002, ADR 0001): the real
# game is the only seam that executes game-class code, so crash regressions
# (0xc0000005 from game decode calls, mod parse errors) can only be caught
# here. Launches the game with a given ghost_filter.json variant, waits for
# a new crash entry in crashes.txt, kills the game, restores the filter
# file, prints the mod log tail. Run after every mod rebuild:
#   powershell -File repro-crash.ps1 -Variant keep
# RED   = exit 1 (new crash entry)
# GREEN = exit 0 (game survived the window)
param(
	[ValidateSet('keep', 'none', 'classes-only', 'items-only')]
	[string]$Variant = 'keep',
	[string]$GameDir = 'C:\Games\BackpackBattles',
	[int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$gameDir = $GameDir
$exe = Join-Path $gameDir 'BackpackBattles.exe'
$crashLog = Join-Path $gameDir 'crashes.txt'
$filter = Join-Path $gameDir 'ghost_filter.json'
$filterBak = Join-Path $env:TEMP 'ghost_filter.bak.json'
$modLog = Join-Path $gameDir 'bbof.log'

function Get-CrashCount {
	if (-not (Test-Path $crashLog)) { return 0 }
	return @(Select-String -Path $crashLog -Pattern 'Unhandled exception').Count
}

if (Get-Process -Name 'BackpackBattles' -ErrorAction SilentlyContinue) {
	Write-Host 'LOOP INVALID: game already running; close it first.'
	exit 2
}

$before = Get-CrashCount
$hadFilter = Test-Path $filter
try {
	switch ($Variant) {
		'none' {
			if ($hadFilter) { Copy-Item $filter $filterBak -Force; Remove-Item $filter }
			Write-Host 'variant=none (filter file hidden)'
		}
		'classes-only' {
			Copy-Item $filter $filterBak -Force
			Set-Content -Path $filter -Value '{ "exclude_classes": ["Engineer"], "exclude_items": [] }' -Encoding ASCII
			Write-Host 'variant=classes-only'
		}
		'items-only' {
			Copy-Item $filter $filterBak -Force
			Set-Content -Path $filter -Value '{ "exclude_classes": [], "exclude_items": ["False Life", "Holy Armor"] }' -Encoding ASCII
			Write-Host 'variant=items-only'
		}
		'keep' { Write-Host 'variant=keep (as the user left it)' }
	}

	if (Test-Path $modLog) { Remove-Item $modLog -Force }

	$proc = Start-Process -FilePath $exe -PassThru
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$crashed = $false
	while ((Get-Date) -lt $deadline) {
		Start-Sleep -Milliseconds 500
		if ($proc.HasExited) { $crashed = $true; break }
		if ((Get-CrashCount) -gt $before) { $crashed = $true; break }
	}
	$killedByLoop = $false
	if (-not $proc.HasExited) {
		Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
		$killedByLoop = $true
	}
	Start-Sleep -Milliseconds 500

	$after = Get-CrashCount
	Write-Host ("crash entries: before={0} after={1}" -f $before, $after)

	# Effectiveness check: an items-only run must prove item exclusions
	# actually dropped ghosts (decode could silently return null for every
	# round and still be "green"). The filter line logs kept/filtered/rules.
	if (-not $crashed -and $Variant -eq 'items-only') {
		$filterLine = Select-String -Path $modLog -Pattern 'filter kept=\d+ filtered=\d+ rules=\{.*item=' |
			Select-Object -Last 1
		if (-not $filterLine) {
			Write-Host 'VERDICT: RED (item exclusions matched nothing - decode broken or no matches)'
			exit 1
		}
		Write-Host ("effectiveness: {0}" -f $filterLine.Line.Trim())
	}

	if ($crashed -and $after -gt $before) {
		$lines = Get-Content $crashLog
		# newest crash entry = everything after the previous entry's separator
		$idx = @($lines | Select-String -Pattern '\*{5,}').LineNumber
		if ($idx.Count -ge 2) {
			Write-Host '--- newest crash entry (head) ---'
			$lines[($idx[-2] - 1)..([Math]::Min($lines.Count - 1, $idx[-1] - 1 + 8))]
		}
		Write-Host 'VERDICT: RED'
		exit 1
	}
	elseif ($killedByLoop) {
		Write-Host 'VERDICT: GREEN (survived window, killed by loop, no new crash entry)'
		exit 0
	}
	else {
		Write-Host 'VERDICT: GREEN (survived window, no new crash entry)'
		exit 0
	}
}
finally {
	# restore filter file state
	if ($Variant -eq 'none' -and $hadFilter -and -not (Test-Path $filter)) {
		Move-Item $filterBak $filter -Force
	}
	elseif (($Variant -eq 'classes-only' -or $Variant -eq 'items-only') -and (Test-Path $filterBak)) {
		Copy-Item $filterBak $filter -Force
		Remove-Item $filterBak -ErrorAction SilentlyContinue
	}
	if (Test-Path $modLog) {
		Write-Host '--- bbof.log ---'
		Get-Content $modLog
	}
}
