extends Reference

# Self-contained port of the game's BitStream (docs/board-format.md).
# Deliberately NOT registered as class_name: the game ships its own global
# BitStream and a second registration would collide. Only the pieces board
# decoding needs: 6-bit-per-character Godot strings and MSB-first pulls.
#
# Hot-path shape: the stream is kept as raw ASCII bytes and pulls consume
# whole 6-bit chars with integer arithmetic. The first board-decode port
# expanded every char into six Array push_backs and pulled bit by bit,
# which profiled as the single largest cost of a mod load (board decode
# runs per round of every candidate ghost). Semantics are byte-identical
# to the per-bit version run_tests.gd pins: dry pulls return -1 and pin
# currentBit at the stream end, partial fields may have been consumed.

const BASE64OFFSET = 62

var bytes: PoolByteArray = PoolByteArray()
var num_bits: int = 0
var currentBit: int = 0
# _num_bits per rangeMax, filled lazily: the game parity formula costs two
# log() calls per pull and boards pull the same widths thousands of times
# per load.
var _nb_cache: Dictionary = {}


func from_godot_string(string: String) -> bool:
	bytes = string.to_ascii()
	num_bits = bytes.size() * 6
	currentBit = 0
	for i in range(bytes.size()):
		var offsetByte = int(bytes[i]) - BASE64OFFSET
		if offsetByte < 0 or offsetByte > 63:
			return false
	return true


func bits_left() -> int:
	return num_bits - currentBit


# ceil(log2(rangeMax)) bits, MSB first; 0 bits consumed when rangeMax <= 1;
# -1 once the stream runs dry (partial field may have been consumed).
# Body is pull_bitsize with the width from _nb_cache - kept in sync with it.
# Inlined because boards pull ~6 fields per item and each saved call frame
# is measurable in GDScript.
func pull(rangeMax: int) -> int:
	if rangeMax <= 1:
		return 0
	var numBits = _nb_cache.get(rangeMax)
	if numBits == null:
		numBits = _num_bits(rangeMax)
		_nb_cache[rangeMax] = numBits
	var end = currentBit + numBits
	if end > num_bits:
		# Dry stream: currentBit pinned at the stream end, field is dead.
		currentBit = num_bits
		return -1
	var value = 0
	var remaining = numBits
	while remaining > 0:
		var bit_in_char = currentBit % 6
		var take = 6 - bit_in_char
		if take > remaining:
			take = remaining
		var char_val = int(bytes[int(currentBit / 6.0)]) - BASE64OFFSET
		value = (value << take) | ((char_val >> (6 - bit_in_char - take)) & ((1 << take) - 1))
		currentBit += take
		remaining -= take
	return value


func pull_bitsize(numBits: int) -> int:
	var end = currentBit + numBits
	if end > num_bits:
		# Dry stream: same end state as the per-bit loop that stopped at
		# the first missing bit - currentBit pinned at the stream end.
		currentBit = num_bits
		return -1
	var value = 0
	var remaining = numBits
	while remaining > 0:
		var bit_in_char = currentBit % 6
		var take = 6 - bit_in_char
		if take > remaining:
			take = remaining
		var char_val = int(bytes[int(currentBit / 6.0)]) - BASE64OFFSET
		var shift = 6 - bit_in_char - take
		value = (value << take) | ((char_val >> shift) & ((1 << take) - 1))
		currentBit += take
		remaining -= take
	return value


static func _num_bits(rangeMax: int) -> int:
	# Game parity: ceil(Util.log2(n)) with log2 = log(n) / log(2).
	return int(ceil(log(rangeMax) / log(2)))
