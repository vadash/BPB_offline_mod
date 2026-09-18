extends Node
class_name SteamLeaderboard

# ---------------------------------------------------------------------------
# BBOF override — replaces Steam leaderboard I/O with a local ghost DB read.
# Thin adapter: keeps the game contract (class_name SteamLeaderboard, the
# fields RunDatabase reads, pushScore/downloadScores) and delegates every
# ghost-DB read to Core/GhostDb.gd. Upload path persists player state to
# player_state.json (sidecar, not in DB); download path reads ghosts.gdb
# placed next to the game executable (BGDB v1, written by the seeder).
# ---------------------------------------------------------------------------

const BbofLog = preload("res://Core/BbofLog.gd")
const GhostDb = preload("res://Core/GhostDb.gd")
const BoardDecoder = preload("res://Core/BoardDecoder.gd")

# Fields read by RunDatabase — must remain present and correctly typed.
var gotResponse: bool = false
var largestSequenceNumber: int = 0
var parsedRuns: Array = []
var downloading: bool = false

# Player state loaded from player_state.json sidecar (written by pushScore).
var _player_state: Dictionary = {}
var _log: BbofLog
var _db_path: String
var _state_path: String
var _filter_path: String
var _excl_classes: Array = []
var _excl_items: Array = []
var _ghost
var _decoder


func _ready():
	var exe_dir = OS.get_executable_path().get_base_dir()
	_db_path = exe_dir + "/ghosts.gdb"
	_state_path = exe_dir + "/player_state.json"
	_filter_path = exe_dir + "/ghost_filter.json"
	_log = BbofLog.new()
	_log.open(exe_dir + "/bbof.log")
	_log.info("init steam_id=%s db=%s" % [SteamHelper.STEAM_ID, _db_path.get_file()])
	_ghost = GhostDb.new()
	_ghost.setup(_db_path, _log, funcref(self, "_parse_single"))
	_decoder = BoardDecoder.new()
	call_deferred("_load_from_db")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_log.close()


# Contract guards: anything the game reads that is not a declared field above
# used to be one of the pruned dead members — surface it in the log instead
# of failing silently.
func _get(property):
	if _log: _log.warn("contract_access unknown_get field=%s" % str(property))
	return null


func _set(property, value):
	if _log: _log.warn("contract_access unknown_set field=%s" % str(property))
	return false


# The game's own score parser, injected into GhostDb so the deep module
# never references game classes.
func _parse_single(dict):
	return RunDatabase.parseSingleScore(dict, true, false)


func downloadScores() -> void:
	if gotResponse:
		return
	_load_from_db()


func _load_state() -> void:
	_player_state = {}
	var f = File.new()
	if not f.file_exists(_state_path):
		return
	var err = f.open(_state_path, File.READ)
	if err != OK:
		_log.warn("state_load_fail error=%d" % err)
		return
	var p = JSON.parse(f.get_as_text())
	f.close()
	if p.error == OK and typeof(p.result) == TYPE_DICTIONARY:
		_player_state = p.result
		_log.info("state_loaded rank=%s r=%s db_rows=%s seq=%s" % [
			_player_state.get("estimated_rank", "(none)"),
			_player_state.get("r", "(none)"),
			_player_state.get("db_row_count", "(none)"),
			_player_state.get("sequence_number", "(none)")])
	else:
		_log.warn("state_malformed — starting fresh")


func _save_state() -> void:
	var f = File.new()
	var err = f.open(_state_path, File.WRITE)
	if err != OK:
		_log.warn("state_save_fail error=%d path=%s" % [err, _state_path])
		return
	var content = JSON.print(_player_state)
	f.store_string(content)
	f.close()
	_log.info("state_saved path=%s bytes=%d" % [_state_path.get_file(), content.length()])


func _fail_load(reason: String) -> void:
	_log.warn(reason)
	gotResponse = true
	downloading = false
	RunDatabase.call_deferred("onSteamRunsReceived")


# Read ghost_filter.json next to the exe, fresh on every download. Optional
# "exclude_classes" / "exclude_items" string arrays; missing file = no-op.
# Malformed JSON, wrong types, or non-string entries: one warn, both lists
# treated as empty — a bad filter file never blocks a download.
func _load_filter() -> void:
	_excl_classes = []
	_excl_items = []
	var f = File.new()
	if not f.file_exists(_filter_path):
		_log.info("filter off no ghost_filter.json")
		return
	var err = f.open(_filter_path, File.READ)
	if err != OK:
		_log.warn("filter_read_fail error=%d" % err)
		return
	var p = JSON.parse(f.get_as_text())
	f.close()
	if p.error != OK or typeof(p.result) != TYPE_DICTIONARY:
		_log.warn("filter_malformed — exclusions disabled")
		return
	var raw_classes = p.result.get("exclude_classes", [])
	var raw_items = p.result.get("exclude_items", [])
	if typeof(raw_classes) != TYPE_ARRAY or typeof(raw_items) != TYPE_ARRAY:
		_log.warn("filter_malformed — exclusions disabled")
		return
	for v in raw_classes:
		if typeof(v) != TYPE_STRING:
			_log.warn("filter_malformed — exclusions disabled")
			return
	for v in raw_items:
		if typeof(v) != TYPE_STRING:
			_log.warn("filter_malformed — exclusions disabled")
			return
	_excl_classes = raw_classes
	_excl_items = raw_items
	_log.info("filter loaded classes=%d items=%d" % [raw_classes.size(), raw_items.size()])


