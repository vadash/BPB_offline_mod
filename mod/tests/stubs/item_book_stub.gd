extends Node

# Compile-time stub for the game's ItemBook autoload (check scene context).
# BoardDecoder no longer references this global (item facts arrive via the
# item-data seam), but the SteamWorkshop filter test reads `items` - the
# game's name-keyed item data - to validate ghost_filter.json names.
# Only key presence is consulted; values are never dereferenced.
var items = {"Wooden Sword": null, "Magic Ring": null}

func getNumItems() -> int:
	return 0


func getNumSockets(_itemIndex) -> int:
	return 0


func getNumGems() -> int:
	return 0


func getDescriptorFromIndex(_index):
	return null
