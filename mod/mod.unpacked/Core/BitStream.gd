extends Reference

# Self-contained port of the game's BitStream (docs/board-format.md).
# Deliberately NOT registered as class_name: the game ships its own global
# BitStream and a second registration would collide. Only the pieces board
# decoding needs: 6-bit-per-character Godot strings and MSB-first pulls.

const BASE64OFFSET = 62

var bits: Array = []
var currentBit: int = 0


func from_godot_string(string: String) -> bool:
	bits = []
	currentBit = 0
	for byte in string.to_ascii():
		var offsetByte = byte - BASE64OFFSET
		if offsetByte < 0 or offsetByte > 63:
			return false
		for digit in range(5, -1, -1):
			bits.push_back((offsetByte >> digit) & 1)
	return true


func bits_left() -> int:
	return bits.size() - currentBit


# ceil(log2(rangeMax)) bits, MSB first; 0 bits consumed when rangeMax <= 1;
# -1 once the stream runs dry (partial field may have been consumed).
func pull(rangeMax: int) -> int:
	if rangeMax <= 1:
		return 0
	return pull_bitsize(_num_bits(rangeMax))


func pull_bitsize(numBits: int) -> int:
	var value = 0
	for digit in range(numBits - 1, -1, -1):
		if currentBit == bits.size():
			return -1
		value += bits[currentBit] << digit
		currentBit += 1
	return value


static func _num_bits(rangeMax: int) -> int:
	# Game parity: ceil(Util.log2(n)) with log2 = log(n) / log(2).
	return int(ceil(log(rangeMax) / log(2)))
