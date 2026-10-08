extends Node

# Compile-time stub for the game's Game autoload (check_scene.gd context).
# Only members the adapter references exist; return values are irrelevant
# to the compile check.

# Same shape as the game's Game.gd: a ranked run ends at MAX_WINS wins, and
# results are per-day Win/Loss/Draw/RunOver (Win first, value 0).
enum RoundResult { Win, Loss, Draw, RunOver }
const MAX_WINS = 10

# Stub names for the class-exclusion rule label ("class=" + name). The real
# game supplies its own names in production.
var _class_names = {0: "Ranger", 1: "Rogue", 2: "Engineer"}


func getClassName(charClass = 0) -> String:
	return _class_names.get(int(charClass), "")
