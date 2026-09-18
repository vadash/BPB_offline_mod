extends Node

# Stub of the game's RunDatabase autoload. Registered as an autoload in
# project.godot (NOT a global class) so identifier resolution matches the
# game: the adapter calls members on the autoload instance. parseSingleScore
# stays callable through that instance exactly like the shipped call form.

var statisticsMode := false


func onSteamRunsReceived(_runs) -> void:
	pass


func parseSingleScore(_dict, _a, _b) -> Dictionary:
	return {}
