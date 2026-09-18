# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```powershell
# Validate syntax & types (run before every commit).
# Godot 3.6.2 has NO --headless / --script-check flags: --script-check treats
# the .gd path as a project and opens the Project Manager. check.ps1 runs the
# check scene (--no-window) which compiles + instantiates the Core scripts.
# See docs/adr/0001-godot-cli-validation.md.
mod\tests\check.ps1

# Run the GhostDb test suite (headless; nonzero exit on any failure or SCRIPT ERROR)
mod\tests\setup.ps1   # no-op since the BGDB v1 port (no DLLs to stage)
mod\tests\run.ps1

# Game-level regression check (after every rebuild+deploy): launches the real
# game with the user's ghost_filter.json and asserts no new crash entry.
mod\tests\repro-crash.ps1 -GameDir C:\Games\BackpackBattles -Variant keep


# Pack mod.unpacked/ into mod.pck
.\Pack-ModPck.ps1

# Unpack mod.pck into mod.unpacked/
.\Unpack-ModPck.ps1

# Deploy to game
Copy-Item mod.pck C:\Games\BackpackBattles\
```
Validation is Godot's `--check-only` script check (`check.ps1`) plus the headless GhostDb harness in `mod/tests/` (`run.ps1` exits nonzero on any check failure or `SCRIPT ERROR` — Godot itself exits 0 even when the `-s` script fails to parse). Godot's Windows exe is GUI-subsystem: under piped/captured output both stdout and the exit code vanish, so automation must use the `Start-Process -RedirectStandardOutput/-RedirectStandardError -Wait -PassThru` pattern `run.ps1` uses.

## Architecture

Godot 3.6.2 mod that replaces Steam leaderboard I/O with a local ghost database (`ghosts.gdb`, BGDB v1 — see `docs/ghost-db-format.md`), enabling offline play with custom leaderboards. Ships as a PCK file the game loads as an override.

### Flow

1. **Game loads mod.pck** — PCK files override `res://` paths, so `Core/SteamWorkshop.gd` replaces the game's original.
2. **Startup** — Caches paths next to the game exe, opens `bbof.log`, defers the download path.
3. **Download path** — Opens `ghosts.gdb`, gates the BGDB v1 header (magic + format_version), estimates rank from cached state, reads a ±1000 opponent window, parses metadata, notifies the game.
4. **Zero-parse fallback** — If the primary opponent window parses to zero ghosts, one refill over the global middle-50% window. Game rejects ghosts older than its cutoff.
5. **Min version probe** — Walks rows oldest-`d` first through the game's parser; first parseable `d` = live cutoff. Persists `min_d` at startup for reference; the seeder no longer consumes it (it keeps the newest `--keep-d` version codes instead).
6. **Tiered difficulty** — Player percentile maps to a tier; higher tiers shift the opponent window toward easier opponents.

### Key files

- `mod.unpacked/Core/SteamWorkshop.gd` — Thin adapter: game contract, paths, sidecar JSON, upload/download orchestration. Logs `contract_access` on any undeclared field get/set (`_get`/`_set` guards).
- `mod.unpacked/Core/GhostDb.gd` — Deep module owning every ghost-DB read: schema gate, min-d cutoff probe, rank estimate, opponent window, metadata parsing. Zero game references; reads BGDB v1 with plain File seek/read (header + arrays cached per session, blobs read on demand).
- `mod.unpacked/Core/BoardDecoder.gd` + `BitStream.gd` — Mod-side board decoding for exclusions (ADR 0002, docs/board-format.md). Game data via safe ItemBook data lookups; never calls the game's decode family. ~98% of rounds decode (game parity); a failed round means "cannot match exclusions".
- `mod.unpacked/Core/BbofLog.gd` — Compact persistent logger (extracted from the old inner class).
- `mod/tests/` — Headless GhostDb harness: `fixture.gd` writes throwaway BGDB v1 files (`docs/ghost-db-format.md`), `run_tests.gd` (SceneTree) holds the suite, `run.ps1` runs it, `setup.ps1` is a no-op since the port.
- `Pack-ModPck.ps1` — Pure PowerShell PCK packer with real MD5 hashes. Reads header from `mod_1.pck` reference if present, defaults to Godot 3.6.0.
- `Unpack-ModPck.ps1` — Pure PowerShell PCK unpacker. Parses GDPC binary format, generates `project.godot` + `export_presets.cfg` for rebuilding.
- `mod.pck` — Packed binary (the deployable artifact).
- `AGENTS.md` — Extended developer notes (overlap with this file).

