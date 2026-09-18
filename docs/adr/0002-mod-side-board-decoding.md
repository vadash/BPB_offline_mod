# Mod-side board decoding instead of game decode calls

The ghost exclusion feature needs item names per board. The game's decoder
(`RunData.deserializeItemsOfRound` and the whole decode family) crashes the
process with 0xc0000005 when called by name from mod GDScript: unbounded
recursion in game code, stack exhaustion. Reproduced on ghost boards
(entryVersion 1.1.6) and the player's own boards (1.1.8), with and without
`fromSerialized` init. `isRoundValid` / `deserializeItems` return unusable
values by name, so there is no safe guard or alternative entry point.
Data-only game calls (`Game.getClassName`, `RunDatabase.parseSingleScore`)
work fine; the game itself decodes boards through paths the mod cannot
reach.

Decision: the mod decodes board strings itself - `Core/BoardDecoder.gd`
(pure GDScript port of the game's deserializeStream, restricted to item
names) plus a `BitStream` port. Game data comes from safe ItemBook data
lookups only (indexes, names, socket counts, Magic Ring's effects param -
read live, so item updates need no bake). The mod never calls the game's
decode family. Format spec: docs/board-format.md.

Known limits: decode accuracy is game-parity, not perfect - ~98% of rounds
in the local DB decode cleanly. The rest contain item indexes whose meaning
shifted across game versions (the ring block around idx 505); the game's
own decoder misreads those boards the same way at fight time, so parity is
the ceiling. A failed round is treated as "cannot match exclusions", never
an error.

Consequences: every game update can shift item indexes or the format; the
format constants (999 health/stamina range, 10x10 inventory cells) and the
Magic Ring name/persistence assumption are the first suspects when decode
validation fails after an update. Validate by decoding a DB sample offline
(Python port against the ItemBook table dump) or in game via bbof.log.

Considered options:

- Calling the game's decoder: rejected - crashes the process (above).
- Class-only exclusions: rejected for now - drops half the exclusion
  feature the mod promises.
- Seeder-side decoding: rejected - same decoder needed in C#, doubles the
  port surface; mod-side decoding keeps the DB schema at version 1.
