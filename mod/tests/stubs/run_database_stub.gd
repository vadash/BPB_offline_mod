extends Node

# Stub of the game's RunDatabase autoload. Registered as an autoload in
# project.godot (NOT a global class) so identifier resolution matches the
# game: the adapter calls members on the autoload instance. parseSingleScore
# stays callable through that instance exactly like the shipped call form.

var statisticsMode := false


func onSteamRunsReceived(_runs) -> void:
	pass


func parseSingleScore(_dict, _a, _b):
	# Documented game contract (Core/SteamWorkshop.gd migration comment):
	# the parser's steamFields require "ugc" — a metadata dict without it
	# parses to nothing. GhostDb and the adapter inject ugc before calling;
	# pushed metadata never carries it natively.
	if not _dict.has("ugc"):
		return null
	return {"characterClass": 0}