# Exclusion filter handed to GhostDb: returns a rule label for runs to drop,
# "" to keep. Class checks use the game's safe getClassName; item checks use
# the mod-side BoardDecoder - never the game's decode family, which crashes
# the process by name (ADR 0002, docs/board-format.md).
func _filter_run(run) -> String:
	# 1-arg get only: Object.get takes one argument in Godot 3 (the 2-arg
	# default form is Dictionary-only and raises a runtime error on the game's
	# RunData objects, which would silently kill every ghost).
	var cc = run.get("characterClass")
	if cc != null:
		var cname = Game.getClassName(int(cc))
		if cname in _excl_classes:
			return "class=" + cname
	var rounds = run.get("rounds")
	if rounds != null and _excl_items.size() > 0:
		var version = str(run.get("entryVersion"))
		for i in range(rounds.size()):
			var names = _decoder.decode_item_names(str(rounds[i]), version)
			if names == null:
				continue
			for iname in names:
				if iname in _excl_items:
					return "item=" + iname
	return ""


func _load_from_db() -> void:
	if downloading or gotResponse:
		return
	downloading = true
	parsedRuns.clear()
	_load_filter()
	_load_state()
	largestSequenceNumber = max(int(_player_state.get("sequence_number", 0)), largestSequenceNumber)

	var state = {
		"player_r": _player_state.get("r", null),
		"estimated_rank": int(_player_state.get("estimated_rank", -1)),
		"db_row_count": int(_player_state.get("db_row_count", 0)),
		# Game dependency stays in the adapter: the opponent window size
		# comes from the game's own mode.
		"window": 60000 if RunDatabase.statisticsMode else 2001,
		"player_id": int(SteamHelper.STEAM_ID) if SteamHelper.STEAM_ID != 0 else -1,
		"cached_min_d": str(_player_state.get("min_d", "(none)")),
	}
	# Exclusions active: hand GhostDb the adapter-side filter. GhostDb stays
	# game-agnostic and only forwards runs to it.
	if _excl_classes.size() > 0 or _excl_items.size() > 0:
		state["filter_fn"] = funcref(self, "_filter_run")
	var res = _ghost.load_ghosts(state)
	if not res.ok:
		_fail_load(res.reason)
		return

	# Sidecar updates the DB read produced: the probed min-d cutoff, and the
	# re-estimated rank with fresh row count when the DB was replaced.
	if res.min_d != "":
		_player_state["min_d"] = res.min_d
	if res.db_changed and res.rank >= 0:
		_player_state["estimated_rank"] = res.rank
		_player_state["db_row_count"] = res.db_rows
	if res.min_d != "" or (res.db_changed and res.rank >= 0):
		_save_state()

	for run in res.runs:
		parsedRuns.push_back(run)

	gotResponse = true
	downloading = false
	RunDatabase.call_deferred("onSteamRunsReceived")


# ---------------------------------------------------------------------------
# Upload path — persists player state to player_state.json, no Steam calls.
# ---------------------------------------------------------------------------

func pushScore(_steamMetaDataString: String, _sequenceNumber: int) -> void:
	var meta_len = _steamMetaDataString.length() if _steamMetaDataString != null else -1
	var meta_preview = _steamMetaDataString.substr(0, 120) if meta_len > 0 else "(empty)"
	_log.info("push seq=%d meta_len=%d steam_id=%s preview='%s'" % [_sequenceNumber, meta_len, str(SteamHelper.STEAM_ID), meta_preview])

	var player_r = null
	var player_d = ""
	var parsed = JSON.parse(_steamMetaDataString)
	if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
		player_r = parsed.result.get("r", null)
		player_d = str(parsed.result.get("d", ""))
		if player_r == null:
			_log.warn("push no_r_field keys=%s" % str(parsed.result.keys()))
		else:
			_log.info("push meta_ok r=%s d=%s" % [str(player_r), player_d])
	else:
		_log.warn("push meta_parse_fail error=%d type=%d" % [parsed.error, typeof(parsed.result)])

	var estimated_rank = int(_player_state.get("estimated_rank", -1))
	var db_rows = 0

	if player_r != null:
		db_rows = _ghost.row_count()
		if db_rows < 0:
			_log.warn("push db_open_fail state not written")
		else:
			estimated_rank = _ghost.estimate_rank(player_r)
			if estimated_rank < 0:
				_log.warn("push rank_estimate_no_rows db may be empty")
			_log.info("push db_ok rows=%d rank=%d" % [db_rows, estimated_rank])

			if SteamHelper.STEAM_ID != 0:
				_player_state["steam_id"] = SteamHelper.STEAM_ID
				_player_state["estimated_rank"] = estimated_rank
				_player_state["sequence_number"] = _sequenceNumber
				_player_state["r"] = player_r
				_player_state["d"] = player_d
				_player_state["db_row_count"] = db_rows
				_player_state["last_metadata"] = _steamMetaDataString
				_save_state()
			else:
				_log.warn("push no_steam_id seq=%d state not written" % _sequenceNumber)
	else:
		_log.info("push skip_db player_r is null")

	largestSequenceNumber = max(_sequenceNumber, largestSequenceNumber)
	call_deferred("onSteamLeaderboardUploaded", 1, 0, {})


func onSteamLeaderboardUploaded(result: int, _this_handle: int, _this_score: Dictionary) -> void:
	_log.info("upload_mocked result=%d" % result)


func onSteamLeaderboardUGCSet(_leaderboard_handle, _result: String):
	pass
