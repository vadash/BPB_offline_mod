# Board round format (Backpack Battles, entryVersion >= 1.1.0)

entryVersion < 1.1.0: item index range is a baked constant, 510
(RunData.deserializeStream), instead of ItemBook.getNumItems().

Reverse-engineered from game scripts recovered with GDRE Tools v2.6.4 plus
the runtime-dumped script key (`encryption_key.txt`, corrected_key). Sources:
`Utility/BitStream.gd`, `Utility/RunData.gd` (`deserializeItems` /
`deserializeStream`), `Sheets/ItemBook.gd`, `Core/Game.gd`,
`Core/Inventory.gd` in the recovered tree. Recovered sources live in
`.gdre/extracted` (gitignored) and are regenerated per game update.

## Byte order

One round is one "Godot string": each character encodes 6 bits,
`value = ord(char) - 62` (BitStream.BASE64OFFSET). Legal characters are
ASCII 62..125 (`>?@A..Z[\]^_`a..z{|}~`). All multi-bit fields below are
MSB-first, `ceil(log2(rangeMax))` bits wide (`BitStream.pull`).

## Round stream layout, in order

| Field | Range | Bits |
|---|---|---|
| health | 999 | 10 |
| stamina | 999 | 10 |
| repeat until fewer than 8 bits remain: | | |
| item index | ItemBook.getNumItems() | ceil(log2(N)) |
| pos x | 10 | 4 |
| pos y | 10 | 4 |
| face | 4 | 2 |
| if numSockets(index) > 0: hasGems | 2 | 1 |
| if hasGems == 1: gemIndex per socket | ceil(numGems+1) | ceil(log2) |
| if item has getDataPersistent(): persistent blob | item-specific | see below |

Per-item data the decoder needs, in dependency order:

- `numSockets` - `ItemBook.numSockets[index]` (plain array).
- persistent bit count - `instance.getDataPersistentBits()` on the item
  script; constant per item type (the game's own reader uses a fresh
  instance, so writer and reader must agree). Items whose script lacks
  `getDataPersistent` consume zero persistent bits. Exactly one item ships
  an override: Magic Ring, matched by display name, width
  `int(getP("effects")) * 6`.
- item display name - `ItemBook.getDescriptorFromIndex(index).getName()`.

Skipping any field with the wrong width corrupts every item after it.

## Why the mod cannot call this decoder

Calling `RunData.deserializeItemsOfRound` / `deserializeRound` by name from
mod GDScript recurses unboundedly inside the game and crashes the process
(0xc0000005, stack exhaustion). Reproduced on ghost boards (1.1.6) and the
player's own boards (1.1.8), with and without `fromSerialized` init; see
ADR 0002. `isRoundValid` / `deserializeItems` return unusable values by
name. Data-only lookups (`Game.getClassName`, `RunDatabase.parseSingleScore`)
are safe. The mod therefore decodes boards itself (BitStream port + baked
per-item tables) and never calls the game's decode family.
