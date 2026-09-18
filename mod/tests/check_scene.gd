extends Node

# Parse/compile check for the Core mod scripts. Runs as the project's main
# scene (normal run mode) because -s script mode does not register global
# classes from the script class cache, and the adapter references the game
# classes RunDatabase/SteamHelper/RunData. The stubs + .godot cache make
# those resolvable here. Scripts are copied to res://Core/ first: that
# satisfies the adapter's res://Core/* preloads and dodges the
# Core/SteamWorkshop.gd.remap pack artifact that hijacks loads of the
# original path. A failed compile still yields a non-null GDScript resource,
# so validity is asserted via can_instance().

const FILES := ["BbofLog.gd", "GhostDb.gd", "SteamWorkshop.gd", "BitStream.gd", "BoardDecoder.gd"]


func _ready() -> void:
	var failures := 0
	var src_dir := ProjectSettings.globalize_path("res://").plus_file("../mod.unpacked/Core/")
	var dst_dir := ProjectSettings.globalize_path("res://").plus_file("Core/")
	var dir := Directory.new()
	dir.make_dir_recursive(dst_dir)
	for name in FILES:
		dir.copy(src_dir.plus_file(name), dst_dir.plus_file(name))
	for name in FILES:
		var script = load("res://Core/".plus_file(name))
		if script == null or not script.can_instance():
			print("FAIL %s — did not compile" % name)
			failures += 1
		else:
			print("OK %s" % name)
	print("parse_failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
