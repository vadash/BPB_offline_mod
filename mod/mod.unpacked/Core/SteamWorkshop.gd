extends Node
class_name SteamLeaderboard

# ---------------------------------------------------------------------------
# BBOF override — replaces Steam leaderboard I/O with a local ghost DB read.
# Thin adapter: keeps the game contract (class_name SteamLeaderboard, the
# fields RunDatabase reads, pushScore/downloadScores) and delegates every
# ghost-DB read to Core/GhostDb.gd. Upload path persists player state to
# player_state.json (sidecar, not in DB): per-class ranked ratings
# (r_by_class), the anchored class + rank estimate, sequence number, min-d
# cutoff. Download path reads the newest top-level *.gdb next to the game
# executable (GhostDb.pick_db_path, fixed once at startup; BGDB v1, written
# by the seeder), centered on the current class's anchor.
# ---------------------------------------------------------------------------

const BbofLog = preload("res://Core/BbofLog.gd")
const GhostDb = preload("res://Core/GhostDb.gd")
const BoardDecoder = preload("res://Core/BoardDecoder.gd")

# The game's RunDatabase.UNRANKED_RATING: metadata r value for non-ranked
# runs. Means "no rating" — such uploads never move the class anchor.
const UNRANKED_RATING = -1000

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
# "exclude_perfect": drop ghosts whose first ten round results are all wins
# (a finished 10-0 run, CONTEXT.md "Perfect ghost"). Default on: absent file
# or absent key keeps it active.
var _exclude_perfect: bool = true
var _ghost
var _decoder


func _ready():
	var exe_dir = OS.get_executable_path().get_base_dir()
	_dump_items(exe_dir)
	_state_path = exe_dir + "/player_state.json"
	_filter_path = exe_dir + "/ghost_filter.json"
	_log = BbofLog.new()
	_log.open(exe_dir + "/bbof.log")
	# Newest-DB pick: any top-level *.gdb next to the exe wins by mtime;
	# fixed for the session (GhostDb.pick_db_path logs the fallback miss).
	_db_path = GhostDb.pick_db_path(exe_dir, _log)
	_log.info("init steam_id=%s db=%s" % [SteamHelper.STEAM_ID, _db_path.get_file()])
	_ghost = GhostDb.new()
	_ghost.setup(_db_path, _log, funcref(self, "_parse_single"))
	_decoder = BoardDecoder.new()
	call_deferred("_load_from_db")


# Item-data dump (ADR 0002): every start rewrites item_book_dump.json next
# to the exe - the ItemBook facts the board decoder reads (exact names,
# socket counts, scene presence, effects). Always fresh after game updates;
# the copy kept in mod/tests/fixtures/ feeds the headless decode tests and
# doubles as the exact item-name reference for authoring ghost_filter.json.
func _dump_items(exe_dir: String) -> void:
	var n = min(int(ItemBook.getNumItems()), int(ItemBook.descriptorList.size()))
	var sockets: Array = ItemBook.numSockets
	var items = []
	for i in range(n):
		var d = ItemBook.getDescriptorFromIndex(i)
		items.push_back({
			"name": d.getName() if d != null else null,
			"sockets": int(sockets[i]) if i < sockets.size() else 0,
			"scene": d != null and d.get("scene") != null,
			"effects": d.getP("effects") if d != null and d.hasParam("effects") else null,
		})
	var f = File.new()
	if f.open(exe_dir + "/item_book_dump.json", File.WRITE) != OK:
		print("bbof: item_book_dump.json not written (dir not writable)")
		return
	f.store_line(to_json({
		"game_version": str(Game.VERSION),
		"num_gems": int(ItemBook.getNumGems()),
		"num_items": items.size(),
		"items": items,
	}))
	f.close()


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
		_migrate_state()
		var map = _player_state.get("r_by_class", {})
		_log.info("state_loaded rank=%s anchor=%s classes=%d db_rows=%s seq=%s" % [
			_player_state.get("estimated_rank", "(none)"),
			_player_state.get("anchor_class", "(none)"),
			map.size(),
			_player_state.get("db_row_count", "(none)"),
			_player_state.get("sequence_number", "(none)")])
	else:
		_log.warn("state_malformed — starting fresh")


