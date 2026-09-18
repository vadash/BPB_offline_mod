# Ghost Leaderboard

Backpack Battles leaderboard runs offline: a seeder scrapes the Steam leaderboard into a local store, and a game mod serves opponents from it instead of from Steam.

## Leaderboard data

**Run**:
One completed leaderboard performance. Carries run metadata.
_Avoid_: entry, score (a score is only the number)

**Run metadata**:
JSON blob attached to every run; carries the Elo-like score `r` and the game version `d`.
_Avoid_: UGC metadata, preview

**Board**:
One day's snapshot of a run's build; a run carries up to 18 boards (one per day). Not the backpack grid.
_Avoid_: day snapshot, floor

**Ghost**:
A run served to the player as an opponent. The game rejects ghosts older than its cutoff.
_Avoid_: opponent run, dummy

**Ghost DB**:
The local store the seeder produces and the mod reads; the source of ghosts when Steam is absent.
_Avoid_: dump, cache

**Seeder**:
CLI tool that scrapes the Steam leaderboard and writes the ghost DB.
_Avoid_: scraper, dumper

**Mod**:
The game-file override that replaces Steam leaderboard I/O with ghost-DB reads.
_Avoid_: addon, patch, plugin

**Player state sidecar**:
The mod's persisted record of the player: score, rank estimate, sequence number, min-d cutoff.
_Avoid_: save file, state file

## Progression

**Rank estimate**:
The mod's live approximation of the player's position, computed without Steam.
_Avoid_: estimated rank (as a bare phrase), Elo

**Dense rank**:
The seeder's renumbering of kept ghosts 1..N after filtering. Distinct from the rank estimate; the two are not interchangeable.
_Avoid_: re-rank

**Opponent window**:
The rank range ghosts are sampled from, centered on the player.
_Avoid_: rank window, bracket

**Tier**:
Player band mapped from the rank estimate; higher tiers shift the opponent window toward easier ghosts.
_Avoid_: league, division

**Min-d cutoff**:
Oldest game version accepted as a ghost. The mod probes it live at startup and persists it.
_Avoid_: min version, version floor

**Rating floor**:
Bottom fraction of runs by `r` excluded from the ghost DB. Seeder-side percentile over the runs that survive version selection.
_Avoid_: rank cut, trim, percentile filter

**Version code**:
First two characters of a run's `d` string (`OC`, `OD`, …). The unit both tools use to order and filter versions; the rest of `d` is opaque packed bytes.
_Avoid_: version string (bare), build tag

## Installs

**Steam install**:
The original Steam copy of Backpack Battles; the seeder runs against its logged-in client and `steam_api64.dll`.
_Avoid_: original game (bare), seed install

**Offline install**:
The modded game copy the mod and ghost DB deploy to; plays without Steam.
_Avoid_: non-Steam copy

## Exclusions

**Exclusion**:
A user rule that stops ghosts from loading. A ghost is dropped when its hero class matches an excluded class, or any of its boards contains an excluded item. Rules combine with OR.
_Avoid_: blacklist, ban, ignore list

**Refill**:
Widening the opponent window around the player when exclusions leave too few ghosts. Stops as soon as the pool is half full again or the whole ghost DB is inside the window.
_Avoid_: re-query, expansion
