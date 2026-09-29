extends Reference

# Test-side inverse of Core/BitStream.gd (tests-only): builds the Godot
# string encoding of a bit stream the way the game writes boards.
# push() mirrors BitStream.pull: ceil(log2(rangeMax)) bits, MSB first, no
# bits for rangeMax <= 1. to_godot_string() packs the bits 6 per char as
# chr(v + 62), zero-padding the final char - exactly what
# BitStream.from_godot_string reads back.

const BASE64OFFSET = 62

var bits: Array = []


func push(value: int, range_max: int) -> void:
	if range_max <= 1:
		return
	push_bitsize(value, _num_bits(range_max))


func push_bitsize(value: int, num_bits: int) -> void:
	for digit in range(num_bits - 1, -1, -1):
		bits.push_back((value >> digit) & 1)


func to_godot_string() -> String:
	var padded = bits.duplicate()
	while padded.size() % 6 != 0:
		padded.push_back(0)
	var out = ""
	for i in range(0, padded.size(), 6):
		var v = 0
		for b in range(6):
			v = (v << 1) | int(padded[i + b])
		out += char(v + BASE64OFFSET)
	return out


static func _num_bits(range_max: int) -> int:
	# Game parity: same expression as BitStream._num_bits.
	return int(ceil(log(range_max) / log(2)))
