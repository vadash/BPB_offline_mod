# BPB Offline Mod

Offline ghost leaderboard for [Backpack Battles](https://store.steampowered.com/app/2427700/Backpack_Battles/). Plays the game's leaderboard without a Steam connection by serving locally stored ghost opponents.

## Components

- **`seeder/`** — Steam leaderboard seeder. Builds a local ghost database (`ghosts.gdb`, BGDB v1 — see [docs/ghost-db-format.md](docs/ghost-db-format.md)). Build with `seeder/build.bat`.
- **`mod/`** — Game mod. Replaces the game's Steam leaderboard I/O with the local ghost database; ships as a `mod.pck` override. Pack with `mod/Pack-ModPck.ps1`, deploy by copying `mod.pck` next to the game exe. See [mod/AGENTS.md](mod/AGENTS.md) for build, deploy, and validation steps.

## Documentation

- [docs/ghost-db-format.md](docs/ghost-db-format.md) — ghost database format (BGDB v1)
- [docs/board-format.md](docs/board-format.md) — board encoding used for ghost exclusions
- [docs/adr/](docs/adr/) — architecture decision records

## Requirements

- A legitimately owned copy of Backpack Battles (Steam version).
- A logged-in Steam client when seeding.

## Disclaimer

- This mod requires a legitimately owned copy of the game.
- Not affiliated with or endorsed by PlayWithFurcifer.
- This repository contains mod scripts only; it contains no game files.