# Legacy sidecars carried one scalar r (last uploaded run, any class) plus
# write-only r/d/last_metadata. Seed the per-class map from the stored
# run's own metadata so the first download keeps the old window center
# instead of treating that class as unseen (anchor 0.0). One-way: after
# this, the scalar keys are gone and _save_state writes the new schema.
func _migrate_state() -> void:
	if _player_state.has("r_by_class"):
		_player_state.erase("r")
		_player_state.erase("d")
		_player_state.erase("last_metadata")
		return
	var legacy_r = _player_state.get("r", null)
	var map = {}
	if legacy_r != null:
		var meta_text = str(_player_state.get("last_metadata", ""))
		var cls = -1
		if meta_text != "":
			var parsed = JSON.parse(meta_text)
			if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
				# The game's parser requires the ugc field (steamFields =
				# sharedFields + ["ugc", "p"]); GhostDb injects it for every
				# ghost — the pushed metadata carries p but never ugc.
				parsed.result["ugc"] = 1
				var run = _parse_single(parsed.result)
				if run != null:
					cls = int(run.get("characterClass"))
		if cls >= 0:
			map[str(cls)] = float(legacy_r)
		else:
			_log.warn("state_migrate_no_class legacy r dropped")
	_player_state["r_by_class"] = map
	_player_state.erase("r")
	_player_state.erase("d")
	_player_state.erase("last_metadata")


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
# "exclude_classes" / "exclude_items" string arrays plus the boolean
# "exclude_perfect" (default on). Malformed JSON, wrong types, or non-string
# entries: one warn, the whole filter is disabled — a bad filter file never
# blocks a download.
func _load_filter() -> void:
	_excl_classes = []
	_excl_items = []
	_exclude_perfect = true
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
		_exclude_perfect = false
		return
	var raw_classes = p.result.get("exclude_classes", [])
	var raw_items = p.result.get("exclude_items", [])
	if typeof(raw_classes) != TYPE_ARRAY or typeof(raw_items) != TYPE_ARRAY:
		_log.warn("filter_malformed — exclusions disabled")
		_exclude_perfect = false
		return
	for v in raw_classes:
		if typeof(v) != TYPE_STRING:
			_log.warn("filter_malformed — exclusions disabled")
			_exclude_perfect = false
			return
	for v in raw_items:
		if typeof(v) != TYPE_STRING:
			_log.warn("filter_malformed — exclusions disabled")
			_exclude_perfect = false
			return
	var raw_perfect = p.result.get("exclude_perfect", true)
	if typeof(raw_perfect) != TYPE_BOOL:
		_log.warn("filter_malformed — exclusions disabled")
		_exclude_perfect = false
		return
	_excl_classes = raw_classes
	_excl_items = raw_items
	_exclude_perfect = raw_perfect
	# A name the item data does not know can never match a decode; warn
	# once at load so typos in ghost_filter.json surface in bbof.log. Never
	# blocks the download - exclusions stay loaded as given.
	for v in raw_items:
		if not ItemBook.items.has(v):
			_log.warn("filter_unknown_item name=" + v)
	_log.info("filter loaded classes=%d items=%d perfect=%s" % [raw_classes.size(), raw_items.size(), str(_exclude_perfect)])


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
	# Perfect ghost (CONTEXT.md): first Game.MAX_WINS round results all wins —
	# a finished 10-0 run. A draw or loss in the first ten disqualifies; a
	# missing or short results array means "cannot match" and keeps the run.
	if _exclude_perfect:
		var results = run.get("results")
		if results != null and results.size() >= Game.MAX_WINS:
			var perfect = true
			for i in range(Game.MAX_WINS):
				if int(results[i]) != Game.RoundResult.Win:
					perfect = false
					break
			if perfect:
				return "perfect"
	var rounds = run.get("rounds")
	if rounds != null and _excl_items.size() > 0:
		var version = str(run.get("entryVersion"))
		for i in range(rounds.size()):
			# The ItemBook global is the item-data seam argument (ADR 0002) -
			# BoardDecoder itself never touches the global.
			var names = _decoder.decode_item_names(str(rounds[i]), version, ItemBook)
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

	# The download fires at startup, after the game picked its class
	# (Game autoload precedes RunDatabase, so curClass is set by the time
	# this deferred call runs).
	var cur_class = int(Game.curClass)

	var state = {
		# Per-class anchor: the current class's own r; a class never uploaded
		# anchors at the game's fresh-class rating (0.0 — bottom of the
		# distribution, matching how the game leagues a fresh class).
		"player_r": _player_state.get("r_by_class", {}).get(str(cur_class), 0.0),
		"estimated_rank": int(_player_state.get("estimated_rank", -1)),
		"db_row_count": int(_player_state.get("db_row_count", 0)),
		"anchor_class": int(_player_state.get("anchor_class", -1)),
		"current_class": cur_class,
		# Game dependency stays in the adapter: the opponent window size
		# comes from the game's own mode.
		"window": 60000 if RunDatabase.statisticsMode else 2001,
		"player_id": int(SteamHelper.STEAM_ID) if SteamHelper.STEAM_ID != 0 else -1,
		"cached_min_d": str(_player_state.get("min_d", "(none)")),
	}
	# Exclusions active: hand GhostDb the adapter-side filter. GhostDb stays
	# game-agnostic and only forwards runs to it.
	if _excl_classes.size() > 0 or _excl_items.size() > 0 or _exclude_perfect:
		state["filter_fn"] = funcref(self, "_filter_run")
	var res = _ghost.load_ghosts(state)
	if not res.ok:
		_fail_load(res.reason)
		return

	# Sidecar updates the DB read produced: the probed min-d cutoff, and the
	# re-estimated rank with fresh row count when the DB was replaced or the
	# anchor class changed.
	if res.min_d != "":
		_player_state["min_d"] = res.min_d
	if res.db_changed and res.rank >= 0:
		_player_state["estimated_rank"] = res.rank
		_player_state["db_row_count"] = res.db_rows
		_player_state["anchor_class"] = cur_class
	if res.min_d != "" or (res.db_changed and res.rank >= 0):
		_save_state()

	for run in res.runs:
		parsedRuns.push_back(run)

	# Acceptance aid, off by default: BBOF_DUMP_RUNS=1 writes one run key
	# per line in pool order next to the exe, so a pipeline change can be
	# diffed old-vs-new byte for byte.
	if OS.get_environment("BBOF_DUMP_RUNS") == "1":
		var dump = File.new()
		if dump.open(_state_path.get_base_dir() + "/bbof_runs.txt", File.WRITE) == OK:
			for run in parsedRuns:
				var rid = run.get("id")
				if rid == null:
					rid = run.get("playerId")
				dump.store_line(str(rid))
			dump.close()
			_log.info("runs_dumped path=bbof_runs.txt count=%d" % parsedRuns.size())

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
	var parsed = JSON.parse(_steamMetaDataString)
	if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
		player_r = parsed.result.get("r", null)
		if player_r == null:
			_log.warn("push no_r_field keys=%s" % str(parsed.result.keys()))
		else:
			_log.info("push meta_ok r=%s" % str(player_r))
	else:
		_log.warn("push meta_parse_fail error=%d type=%d" % [parsed.error, typeof(parsed.result)])

	var estimated_rank = int(_player_state.get("estimated_rank", -1))
	var db_rows = 0

	if player_r != null:
		db_rows = _ghost.row_count()
		if db_rows < 0:
			_log.warn("push db_open_fail anchor not written")
		else:
			# The uploaded run's class comes from its own metadata, through
			# the game's safe parser — never game decode calls.
			var cls = -1
			# Same injection as the migration path: the game's parser requires
			# ugc (steamFields = sharedFields + ["ugc", "p"]) and pushed
			# metadata never carries it. Without it every ranked push parses
			# classless and the anchor never moves.
			parsed.result["ugc"] = 1
			var run = _parse_single(parsed.result)
			if run != null:
				cls = int(run.get("characterClass"))
			if player_r == UNRANKED_RATING:
				_log.info("push unranked anchor untouched class=%d" % cls)
			elif cls < 0:
				_log.warn("push no_class anchor not written")
			else:
				# Ranked upload: this class's anchor moves to the run's r.
				var map = _player_state.get("r_by_class", {})
				map[str(cls)] = float(player_r)
				_player_state["r_by_class"] = map
				estimated_rank = _ghost.estimate_rank(player_r)
				if estimated_rank < 0:
					_log.warn("push rank_estimate_no_rows rank anchor kept")
				else:
					_player_state["estimated_rank"] = estimated_rank
					_player_state["anchor_class"] = cls
				_log.info("push db_ok rows=%d rank=%s class=%d" % [db_rows, str(estimated_rank), cls])
	else:
		_log.info("push skip_db player_r is null")

	largestSequenceNumber = max(_sequenceNumber, largestSequenceNumber)
	if SteamHelper.STEAM_ID != 0:
		# Sequence tracking is mode-independent: unranked runs advance it
		# even though they never move the anchor.
		_player_state["steam_id"] = SteamHelper.STEAM_ID
		_player_state["sequence_number"] = _sequenceNumber
		_player_state["db_row_count"] = db_rows if db_rows >= 0 else int(_player_state.get("db_row_count", 0))
		_save_state()
	else:
		_log.warn("push no_steam_id seq=%d state not written" % _sequenceNumber)
	call_deferred("onSteamLeaderboardUploaded", 1, 0, {})


func onSteamLeaderboardUploaded(result: int, _this_handle: int, _this_score: Dictionary) -> void:
	_log.info("upload_mocked result=%d" % result)


func onSteamLeaderboardUGCSet(_leaderboard_handle, _result: String):
	pass
