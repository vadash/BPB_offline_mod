# Ghost DB format (`ghosts.gdb`), version 1

Produced by `seeder/` (only writer), consumed by the mod's `Core/GhostDb.gd`. Replaces the SQLite `full_dump.db` schema v1 (ADR 0003). Board payloads inside the metadata blobs use the encoding in `docs/board-format.md`.

## Byte order

Little-endian throughout. Compressed blobs are gzip streams (RFC 1952); the seeder emits `System.IO.Compression.GZipStream`, the mod decompresses with `PoolByteArray.decompress(raw_len, COMPRESSION_GZIP)`.

## File layout, in order

`N` = run count from the header. `V` = version-table count. All offsets are absolute file offsets. All arrays are dense-rank ordered: index `i` is rank `i + 1` (the seeder re-ranks kept ghosts 1..N after filtering, so no rank column exists).

| Section | Size | Contents |
|---|---|---|
| Header | 12 B | magic `BGDB` (4 bytes ASCII), `format_version` u32 (= 1), `run_count` u32 (= N) |
| Version table | 1 + 2·V B | `version_count` u8 (= V), then V 2-char ASCII version codes, sorted ascending (`"OC"`, `"OD"`, …) |
| `steam_ids` | 8·N B | u64[N], rank-ordered; used to exclude the player's own run |
| `blob_offsets` | 8·N B | u64[N]; `blob_offsets[i]` = offset of blob `i`'s framing header |
| `d_codes` | N B | u8[N]; index into the version table for each run |
| `d_order` | 4·N B | u32[N]; run indices sorted by (`d_code` ascending, index ascending) — the min-d probe's walk order |
| `r_values` | 8·N B | f64[N] sorted **descending**; used only for the rank estimate |
| Blob section | ≥ 8·N B | per blob, at `blob_offsets[i]`: `comp_len` u32, `raw_len` u32, then `comp_len` bytes of gzip stream |

The metadata string is stored verbatim as UTF-8 (the exact text the seeder received from Steam UGC): one JSON object carrying per-day boards (`"0".."17"`) plus `r`/`p`/`d`. The seeder validates it parses as JSON and has a numeric `r` before writing; rows without `r` are rejected.

## Reader semantics

- **Schema gate**: magic and `format_version` must match, else fail with the old `db_schema_version` warn carrying the format version.
- **Rank estimate** for player score `x`: count of `r_values` strictly greater than `x` (binary search for the first index with `r <= x`), plus 1.
- **Opponent window** `[lo, hi]`, self id, limit: read blobs `lo-1 .. hi-1` in order, skip runs whose `raw_len <= 10` or whose `steam_id` equals the player's, stop after `limit` accepted rows.
- **Min-d probe**: walk `d_order`, decompress + JSON-parse each blob, first parseable one marks the cutoff (version code = first 2 chars of its `d`); stop after 200 scanned.
- **Row count**: `run_count` from the header; no scan.
