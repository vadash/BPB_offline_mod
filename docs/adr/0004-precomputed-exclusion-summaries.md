# Precomputed exclusion summaries in the ghost DB

## Context

Exclusions (an excluded hero class, an excluded item on any board, perfect-ghost status) decide per candidate ghost at load time. Until now every rule that needed run content decoded boards in the mod at read time: each windowed run's day boards went through `Core/BoardDecoder.gd` (ADR 0002, ~98% game-parity ceiling) on every download. Measured on the author's install (1666-run DB): the exclusion sweep cost `filter_ms=8755` of a ~9.2 s startup (`io_ms=45`, `parse_ms=418`) — effectively the whole load. The decode surface also duplicated write-side knowledge: the seeder already parses the same `d` headers and board strings when building summaries of its own.

## Decision

The seeder precomputes a per-run exclusion summary at write time and stores it in the ghost DB; format version bumps to 2 (`docs/ghost-db-format.md`). One summary record per run, addressed through a `summary_offsets` table placed between `r_values` and the blob section: hero class, perfect flag, undecodable marker, and the union of decoded board item sets stored as descriptor indexes — indexes over names, resolved live through the per-session item-fact index (the game's ItemBook, `item_book_dump.json` in headless tests). Decode moves to write time; the exclusion sweep, the refill slab logic (left slab then right slab, each row read once), the seen dedupe, all counters, and the log shapes (`filter kept=… filtered=… ms=… rules=…`, `refill half=…`) stay unchanged — only the per-rule field source moves from decode results to the summary. The mod's board decoder stays in the tree as the test-time conformance oracle (the golden-suite decode pins), but no production path calls it. v1 support is removed outright from both readers (clean cutover): a gate accepts format_version 2 only, ghost DBs from before the cutover fail it and must be re-seeded or re-merged.

## Consequences

The load-time exclusion sweep no longer decodes a single board; its remaining cost is summary byte reads and name resolution, and `filter_ms` in the load log keeps making that measurable. Items are matched against whatever the running game's item data says the indexes mean, so a game update that renames items keeps exclusion parity without touching stored DBs. Both writers (seeder and merger) emit v2 through the single `GhostDb.Write` path, and the committed golden fixture is regenerated through the same production Read->Write path, so the cross-language conformance pin survives the version bump byte for byte.

Considered options:

- Freezing item display names into the summaries: rejected - a game update renaming items would silently break exclusion parity for every stored DB; descriptor indexes resolved through the live item facts stay correct across renames.
- Keeping the read-time decode as a fallback for summary-less runs: rejected - keeps the whole decode surface (and its ~9 s sweep) on the hot path forever, and the dual-format branches in both readers exist only for DBs the current writers can no longer produce.
- Caching decoded names per session in the mod instead: rejected - still decodes every unseen run once per session, and the cache dies with the session while the cost stays O(decoded rows) rather than O(summary bytes).