### Game contract (settled, from decrypted game bytecode)

The game (`RunDatabase`) touches exactly: fields `gotResponse`, `largestSequenceNumber`, `parsedRuns`; methods `pushScore(meta, seq)`, `downloadScores()`; plus the load-bearing `class_name SteamLeaderboard` binding. The mod calls into the game: `RunDatabase.onSteamRunsReceived`, `RunDatabase.statisticsMode`, `SteamHelper.STEAM_ID`, and (exclusions feature) `Game.getClassName`, plus safe data reads: `run.get("characterClass")` / `run.get("rounds")` / `run.get("entryVersion")` on parsed RunData objects and the ItemBook data lookups (`getNumItems`, `getNumSockets`, `getNumGems`, `getDescriptorFromIndex` + descriptor `getName`/`get`/`getP`) from BoardDecoder (ADR 0002). The score parser is injected into GhostDb as a FuncRef wrapping `RunDatabase.parseSingleScore(dict, true, false)` so the deep module never references game classes. The game's board-decode family (`RunData.deserializeItemsOfRound`/`deserializeRound`/`deserializeItems`, `isRoundValid`) MUST NOT be called by name from the mod: it crashes the process (ADR 0002); the mod decodes boards itself per `docs/board-format.md`.

### Data files (at runtime, next to game exe)

- `ghosts.gdb` — Ghost database in BGDB v1 (docs/ghost-db-format.md), produced by the seeder: `BGDB` magic + format_version + run_count header, dense-rank arrays (steam_ids, blob_offsets, d_codes, d_order, r_values descending), gzip metadata blobs.
- `player_state.json` — Player sidecar with `r`, `estimated_rank`, `db_row_count`, `sequence_number`, `d`, `steam_id`, `last_metadata`, `min_d`.
- `ghost_filter.json` — Optional user config, hand-edited, re-read at every download: `{"exclude_classes": ["Engineer"], "exclude_items": ["False Life", "Holy Armor"]}`. Names are exact wiki-style display names (matched against `Game.getClassName` and item descriptor names). Missing file = no filtering. OR semantics: a ghost is dropped when its class is listed or any of its boards contains a listed item (whole-run). If filtering leaves fewer than `window/2` ghosts, the opponent window widens (rank half-width doubling) until the pool refills or the whole DB is covered.
- `bbof.log` — Structured log `[HH:MM:SS] LEVEL msg`, 5 MB rotation.

### Rank system

- `r` — Float Elo-like score from the game's metadata JSON. Ground truth of run performance.
- `rank` — Integer position estimated by counting `r_values` strictly greater than the player's r (binary search over the descending array), plus 1. Recomputed when the DB changes (row count differs from cached value).
- Rank determines opponent selection: a ±1000 opponent window centered on the player. Higher tiers (Diamond+) get negative offsets shifting opponents easier.

## Godot 3.x constraints

| Feature | Godot 3.6 | Godot 4+ |
|---------|-----------|----------|
| Reference-counted objects | `Reference` | `RefCounted` |
| File.open() return | `int` error code | `Error` enum |
| String formatting | `%` operator | `${}` interpolation |

Always use Godot 3.x APIs. The `--script-check` validator uses 3.6.2.

## Project config

- Target engine: Godot 3.6.2-stable
- Game path: `C:\Games\BackpackBattles\`
- Game logs: `%APPDATA%\Godot\app_userdata\Backpack Battles\logs\godot.log`
- Mod logs: `<game_dir>\bbof.log`
- Native dependencies: none (BGDB v1 reads use plain File I/O; the old gdsqlite GDNative addon is gone).
