extends Node

# Compile-time stub for the game's ItemBook autoload. The SteamWorkshop
# filter reads `items` (the game's name-keyed item data) to validate
# ghost_filter.json names, and passes this global to the BoardDecoder as the
# item-data seam (ADR 0002) — so the descriptor facts delegate to the same
# dump-backed double the decode tests use, fed by the committed
# item_book_dump.json. Only key presence is consulted in `items`.
var items = {"Wooden Sword": null, "Magic Ring": null, "False Life": null, "Holy Armor": null}

const _DumpItemData = preload("res://dump_item_data.gd")

var _data


func _facts():
	if _data == null:
		var dump = {}
		var f = File.new()
		if f.open("res://fixtures/item_book_dump.json", File.READ) == OK:
			var parsed = parse_json(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				dump = parsed
		_data = _DumpItemData.new(dump)
	return _data


func getNumItems() -> int:
	return _facts().getNumItems()


func getNumSockets(itemIndex) -> int:
	return _facts().getNumSockets(itemIndex)


func getNumGems() -> int:
	return _facts().getNumGems()


func getDescriptorFromIndex(itemIndex):
	return _facts().getDescriptorFromIndex(itemIndex)
