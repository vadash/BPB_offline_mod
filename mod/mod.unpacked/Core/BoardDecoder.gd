extends Reference

# Mod-side board decoder (docs/board-format.md, ADR 0002). Port of the
# game's RunData.deserializeStream restricted to what exclusions need: the
# display names of every item in one round. Never calls the game's decode
# family - by-name calls into it crash the process (ADR 0002). Game data
# comes from safe ItemBook data lookups only. Baked constants (health and
# stamina range 999, 10x10 inventory cells) come from the recovered game
# sources (Game.MAX_HEALTH, Inventory.MAX_SIZE) and are the first thing to
# re-check after a game update.

const BitStreamReader = preload("res://Core/BitStream.gd")

const MAX_HEALTH = 999
const MAX_STAMINA = 999
const INVENTORY_X = 10
const INVENTORY_Y = 10

# Boards older than 1.1.0 encode item indexes against a fixed count.
const LEGACY_NUM_ITEMS = 510


# Display names of every item in the round, or null when the stream is
# invalid. null means "cannot match exclusions on this round" - never a
# player-visible error.
func decode_item_names(round_string: String, entry_version: String):
	var bs = BitStreamReader.new()
	if not bs.from_godot_string(round_string):
		return null
	if bs.pull(MAX_HEALTH) == -1 or bs.pull(MAX_STAMINA) == -1:
		return null

	var numGems = ItemBook.getNumGems()
	var gemRange = _binary_ceil(numGems + 1)
	var emptySocketId = gemRange - 1

	var numItems = LEGACY_NUM_ITEMS
	if _later_or_equal(entry_version, "1.1.0"):
		numItems = ItemBook.getNumItems()

	var names: Array = []
	while bs.bits_left() >= 8:
		var index = bs.pull(numItems)
		if index == -1 or index >= numItems:
			return null
		var descriptor = ItemBook.getDescriptorFromIndex(index)
		if descriptor == null or descriptor.get("scene") == null:
			return null
		if bs.pull(INVENTORY_X) == -1 or bs.pull(INVENTORY_Y) == -1:
			return null
		if bs.pull(4) == -1:
			return null

		var name = descriptor.getName()
		names.push_back(name)

		var numSockets = ItemBook.getNumSockets(index)
		if numSockets > 0:
			var hasGems = bs.pull(2)
			if hasGems == -1:
				return null
			if hasGems == 1:
				for _socket in numSockets:
					var gemIndex = bs.pull(gemRange)
					if gemIndex == -1:
						return null
					if gemIndex >= numGems and gemIndex != emptySocketId:
						return null

		# getDataPersistent exists on exactly one item script (Magic Ring);
		# its blob width is int(getP("effects")) * (2 + 4) bits.
		if name == "Magic Ring":
			var numBits = int(descriptor.getP("effects")) * 6
			if bs.pull_bitsize(numBits) == -1:
				return null
	return names


static func _binary_ceil(number: float) -> int:
	# Game parity: BitStream.binaryCeil = pow(2, ceil(log2(n))).
	return int(pow(2, ceil(log(number) / log(2))))


static func _later_or_equal(version: String, base: String) -> bool:
	# Game parity: Util.laterOrEqual - numeric dot-part comparison.
	var parts = version.split(".")
	var baseParts = base.split(".")
	for i in range(parts.size()):
		var part = int(parts[i])
		var basePart = int(baseParts[i]) if i < baseParts.size() else 0
		if part > basePart:
			return true
		if part < basePart:
			return false
	return true
