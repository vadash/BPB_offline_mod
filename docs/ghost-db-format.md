# Ghost DB format (`ghosts.gdb`), version 2

Produced by `seeder/` — the seeder and its `--merge` merger write through the single writer code path (`LeaderboardSeeder/GhostDb.Write`); consumed by the mod's `Core/GhostDb.gd`. Replaces the SQLite `full_dump.db` schema v1 (ADR 0003); version 2 adds the per-run exclusion summaries over that base layout (ADR 0004). Board payloads inside the metadata blobs use the encoding in `docs/board-format.md`.

## Byte order

Little-endian throughout. Compressed blobs are gzip streams (RFC 1952); the seeder emits `System.IO.Compression.GZipStream`, the mod decompresses with `PoolByteArray.decompress(raw_len, COMPRESSION_GZIP)`.

## File layout, in order

`N` = run count from the header. `V` = version-table count. All offsets are absolute file offsets. All arrays are dense-rank ordered: index `i` is rank `i + 1` (the seeder re-ranks kept ghosts 1..N after filtering, so no rank column exists).

| Section | Size | Contents |
|---|---|---|
| Header | 12 B | magic `BGDB` (4 bytes ASCII), `format_version` u32 (= 2), `run_count` u32 (= N) |
| Version table | 1 + 2·V B | `version_count` u8 (= V), then V 2-char ASCII version codes, sorted ascending (`"OC"`, `"OD"`, …) |
| `steam_ids` | 8·N B | u64[N], rank-ordered; used to exclude the player's own run |
| `blob_offsets` | 8·N B | u64[N]; `blob_offsets[i]` = offset of blob `i`'s framing header |
| `d_codes` | N B | u8[N]; index into the version table for each run |
| `d_order` | 4·N B | u32[N]; run indices sorted by (`d_code` ascending, index ascending) — the min-d probe's walk order |
| `r_values` | 8·N B | f64[N] sorted **descending**; used only for the rank estimate |
| `summary_offsets` | 8·N B | u64[N]; `summary_offsets[i]` = offset of run `i`'s summary record (see below) |
| Summary records | variable | the N records back to back, in rank order; the last ends where the blob section starts (`blob_offsets[0]`) |
| Blob section | ≥ 8·N B | per blob, at `blob_offsets[i]`: `comp_len` u32, `raw_len` u32, then `comp_len` bytes of gzip stream |

The metadata string is stored verbatim as UTF-8 (the exact text the seeder received from Steam UGC): one JSON object carrying per-day boards (`"0".."17"`) plus `r`/`p`/`d`. The seeder validates it parses as JSON and has a numeric `r` before writing; rows without `r` are rejected.

## Per-run exclusion summaries

One record per run, written at seed time so the mod's exclusion sweep never decodes a board. Record layout: `class` u8 (game class index; 255 = the `d` header could not be decoded), `flags` u8 (bit0 perfect, bit1 undecodable), item count as unsigned LEB128, then that many unsigned LEB128 varints — the first an absolute item descriptor index, each next the gap to the previous (gaps are ≥ 1, so the indexes are sorted and distinct without a length field). The count makes the record self-delimiting.

Content rules (writer-side, mirroring the old mod-side sweep): class and the perfect flag come from the run's `d` header (perfect = all first-ten round results wins); the item set is the union over the present board rounds of the successfully decoded descriptor indexes, deduplicated; a failed board contributes no items but sets the undecodable flag; a header-unreadable run gets class 255, the undecodable flag, and an empty item set.

## Reader semantics

- **Schema gate**: magic and `format_version = 2` exactly, else fail with the old `db_schema_version` warn carrying the found and expected versions (the mod's `db_schema_version ver=%s expected=%d`; the seeder throws `unsupported format_version %u (expected 2).`). Neither reader accepts version 1.
- **Exclusion sweep**: every rule decides from the run's summary — class via the game's class names, perfect via the flag, items by resolving descriptor indexes to names through the live item data. A summary is required for every row.
- **Rank estimate** for player score `x`: count of `r_values` strictly greater than `x` (binary search for the first index with `r <= x`), plus 1.
- **Opponent window** `[lo, hi]`, self id, limit: read blobs `lo-1 .. hi-1` in order, skip runs whose `raw_len <= 10` or whose `steam_id` equals the player's, stop after `limit` accepted rows; each accepted row rides with its summary record.
- **Min-d probe**: walk `d_order`, decompress + JSON-parse each blob, first parseable one marks the cutoff (version code = first 2 chars of its `d`); stop after 200 scanned.
- **Row count**: `run_count` from the header; no scan.

## Reference artifact

`seeder/LeaderboardSeeder.Tests/Fixtures/ghosts-fixture-64.gdb` is the committed reference file — the first 64 dense-rank rows of a real dump, re-emitted through `GhostDb.Write` — read by both test suites (C# `FixtureTests`, the mod's `run_tests.gd` golden suite). Regenerate anywhere with `BPB_REGENERATE_FIXTURE=1 dotnet test --filter Regenerate_fixture`: the gate re-reads the committed file's own rows and writes them back through the production Read->Write path, so the result is exactly what the current writer emits.
