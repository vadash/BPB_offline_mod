# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
dotnet build -c Release
dotnet run -c Release -- --db path/to/output.gdb   # custom output path
dotnet run -c Release -- --keep-d 4               # keep newest N version codes present in the data (default 4)
dotnet run -c Release -- --cut-bottom 25          # rating floor: drop bottom P% by r (default 25; 0 = off)
dotnet run -c Release -- --merge path/to/folder   # merger: merge every top-level *.gdb in folder -> folder/ghosts-merged.gdb
```

Requires `steam_api64.dll` next to the executable (or discoverable via PATH). Steam client must be running and logged in. `--merge` needs no Steam and no DLLs.

Tests: `dotnet test LeaderboardSeeder.Tests` (xUnit; round-trips the BGDB layout, merge dedup/filter behavior, and a real-data fixture under `LeaderboardSeeder.Tests/Fixtures/`). Regenerate the fixture explicitly with `BPB_REGENERATE_FIXTURE=1 dotnet test --filter Regenerate_fixture` on the machine that has the source dump.

## Architecture

Single-purpose CLI tool that scrapes the "bpb-runs3" Steam leaderboard, enriches entries with UGC (Workshop) metadata, filters them, and writes results to the binary `ghosts.gdb` format (see `docs/ghost-db-format.md`).

### Flow

1. **Init Steam** — P/Invokes `steam_api64.dll` via `Steam` static class. Tries `SteamAPI_InitFlat` first (newer SDK), falls back to `SteamAPI_InitSafe`. Gracefully handles `EntryPointNotFoundException` for version mismatches.
2. **Fetch leaderboard** — Finds the leaderboard handle, then downloads entries in 5000-entry batches (4 concurrent requests) via async Steam callback polling (`SteamAPI_RunCallbacks` loop with `Thread.Sleep`).
3. **Fetch UGC metadata** — For each distinct Workshop ID in the entries, queries UGC details in 1000-item batches (4 concurrent). Extracts metadata JSON strings from each item.
4. **Filter & write** — Parses metadata (`r`, `d`), deduplicates by Steam ID, rejects rows without a numeric `r`, keeps only the newest `--keep-d` (default 4) version codes present in the candidates, drops rows below the `--cut-bottom` (default 25) percentile rating floor, then writes the `BGDB` v1 binary layout (gzip-compressed metadata blobs, two-pass via `<final>.tmp` + atomic `File.Move`).
5. **Version report** — Prints per-version kept/cut/total counts after filtering.

### Merge flow (`--merge <folder>`)

No Steam. Reads every top-level `*.gdb` in the folder (skipping the output name `ghosts-merged.gdb` itself), failing the whole merge on any unreadable input. A row is a duplicate when the same Steam ID carries byte-identical metadata text (same run re-seeded); differing content for the same player is kept. **No re-filtering by default** — every input was already keep-d/cut-bottom filtered by the seeder that wrote it, and re-applying would double-cut. `--keep-d`/`--cut-bottom` flags override and re-apply over the union. Rows are ordered by `r` descending (dense-rank order) and written to `<folder>/ghosts-merged.gdb` atomically (overwrite allowed, so repeat merges are idempotent).

Memory: the merge holds every input fully in RAM (plus the buffered output), so sum of inputs + result should stay well under a few GB. Real scale: two ~80 MB dumps (~177k rows) merge in ~8 s / ~1 GB peak.

### Key files

- `Program.cs` — All logic. Decompiled-style source (top-level statements compiled, then decompiled).
- `LeaderboardSeeder/GhostDb.cs` — BGDB v1 reader (`GhostDb.Read`) and the single writer (`GhostDb.Write`); seeder and merger both write through it.
- `LeaderboardSeeder/Merger.cs` — Merger: content-based dedup, union filtering via `RunFilter`, folder orchestration (`RunMerge`).
- `LeaderboardSeeder/Steam.cs` — Flat P/Invoke bindings to `steam_api64.dll`. Uses `nint` for interface pointers. Includes version-paired accessors (`v018`/`v017`, `v013`/`v012`, `v021`/`v018`).
- `LeaderboardSeeder/Entry.cs` — Record type for a filtered leaderboard row.
- `LeaderboardSeeder/RunFilter.cs` — Pure filter helpers: version-window selection and rating-floor percentile.
- `LeaderboardSeeder/*.cs` — Struct definitions matching Steam SDK callback layouts (`LeaderboardEntryT`, `LeaderboardFindResultT`, `LeaderboardScoresDownloadedT`, `SteamErrMsg`). `KiCallback` constants (1104, 1105, 3401) are Steam callback type IDs.

### Steam API quirks

- Accessor functions (e.g. `SteamAPI_SteamFriends_v018`) may throw `EntryPointNotFoundException` if the SDK version doesn't match — the `GetAccessor` helper tries the newer version first, falls back to the older.
- Callbacks are polled synchronously via `SteamAPI_RunCallbacks` + `IsAPICallCompleted` loops — there is no true async/await.
- The UGC metadata struct size varies by SDK version (152 vs 280 bytes); both are tried.

## Project config

- Target: .NET 10.0, C# 14.0, x64, unsafe blocks enabled
- Output format: custom `BGDB` v1 binary (`ghosts.gdb`), gzip blobs via `System.IO.Compression.GZipStream`. No external data dependencies. Publishing produces a single-file self-contained exe.
