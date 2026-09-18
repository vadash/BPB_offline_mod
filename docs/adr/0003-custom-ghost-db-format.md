# Custom binary ghost DB format replaces SQLite

## Context

The ghost DB (`full_dump.db`, ~450 MB for 212k runs) was SQLite because the mod already shipped with a SQLite GDNative DLL and the seeder had a Sqlite driver. The actual access surface is five fixed query shapes: schema gate, row count, rank estimate (`COUNT WHERE r > ?`), opponent window (metadata blobs by dense rank), min-d probe (oldest-first walk). Most of the file is metadata text; the `r` column has no index, so the rank estimate scans the whole file. ~70% of the bytes are metadata blobs the mod only ever reads as opaque strings to hand to the game's parser.

## Decision

One custom single-file format, `ghosts.gdb` (see `docs/ghost-db-format.md`): little-endian, fixed section order, dense-rank array addressing (offset = rank - 1), one descending `r` array for binary-search rank estimates, a d-sorted index for the probe, and per-blob gzip of the verbatim metadata strings. The seeder is the only writer; the mod reads with plain `File` seek/read — the `gdsqlite` dependency disappears from both. Dropped columns: `workshop_id`, `score`, `p` (never read at runtime). Rows without numeric `r` are rejected at write.

## Consequences

File drops to roughly a third (~170 MB) and the rank estimate becomes ~18 comparisons instead of a full-file scan. Both tools now own the byte layout; any change bumps `format_version` in the header and lands in both at once (clean cutover, no dual-format period). Compression is gzip on both ends from their standard libraries, so neither side gains a dependency.

Considered options:

- Tuned SQLite (index on `r`, drop dead columns, per-blob compressed BLOBs, VACUUM): rejected - keeps the `gdsqlite` dependency and per-call open/close overhead, floors around ~220 MB, and the rank estimate stays a `COUNT` scan.
- Whole-section compression (one zstd/gzip stream over the blob area): rejected - best ratio, but the window and probe need random access to individual blobs, which forces a block index and re-wins us the complexity the format exists to delete.
- Per-blob zstd: rejected - better ratio than gzip by single digits percent, but the seeder would need a new package (no zstd in the BCL) while Godot only decompresses; gzip is stdlib on both sides and measured within ~8%.
