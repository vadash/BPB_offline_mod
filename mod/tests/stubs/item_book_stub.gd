extends Node

# Compile-time stub for the game's ItemBook autoload (check scene context).
# BoardDecoder references these data lookups; return values are irrelevant
# to the compile check.

func getNumItems() -> int:
	return 0


func getNumSockets(_itemIndex) -> int:
	return 0


func getNumGems() -> int:
	return 0


func getDescriptorFromIndex(_index):
	return null
