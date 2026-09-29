extends Reference

# Test double for the game's ItemBook item facts (tests-only), backed by the
# committed item_book_dump.json rows. Duck-types exactly the item-data seam
# BoardDecoder.decode_item_names reads: getNumItems/getNumGems/
# getNumSockets/getDescriptorFromIndex, descriptors exposing getName/get/getP.

var _num_items: int
var _num_gems: int
var _rows: Array
# Test hook: getDescriptorFromIndex returns null at this in-range index
# (the production ItemBook can leave descriptorList holes).
var _null_index: int = -1


func _init(dump: Dictionary) -> void:
	_num_items = int(dump.get("num_items", 0))
	_num_gems = int(dump.get("num_gems", 0))
	_rows = dump.get("items", [])


func getNumItems() -> int:
	return _num_items


func getNumGems() -> int:
	return _num_gems


func getNumSockets(item_index: int) -> int:
	return int(_rows[item_index]["sockets"])


func getDescriptorFromIndex(item_index: int):
	if item_index < 0 or item_index >= _rows.size() or item_index == _null_index:
		return null
	var row: Dictionary = _rows[item_index]
	var params = {}
	if row["effects"] != null:
		params["effects"] = float(row["effects"])
	return Descriptor.new(row["name"], row["scene"], params)


class Descriptor:
	var _name: String
	var _scene: bool
	var _params: Dictionary

	func _init(name, scene, params) -> void:
		_name = name
		_scene = scene
		_params = params

	func getName() -> String:
		return _name

	# Object.get consults _get; null = property absent (BoardDecoder's
	# "scene present" check).
	func _get(property):
		if property == "scene" and _scene:
			return true
		return null

	# Game parity with ItemDescriptor.getP: 0.0 for an absent param.
	func getP(param: String) -> float:
		return float(_params.get(param, 0.0))
