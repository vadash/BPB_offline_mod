# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
dotnet build -c Release
dotnet run -c Release --                          # default: writes ghosts-{dd-MM-yy}.gdb next to the exe
dotnet run -c Release -- --db path/to/output.gdb   # custom output path
dotnet run -c Release -- --keep-d 4               # keep newest N version codes present in the data (default 4)
dotnet run -c Release -- --min-r 60               # rating floor: drop runs with r below the threshold (default 60; 0 = off)
dotnet run -c Release -- --merge path/to/folder   # merger: merge every top-level *.gdb in folder -> folder/ghosts-merged-{dd-MM-yy}.gdb
dotnet run -c Release -- --merge                  # bare: same, with folder = the exe's folder
```

Requires `steam_api64.dll` next to the executable (or discoverable via PATH). If the Steam client is down, the seeder starts it (registry `Software\Valve\Steam\SteamPath`, `-silent`) and waits up to 90 s for login; it shuts the client down after the downloads finish — but only a client it started, never a pre-existing one. Running-but-logged-out is an error. `--merge` needs no Steam and no DLLs.

Tests: `dotnet test LeaderboardSeeder.Tests` (xUnit; round-trips the BGDB layout, merge dedup/filter behavior, and a real-data fixture under `LeaderboardSeeder.Tests/Fixtures/`). Regenerate the fixture explicitly with `BPB_REGENERATE_FIXTURE=1 dotnet test --filter Regenerate_fixture` (no dump needed: the test re-reads the committed fixture's own rows through the production Read->Write path).

## Architecture

Single-purpose CLI tool that scrapes the "bpb-runs3" Steam leaderboard, enriches entries with UGC (Workshop) metadata, filters them, and writes results to the binary `ghosts.gdb` format (see `docs/ghost-db-format.md`).

### Flow

1. **Init Steam** — P/Invokes `steam_api64.dll` via `Steam` static class. Tries `SteamAPI_InitFlat` first (newer SDK), falls back to `SteamAPI_InitSafe`. Gracefully handles `EntryPointNotFoundException` for version mismatches. If the client is down, launches `steam.exe -silent` found via registry (`HKCU`/`HKLM` `Software\Valve\Steam\SteamPath`), retries init for up to 90 s, then waits 15 s for the client's web services to settle — a cold client can serve empty leaderboard pages, truncating the fetch.
2. **Fetch leaderboard** — Finds the leaderboard handle, then downloads entries in 5000-entry batches (4 concurrent requests) via async Steam callback polling (`SteamAPI_RunCallbacks` loop with `Thread.Sleep`).
3. **Fetch UGC metadata** — For each distinct Workshop ID in the entries, queries UGC details in 1000-item batches (4 concurrent). Extracts metadata JSON strings from each item.
4. **Filter & write** — Runs the rank-ordered raw entries through `RunFilter` (`LeaderboardSeeder/RunFilter.cs`): `Admit` parses metadata (`r`, `d`), deduplicates by Steam ID (the dedup fires before metadata validation, so a player whose best-rank row has bad or missing metadata is dropped entirely), and rejects rows without a numeric `r`; `Apply` keeps only the newest `--keep-d` (default 4) version codes present in the candidates and drops runs with `r` below the `--min-r` rating floor (default 60; 0 = off). Then writes the `BGDB` v2 binary layout (gzip-compressed metadata blobs, two-pass via `<final>.tmp` + atomic `File.Move`) to `ghosts-{dd-MM-yy}.gdb` next to the exe — local date, so each scrape is one dated file and same-day reruns overwrite; `--db` overrides. Right after the downloads finish (before filtering/writing, which need no Steam), `SteamAPI_Shutdown` runs and a client the seeder started gets `steam.exe -shutdown`; the same cleanup covers mid-download errors.
5. **Version report** — Prints per-version kept/cut/total counts after filtering.

### Merge flow (`--merge [<folder>]`)

No Steam. Reads every top-level `*.gdb` in the folder as an input — older dated `ghosts-merged-*.gdb` outputs count too (content dedup keeps merges idempotent); today's own output name is excluded, so a same-day rerun rebuilds from the other ghost DBs instead of re-reading its target — failing the whole merge on any unreadable input. Bare `--merge` (no folder) uses the exe's folder, where the dated scrape dumps land. A row is a duplicate when the same Steam ID carries byte-identical metadata text (same run re-seeded); differing content for the same player is kept. The version window re-applies over the union: `keep-d` defaults to the seeder's 4 and walks back from the union's newest version code to fill 4 distinct codes (`--keep-d` overrides). The rating floor re-applies over the union with the same static threshold as a seed run (`--min-r`, default 60; 0 = off), so legacy inputs cut at an older floor normalize to the current one and merging inputs already cut at 60 cuts nothing new. Rows are ordered by `r` descending (dense-rank order) and written to `<folder>/ghosts-merged-{dd-MM-yy}.gdb` atomically (overwrite allowed, so same-day reruns are idempotent).

Memory: the merge holds every input fully in RAM (plus the buffered output), so sum of inputs + result should stay well under a few GB. Real scale: two ~80 MB dumps (~177k rows) merge in ~8 s / ~1 GB peak.

### Key files

- `Program.cs` — Steam I/O, scrape and merge orchestration, console output. Filtering is delegated to `RunFilter`. Decompiled-style source (top-level statements compiled, then decompiled).
- `LeaderboardSeeder/GhostDb.cs` — BGDB v2 reader (`GhostDb.Read`) and the single writer (`GhostDb.Write`); seeder and merger both write through it.
- `LeaderboardSeeder/Merger.cs` — Merger: content-based dedup, union filtering via `RunFilter`, folder orchestration (`RunMerge`).
- `LeaderboardSeeder/Steam.cs` — Flat P/Invoke bindings to `steam_api64.dll`. Uses `nint` for interface pointers. Includes version-paired accessors (`v018`/`v017`, `v013`/`v012`, `v021`/`v018`).
- `LeaderboardSeeder/Entry.cs` — Record type for a filtered leaderboard row.
- `LeaderboardSeeder/RunFilter.cs` — Run-filter pipeline shared by the scrape and merge paths: `Admit` (scrape admission: metadata validation, steam-id dedup, per-version totals) and `Apply` (dedup mode, version window, rating floor, per-code stats); plus the pure `VersionWindow` helper.
- `LeaderboardSeeder/*.cs` — Struct definitions matching Steam SDK callback layouts (`LeaderboardEntryT`, `LeaderboardFindResultT`, `LeaderboardScoresDownloadedT`, `SteamErrMsg`). `KiCallback` constants (1104, 1105, 3401) are Steam callback type IDs.

### Steam API quirks

- Accessor functions (e.g. `SteamAPI_SteamFriends_v018`) may throw `EntryPointNotFoundException` if the SDK version doesn't match — the `GetAccessor` helper tries the newer version first, falls back to the older.
- Callbacks are polled synchronously via `SteamAPI_RunCallbacks` + `IsAPICallCompleted` loops — there is no true async/await.
- The UGC metadata struct size varies by SDK version (152 vs 280 bytes); both are tried.

## Project config

- Target: .NET 10.0, C# 14.0, x64, unsafe blocks enabled
- Output format: custom `BGDB` v2 binary (`ghosts.gdb`), gzip blobs via `System.IO.Compression.GZipStream`. No external data dependencies. Publishing produces a single-file self-contained exe.
