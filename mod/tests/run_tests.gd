extends SceneTree

# Headless harness for the BBOF GhostDb deep module (Godot 3.6.2).
# Vocabulary: a "ghost" is one parsed opponent run; the "opponent window" is
# the rank range ghosts are drawn from; the "min-d cutoff" is the oldest ghost
# version the live game still accepts.
# Run via tests/run.ps1 — never launch Godot without --headless and -s.

const FIXTURE = preload("res://fixture.gd")

var GhostDbScript
var BbofLogScript
var BitStreamScript
var BoardDecoderScript
var SteamWorkshopScript
var BitWriterScript
var DumpItemDataScript

# Committed ItemBook dump (mod/tests/fixtures) backing the item-data double.
var _dump: Dictionary = {}
var _decoder
var _items

var checks: int = 0
var failures: int = 0

# Kills map driving fake_filter: id -> rule label the filter returns.
var _fake_filter_kills: Dictionary = {}

func _initialize() -> void:
	GhostDbScript = _core_script("GhostDb.gd")
	BbofLogScript = _core_script("BbofLog.gd")
	BitStreamScript = _core_script("BitStream.gd")
	# BoardDecoder and SteamWorkshop preload res://Core/*.gd at compile time;
	# copy the Core scripts into this project first (check_scene.gd's trick)
	# so those preloads resolve. Fresh copy every run - the mod.unpacked
	# originals stay the source of truth. BoardDecoder loads from the mod
	# tree (no class_name); SteamWorkshop must load from the copy because its
	# class_name SteamLeaderboard is registered against res://Core/ here.
	if _copy_core_scripts():
		BoardDecoderScript = _core_script("BoardDecoder.gd")
		SteamWorkshopScript = load("res://Core/SteamWorkshop.gd")
	BitWriterScript = load("res://bit_writer.gd")
	DumpItemDataScript = load("res://dump_item_data.gd")
	_dump = _load_dump()
	if _dump.size() > 0:
		_decoder = BoardDecoderScript.new()
		_items = DumpItemDataScript.new(_dump)
	if GhostDbScript == null or BbofLogScript == null or BitStreamScript == null \
			or BoardDecoderScript == null or SteamWorkshopScript == null \
			or BitWriterScript == null or DumpItemDataScript == null \
			or _dump.empty() or _decoder == null or _items == null:
		print("")
		print("checks=%d failures=%d" % [checks, failures])
		quit(1)
		return
	test_schema_gate()
	test_probe_min_d()
	test_window()
	test_zero_parse_fallback()
	test_estimate_rank()
	test_pick_db()
	test_filter_exclusions()
	test_refill()
	test_class_anchor()
	test_golden_db()
	test_golden_sweep()
	test_decode_item_names()
	test_decode_golden_smoke()
	test_bitstream_port()
	test_bitstream_reference()
	test_filter_unknown_item_warn()
	test_filter_perfect_flag()
	test_filter_summary_v2()
	test_push_anchor()
	print("")
	print("checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

# --- assert helpers ---------------------------------------------------------

func ok(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  ok    " + msg)
	else:
		failures += 1
		print("  FAIL  " + msg)

func eq(got, want, msg: String) -> void:
	ok(got == want, "%s (got: %s, want: %s)" % [msg, str(got), str(want)])

# --- scaffolding ------------------------------------------------------------

# GhostDb/BbofLog live in the mod tree, outside this test project's res:// root.
func _core_script(name: String):
	var abs_path = ProjectSettings.globalize_path("res://").plus_file("../mod.unpacked/Core/").plus_file(name)
	var script = load(abs_path)
	if script == null:
		failures += 1
		print("  FAIL  load %s — Core script not found" % name)
	return script

func user_path(name: String) -> String:
	return OS.get_user_data_dir().plus_file(name)

# Copies the Core scripts into res://Core/ so the compile-time preloads in
# BoardDecoder (BitStream) and SteamWorkshop (BbofLog, GhostDb,
# BoardDecoder) resolve inside this test project. Fresh copy every run - the
# mod.unpacked originals stay the source of truth.
func _copy_core_scripts() -> bool:
	var src_dir = ProjectSettings.globalize_path("res://").plus_file("../mod.unpacked/Core/")
	var dst_dir = ProjectSettings.globalize_path("res://").plus_file("Core/")
	var dir = Directory.new()
	if dir.make_dir_recursive(dst_dir) != OK:
		return false
	for name in ["BbofLog.gd", "GhostDb.gd", "BitStream.gd", "BoardDecoder.gd", "SteamWorkshop.gd"]:
		var dst = dst_dir.plus_file(name)
		if dir.file_exists(dst):
			dir.remove(dst)
		if dir.copy(src_dir.plus_file(name), dst) != OK:
			return false
	return true

# The committed dump of the ItemBook facts the decoder reads (auto-written
# next to the game exe every start, ADR 0002).
func _load_dump() -> Dictionary:
	var f = File.new()
	if f.open("res://fixtures/item_book_dump.json", File.READ) != OK:
		failures += 1
		print("  FAIL  fixtures/item_book_dump.json missing")
		return {}
	var parsed = parse_json(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("items"):
		failures += 1
		print("  FAIL  fixtures/item_book_dump.json malformed")
		return {}
	return parsed

func make_ghost(db_path: String, log_path: String, parse_fn = null) -> Dictionary:
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	var blog = BbofLogScript.new()
	blog.open(log_path)
	var gdb = GhostDbScript.new()
	# GDScript default args must be constants, so the standard double is
	# injected here instead of in the signature.
	if parse_fn == null:
		parse_fn = funcref(self, "fake_parse")
	gdb.setup(db_path, blog, parse_fn)
	return {"db": gdb, "log": blog, "log_path": log_path}

# Test double for the game's RunDatabase.parseSingleScore: a dict counts as a
# parseable ghost iff it carries a "score" field.
func fake_parse(dict):
	if dict.has("score"):
		return dict
	return null

# Test double for the adapter's exclusion filter: ids mapped in
# _fake_filter_kills die with their rule label, everything else is kept.
func fake_filter(run) -> String:
	var id = int(run.get("id", -1))
	if _fake_filter_kills.has(id):
		return _fake_filter_kills[id]
	return ""

func log_text(log_path: String) -> String:
	var f = File.new()
	if not f.file_exists(log_path):
		return ""
	f.open(log_path, File.READ)
	var text = f.get_as_text()
	f.close()
	return text

# Fresh empty folder for pick tests (user:// persists across runs).
func _fresh_dir(path: String) -> void:
	_rmtree(path)
	Directory.new().make_dir_recursive(path)

func _rmtree(path: String) -> void:
	var d = Directory.new()
	if not d.dir_exists(path):
		return
	d.open(path)
	d.list_dir_begin(true)
	var name = d.get_next()
	while name != "":
		if d.current_is_dir():
			_rmtree(path.plus_file(name))
		else:
			d.remove(path.plus_file(name))
		name = d.get_next()
	d.list_dir_end()
	d.remove(path)

# Tiny candidate file; content is irrelevant to the pick (names + mtime only).
func _touch(path: String) -> void:
	var f = File.new()
	f.open(path, File.WRITE)
	f.store_8(0)
	f.close()

# Rewrites the format_version u32 of a built DB: gate-reject legs need
# mismatching files the v2-only builder never produces.
func _patch_version(path: String, version: int) -> void:
	var f = File.new()
	f.open(path, File.READ_WRITE)
	f.seek(4)
	f.store_32(version)
	f.close()

# --- tests ------------------------------------------------------------------

# 1. Schema gate: a BGDB file whose format_version does not match is rejected
# with the old fail_load string. Strict v2: v0 and the retired v1 both fail;
# an unreadable header gates as "unknown".
func test_schema_gate() -> void:
	print("[TEST] schema gate (format_version mismatch, garbage header)")
	for ver in [0, 1]:
		var db_path = user_path("gate_%d.db" % ver)
		FIXTURE.build(db_path, [])
		_patch_version(db_path, ver)
		var g = make_ghost(db_path, user_path("gate_%d.log" % ver))
		var res = g.db.load_ghosts({
			"player_r": null,
			"estimated_rank": -1,
			"db_row_count": 0,
			"player_id": 0,
			"window": 100,
		})
		eq(res.get("ok", "(missing)"), false, "format_version=%d rejected: ok=false" % ver)
		eq(res.get("reason", "(missing)"), "db_schema_version ver=%d expected=2" % ver,
			"reason is the old fail_load string")
	var bad_path = user_path("gate_short.bin")
	var fw = File.new()
	fw.open(bad_path, File.WRITE)
	fw.store_buffer("gdb!".to_utf8())
	fw.close()
	var g2 = make_ghost(bad_path, user_path("gate_short.log"))
	var res2 = g2.db.load_ghosts({
		"player_r": null, "estimated_rank": -1, "db_row_count": 0,
		"player_id": 0, "window": 100,
	})
	eq(res2.get("reason", "(missing)"), "db_schema_version ver=unknown expected=2",
		"header too short reports ver=unknown")

	# The seeder writes v2 (per-run exclusion summaries): the gate takes
	# exactly that, so a seeder-replaced DB never fails the load.
	var v2_path = user_path("gate_v2.db")
	FIXTURE.build(v2_path, [])
	var g3 = make_ghost(v2_path, user_path("gate_v2.log"))
	var res3 = g3.db.load_ghosts({
		"player_r": null, "estimated_rank": -1, "db_row_count": 0,
		"player_id": -1, "window": 100,
	})
	eq(res3.get("ok"), true, "format_version=2 accepted")

# 2. Min-d cutoff probe: rows walked oldest-d first; the first metadata the
# parser accepts marks the cutoff, cut to 2 chars, with the 1-based scan count.
func test_probe_min_d() -> void:
	print("[TEST] min-d cutoff probe (first parseable d wins)")
	var db_path = user_path("probe.db")
	FIXTURE.build(db_path, [
		FIXTURE.row(101, 1, "{bad", {"d": "aa"}),
		FIXTURE.row(102, 2, '{"score":9}', {"d": "xyzw"}),
		FIXTURE.row(103, 3, '{"score":1}', {"d": "zz"}),
	])
	var g = make_ghost(db_path, user_path("probe.log"))
	var res = g.db.load_ghosts({
		"player_r": null, "estimated_rank": -1, "db_row_count": 3,
		"window": 10, "player_id": -1,
	})
	eq(res.get("ok"), true, "probe load ok")
	eq(res.get("min_d"), "xy", "min_d is first parseable d cut to 2 chars")
	eq(res.get("scanned"), 2, "scanned counts rows up to the cutoff")
	eq(res.get("parse_ok"), 1, "window parse still counts parseable ghost")

# 3. Opponent window: centered on the rank estimate, lo clamped to 1, the
# player's own steam_id excluded, short metadata rows skipped. Dense rank is
# the row order; the player sits at rank 2.
func test_window() -> void:
	print("[TEST] opponent window (clamp, self exclusion, length filter)")
	var db_path = user_path("window.db")
	FIXTURE.build(db_path, [
		FIXTURE.row(1, 2, '{"score":5,"me":1}', {"r": 5.0}),
		FIXTURE.row(101, 1, "x"),
		FIXTURE.row(102, 3, '{"score":1}'),
		FIXTURE.row(103, 4, '{"score":3}'),
		FIXTURE.row(104, 6, '{"score":6}'),
		FIXTURE.row(105, 7, '{"score":7}'),
	])
	var g = make_ghost(db_path, user_path("window.log"))
	var res = g.db.load_ghosts({
		"player_r": 5.0, "estimated_rank": 5, "db_row_count": 6,
		"window": 2, "player_id": 1,
	})
	eq(res.get("rank"), 5, "cached rank estimate reused when DB unchanged")
	eq(res.get("db_changed"), false, "unchanged row count means no sidecar resave")
	eq(res.get("db_rows"), 6, "live row count reported")
	var scores = []
	for run in res.get("runs"):
		scores.append(int(run["score"]))
	eq(scores, [1, 3], "window clamps lo to 1, skips short metadata, honours limit")
	for run in res.get("runs"):
		ok(not run.has("me"), "player's own steam_id excluded from window")

# 4. Zero-parse fallback: when the primary window parses to zero ghosts, one
# middle-50% retry recovers parseable runs. Two rows share rank field 5: the
# player (steam 1, dense rank 5) and a ghost (dense rank 6).
func test_zero_parse_fallback() -> void:
	print("[TEST] zero-parse fallback (middle-50% retry)")
	var db_path = user_path("fallback.db")
	var rows = [FIXTURE.row(1, 5, '{"score":5,"me":1}', {"r": 5.0})]
	rows.append(FIXTURE.row(101, 1, '{"nope":10}'))
	rows.append(FIXTURE.row(102, 2, '{"nope":20}'))
	for rank in range(3, 12):
		rows.append(FIXTURE.row(100 + rank, rank, '{"score":%d}' % rank))
	FIXTURE.build(db_path, rows)
	var g = make_ghost(db_path, user_path("fallback.log"))
	var res = g.db.load_ghosts({
		"player_r": 5.0, "estimated_rank": 5, "db_row_count": 12,
		"window": 2, "player_id": 1,
	})
	var scores = []
	for run in res.get("runs"):
		scores.append(int(run["score"]))
	eq(scores, [4, 5], "fallback middle-50% window returns parseable ghosts")
	eq(res.get("parse_ok"), 2, "fallback parse count")
	eq(res.get("json_ok"), 4, "json count spans primary and fallback")

# 5. Rank estimate ordering: COUNT(*) + 1 ghosts above the Elo score;
# empty DB estimates -1.
func test_estimate_rank() -> void:
	print("[TEST] rank estimate (ordering, empty DB)")
	var empty_path = user_path("empty.db")
	FIXTURE.build(empty_path, [])
	var ge = make_ghost(empty_path, user_path("empty.log"))
	eq(ge.db.estimate_rank(100.0), -1, "empty DB estimates -1")
	eq(ge.db.row_count(), 0, "empty DB row count is 0")
	var db_path = user_path("estimate.db")
	FIXTURE.build(db_path, [
		FIXTURE.row(201, 1, '{"score":1}', {"r": 1.0}),
		FIXTURE.row(202, 2, '{"score":2}', {"r": 2.0}),
		FIXTURE.row(203, 3, '{"score":3}', {"r": 3.0}),
	])
	var g = make_ghost(db_path, user_path("estimate.log"))
	eq(g.db.row_count(), 3, "row count")
	eq(g.db.estimate_rank(2.0), 2, "one ghost above r=2 -> rank 2")
	eq(g.db.estimate_rank(0.5), 4, "all ghosts above r=0.5 -> rank 4")
	eq(g.db.estimate_rank(3.0), 1, "top ghost -> rank 1")
	eq(g.db.estimate_rank(9.9), 1, "above every ghost -> rank 1")

# 5b. Newest-DB pick: the newest top-level *.gdb in the game folder is the
# loaded Ghost DB (mtime; same-second tie -> lexicographically largest
# name); no candidates falls back to the literal ghosts.gdb path.
func test_pick_db() -> void:
	print("[TEST] newest-db pick (mtime, tie, fallback)")
	var root = user_path("pick_db")

	# No candidates: literal ghosts.gdb fallback, logged once.
	_fresh_dir(root)
	var log_path = user_path("pick.log")
	var blog = BbofLogScript.new()
	blog.open(log_path)
	eq(GhostDbScript.pick_db_path(root, blog), root.plus_file("ghosts.gdb"),
		"no candidates falls back to ghosts.gdb")
	ok(log_text(log_path).find("db_none_found") != -1, "fallback is logged")

	# Newest mtime wins; directories named *.gdb are never candidates;
	# merger-style names are eligible.
	_fresh_dir(root)
	_touch(root.plus_file("ghosts.gdb"))
	Directory.new().make_dir_recursive(root.plus_file("nested.gdb"))
	OS.delay_msec(1100)
	_touch(root.plus_file("ghosts_29_09_26.gdb"))
	eq(GhostDbScript.pick_db_path(root), root.plus_file("ghosts_29_09_26.gdb"),
		"newest mtime wins, *.gdb dirs skipped, merged-style names eligible")

	# Extension match is case-insensitive: .GDB is a candidate.
	_fresh_dir(root)
	_touch(root.plus_file("a.gdb"))
	OS.delay_msec(1100)
	_touch(root.plus_file("B.GDB"))
	eq(GhostDbScript.pick_db_path(root), root.plus_file("B.GDB"),
		".GDB candidate wins on mtime")

	# Same-second tie -> lexicographically largest name. mtime has 1-second
	# resolution, so retry until both fixtures land in the same second.
	_fresh_dir(root)
	var probe = File.new()
	var tied = false
	for attempt in range(6):
		_touch(root.plus_file("b.gdb"))
		_touch(root.plus_file("a.gdb"))
		if int(probe.get_modified_time(root.plus_file("b.gdb"))) \
				== int(probe.get_modified_time(root.plus_file("a.gdb"))):
			tied = true
			break
		_fresh_dir(root)
		OS.delay_msec(1100)
	ok(tied, "tie fixture created (same-second mtimes)")
	eq(GhostDbScript.pick_db_path(root), root.plus_file("b.gdb"),
		"same-second tie -> largest name")

	_rmtree(root)

# 6. Ghost exclusions: an injected filter_fn labels runs to drop. GhostDb
# only forwards runs to the filter — it never reads run fields itself.
func test_filter_exclusions() -> void:
	print("[TEST] filter exclusions (filter_fn drops labeled runs)")
	_fake_filter_kills = {3: "class=Engineer", 5: "class=Engineer"}
	var db_path = user_path("filter.db")
	var rows = []
	for rank in range(1, 7):
		rows.append(FIXTURE.row(100 + rank, rank, '{"score":%d,"id":%d}' % [rank, rank]))
	FIXTURE.build(db_path, rows)
	var g = make_ghost(db_path, user_path("filter.log"))
	var res = g.db.load_ghosts({
		"player_r": 3.0, "estimated_rank": 3, "db_row_count": 6,
		"window": 100, "player_id": 1,
		"filter_fn": funcref(self, "fake_filter"),
	})
	eq(res.get("rank"), 3, "cached rank reused for window centering")
	var ids = []
	for run in res.get("runs"):
		ids.append(int(run["id"]))
	eq(ids, [1, 2, 4, 6], "labeled ids dropped, survivors keep rank order")
	eq(res.get("parse_ok"), 6, "parse counters unaffected by filtering")
	ok(log_text(user_path("filter.log")).find("filter kept=4 filtered=2") != -1,
		"filter log line counts kept and filtered")
	_fake_filter_kills = {}

# 7. Refill: a filter that guts the rank-centered window doubles the
# half-window until it covers the whole DB, deduping runs already kept.
# Widening sweeps only the ring the earlier sweep did not cover (left slab
# then right slab), so the refill parses each row once and the pool keeps
# its dense-rank order: primary survivors, left slab, right slab.
func test_refill() -> void:
	print("[TEST] refill (widened window recovers filter survivors)")
	# Primary window: adjusted rank 1250 +/- 1000 with LIMIT 100 -> dense
	# ranks 250..349; 51 labeled dead leaves kept=49 < threshold=50 and the
	# window [250..2250] does not cover all 2500 rows, so one refill at
	# half=2000 (lo=1, hi=3250) sweeps the ring around 250..349:
	# 2500 - 300 killed = 2200 survivors.
	_fake_filter_kills = {}
	for id in range(299, 350):
		_fake_filter_kills[id] = "class=Engineer"
	for id in range(2201, 2450):
		_fake_filter_kills[id] = "item=Boot"
	var db_path = user_path("refill.db")
	var rows = []
	for rank in range(1, 2501):
		rows.append(FIXTURE.row(100000 + rank, rank, '{"score":%d,"id":%d}' % [rank, rank]))
	FIXTURE.build(db_path, rows)
	var g = make_ghost(db_path, user_path("refill.log"))
	var res = g.db.load_ghosts({
		"player_r": 1250.0, "estimated_rank": 1250, "db_row_count": 2500,
		"window": 100, "player_id": 1,
		"filter_fn": funcref(self, "fake_filter"),
	})
	var uniq = {}
	for run in res.get("runs"):
		uniq[int(run["id"])] = true
	eq(res.get("runs").size(), 2200, "refill recovers every non-excluded ghost")
	eq(uniq.size(), res.get("runs").size(), "refill dedupes: every id unique")
	ok(not uniq.has(299) and not uniq.has(349), "primary-window killed ids absent")
	ok(not uniq.has(2201) and not uniq.has(2449), "far killed ids absent")
	ok(uniq.has(1) and uniq.has(250) and uniq.has(298) and uniq.has(350)
		and uniq.has(2450) and uniq.has(2500),
		"survivors at every refill boundary present")
	var text = log_text(user_path("refill.log"))
	ok(text.find("filter kept=49 filtered=51") != -1, "primary filter line counts the gutted window")
	ok(text.find("refill half=2000 lo=1 hi=3250") != -1, "refill doubles half to cover the whole DB")
	# Slab sweep: only the ring around ranks 250..349 is read, each row once.
	eq(res.get("json_ok"), 2500, "slab refill reads every row exactly once")
	ok(text.find("filter kept=249 filtered=0") != -1, "left slab sweeps ranks 1..249 with no kills")
	ok(text.find("filter kept=1902 filtered=249") != -1, "right slab sweeps ranks 350..2500")
	eq(int(res.get("runs")[0]["id"]), 250, "pool opens with the primary-window survivors")
	eq(int(res.get("runs")[49]["id"]), 1, "left slab follows the primary survivors")
	eq(int(res.get("runs")[298]["id"]), 350, "right slab follows the left slab")
	_fake_filter_kills = {}

# 7b. Exclusion sweep pin: the full golden DB through load_ghosts with no
# exclusions - the byte-identical pool contract of the load rework (slab
# refill, char-wise BitStream, item-fact index), pinned in dense order. The
# golden is v2, so every row also carries its summary record: the class
# histogram, undecodable/perfect counts and highest item index are pinned
# from the committed seeder-written bytes, independent of this reader.
func test_golden_sweep() -> void:
	print("[TEST] golden sweep pin (full-DB survivors, dense order, summaries)")
	var golden_path = ProjectSettings.globalize_path("res://").plus_file("../../seeder/LeaderboardSeeder.Tests/Fixtures/ghosts-fixture-64.gdb")
	if not File.new().file_exists(golden_path):
		# The file is committed; absence is a broken checkout, never a skip.
		ok(false, "golden fixture missing: " + golden_path)
		return
	var g = make_ghost(golden_path, user_path("golden_sweep.log"), funcref(self, "golden_parse"))
	var res = g.db.load_ghosts({
		"player_r": 270.231926, "estimated_rank": 32, "db_row_count": 64,
		"player_id": 1, "window": 64,
	})
	eq(res.get("ok"), true, "golden DB loads")
	eq(res.get("runs").size(), 64, "every dense row survives an empty exclusion set")
	var rs = []
	var carried = 0
	var undecodable = 0
	var perfects = 0
	var max_item = 0
	var hist = {}
	for run in res.get("runs"):
		rs.append(float(run["r"]))
		var summary = run.get("_summary")
		if summary == null:
			continue
		carried += 1
		if summary["undecodable"]:
			undecodable += 1
		if summary["perfect"]:
			perfects += 1
		var cls = int(summary["class"])
		hist[cls] = int(hist.get(cls, 0)) + 1
		for idx in summary["items"]:
			max_item = max(max_item, int(idx))
	eq(rs, [
		342.884159, 266.646171, 270.231926, 273.436809, 361.948541, 251.998941,
		81.898431, 327.265398, 94.382271, 245.192354, 60.118407, 86.044547,
		139.296357, 313.039885, 319.974651, 380.192891, 317.550325, 341.376351,
		324.891486, 350.014367, 415.196835, 333.560974, 292.016733, 342.032064,
		363.434609, 216.618881, 238.330283, 320.539757, 63.789595, 107.313557,
		214.821147, 376.304257, 258.895863, 269.833208, 251.563161, 84.125576,
		277.719591, 338.90359, 328.0738, 289.291717, 402.460818, 330.895099,
		108.219881, 64.545306, 195.081515, 310.929919, 354.818887, 186.101861,
		221.463748, 149.804117, 65.248016, 219.713024, 97.797072, 313.095587,
		108.398895, 82.229489, 294.989475, 147.536184, 223.421581, 185.625563,
		320.540372, 321.386477, 261.259897, 311.297876,
	], "survivor set and dense order pinned")
	eq(carried, 64, "every run carries a summary payload")
	# Pins from the committed seeder-written bytes: every row's header
	# decodes to a class (none classless), three rows have a failed board
	# (undecodable marker, header class kept), no perfect ghost, and the
	# gap-encoded item sets reach the highest descriptor index (519 items).
	var keys = hist.keys()
	keys.sort()
	var parts = []
	for k in keys:
		parts.append("%d=%d" % [k, hist[k]])
	eq(parts, ["0=18", "1=8", "2=14", "3=10", "4=2", "5=6", "6=6"],
		"summary class histogram pinned")
	eq(undecodable, 3, "three rows carry the undecodable marker")
	eq(perfects, 0, "no perfect flag set in the fixture")
	eq(max_item, 518, "gap-encoded item sets reach the highest descriptor index")

# 8. Per-class anchor: switching classes re-estimates the rank from that
# class's r even when the DB is unchanged, so the window centers on the
# current class's rating (db_changed flags the sidecar resave).
func test_class_anchor() -> void:
	print("[TEST] class anchor (switch re-centers window)")
	var db_path = user_path("anchor.db")
	var rows = []
	for rank in range(1, 11):
		rows.append(FIXTURE.row(1000 + rank, rank, '{"score":%d}' % rank, {"r": 11.0 - rank}))
	FIXTURE.build(db_path, rows)
	var g = make_ghost(db_path, user_path("anchor.log"))
	# Sidecar: class 0 uploaded at r=5.0 (rank 6), DB unchanged since.
	var res = g.db.load_ghosts({
		"player_r": 5.0, "estimated_rank": 6, "db_row_count": 10,
		"anchor_class": 0, "current_class": 0,
		"window": 2000, "player_id": 999999,
	})
	eq(res.get("db_changed"), false, "same class and rows reuse cached rank")
	eq(res.get("rank"), 6, "rank 6 for r=5.0")
	# Switch to class 1 (r=9.0): rank re-estimated to 2, resave flagged.
	res = g.db.load_ghosts({
		"player_r": 9.0, "estimated_rank": 6, "db_row_count": 10,
		"anchor_class": 0, "current_class": 1,
		"window": 2000, "player_id": 999999,
	})
	eq(res.get("db_changed"), true, "class switch flags sidecar resave")
	eq(res.get("rank"), 2, "rank re-estimated from the new class r")
	var scores = []
	for run in res.get("runs"):
		scores.append(int(run["score"]))
	eq(scores, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "window centered on rank 2 covers all 10 rows")

# 9. Golden file: the committed seeder-written fixture read through the same
# public seam the game uses, so the GDScript and C# suites enforce the same
# bytes (docs/ghost-db-format.md). Pinned values come from the committed
# file; the fixture is generated from a real dump, never hand-made.
func test_golden_db() -> void:
	print("[TEST] golden fixture (committed seeder DB, cross-language seam)")
	var golden_path = ProjectSettings.globalize_path("res://").plus_file("../../seeder/LeaderboardSeeder.Tests/Fixtures/ghosts-fixture-64.gdb")
	if not File.new().file_exists(golden_path):
		# The file is committed; absence is a broken checkout, never a skip.
		ok(false, "golden fixture missing: " + golden_path)
		return
	var g = make_ghost(golden_path, user_path("golden.log"), funcref(self, "golden_parse"))
	eq(g.db.row_count(), 64, "committed row count is 64")
	eq(g.db.estimate_rank(415.196835), 1, "top r estimates rank 1")
	eq(g.db.estimate_rank(60.118407), 64, "bottom r estimates rank 64")
	eq(g.db.estimate_rank(270.231926), 32, "mid r estimates rank 32")
	# Dense order is leaderboard order, not r order: dense rank 2's r
	# estimates to 34, so the two ranks must never be conflated.
	eq(g.db.estimate_rank(266.646171), 34, "dense rank 2 estimates r-rank 34")
	# Player id 1 is not in the DB (real ids are 17 digits), so no row is
	# excluded and the cached rank is reused.
	var res = g.db.load_ghosts({
		"player_r": 270.231926, "estimated_rank": 32, "db_row_count": 64,
		"player_id": 1, "window": 4,
	})
	eq(res.get("ok"), true, "schema gate passes on seeder bytes")
	eq(res.get("rank"), 32, "cached rank reused on unchanged DB")
	var rs = []
	for run in res.get("runs"):
		rs.append(float(run["r"]))
	eq(rs, [342.884159, 266.646171, 270.231926, 273.436809],
		"window returns the first 4 dense rows in order")
	eq(res.get("json_ok"), 4, "every window blob parses as JSON")
	# The own-steam_id exclusion consumes the file's u64 section: dense
	# rank 3 drops out and the window refills from rank 5.
	res = g.db.load_ghosts({
		"player_r": 270.231926, "estimated_rank": 32, "db_row_count": 64,
		"player_id": 76561199652789041, "window": 4,
	})
	rs = []
	for run in res.get("runs"):
		rs.append(float(run["r"]))
	eq(rs, [342.884159, 266.646171, 273.436809, 361.948541],
		"own steam_id (dense rank 3) excluded from the window")

# Real seeder metadata parses as a ghost iff it carries the r field, like
# the seeder's own write-side gate.
func golden_parse(dict):
	if dict.has("r"):
		return dict
	return null

# --- Board decode (item-data seam) -------------------------------------------

# Encodes a synthetic round exactly the way the game writes boards
# (docs/board-format.md), so the decode tests pin every format constant at
# the public seam: health/stamina range 999, item index width (num_items now,
# 510 legacy), 10x10 inventory cells, the 2-bit per-item field, gem range
# binary_ceil(num_gems + 1) = 64 with empty socket 63, and Magic Ring's
# 12-bit persistence blob (effects 2.0 * 6). specs: [index, x, y, field,
# gems] with gems an Array of gem indexes (empty = hasGems 0).
func encode_round(specs: Array, num_items: int) -> String:
	var w = BitWriterScript.new()
	w.push(123, 999)
	w.push(456, 999)
	for spec in specs:
		var index = int(spec[0])
		w.push(index, num_items)
		w.push(int(spec[1]), 10)
		w.push(int(spec[2]), 10)
		w.push(int(spec[3]), 4)
		var gems: Array = spec[4]
		if index >= 0 and index < _dump["items"].size():
			if _items.getNumSockets(index) > 0:
				if gems.size() > 0:
					w.push(1, 2)
					for gem in gems:
						w.push(int(gem), 64)
				else:
					w.push(0, 2)
			if _items.getDescriptorFromIndex(index).getName() == "Magic Ring":
				w.push_bitsize((1 << 12) - 1, 12)
	# Real boards end with the 6-bit char padding only (< 8 trailing bits,
	# so the reader's item loop stops); pad the same way.
	while w.bits.size() % 6 != 0:
		w.push_bitsize(0, 1)
	return w.to_godot_string()

# decode_item_names is headless-testable since the item facts became a
# parameter (ADR 0002 amendment): production passes the ItemBook global at
# the SteamWorkshop call site, tests pass the dump-backed double fed by the
# committed item_book_dump.json. Pinned dump facts: num_items 519,
# num_gems 34, Wooden Sword index 1 sockets 1, Book of Ice New index 331
# without a scene, Magic Ring index 505 effects 2.0, Superior Ring index
# 506 effects 3.0.
func test_decode_item_names() -> void:
	print("[TEST] board decode (item-data seam, dump-backed)")
	var dec = BoardDecoderScript.new()
	var modern = _items.getNumItems()

	# Happy paths: full round trip through the synthetic encoder.
	eq(dec.decode_item_names(encode_round([[1, 3, 4, 1, [0]]], modern), "1.1.8", _items),
		["Wooden Sword"], "socketed item with one gem decodes to its name")
	eq(dec.decode_item_names(encode_round([[1, 3, 4, 1, [63]]], modern), "1.1.8", _items),
		["Wooden Sword"], "empty-socket gem id (63) accepted")
	eq(dec.decode_item_names(encode_round([[1, 3, 4, 0, []], [0, 1, 2, 2, []]], modern), "1.1.8", _items),
		["Wooden Sword", "Stone"], "hasGems=0 consumes no gem bits")
	# Socket count drives the gem loop width: Rib Saw Blade (index 43) has
	# 3 sockets, so hasGems=1 must consume exactly 3 * 6 gem bits.
	eq(dec.decode_item_names(encode_round([[43, 2, 3, 1, [1, 2, 63]]], modern), "1.1.8", _items),
		["Rib Saw Blade"], "3-socket item consumes a 3-gem block")

	# Magic Ring persists: the reader must consume its 12-bit blob exactly,
	# or the trailing padding would decode as another item.
	eq(dec.decode_item_names(encode_round([[0, 1, 2, 1, []], [505, 3, 4, 2, []]], modern), "1.1.8", _items),
		["Stone", "Magic Ring"], "Magic Ring persistence blob consumed")
	# Superior Ring also carries effects but nothing persists: the next item
	# starts right after the 2-bit field.
	eq(dec.decode_item_names(encode_round([[506, 3, 4, 2, []], [0, 5, 6, 3, []]], modern), "1.1.8", _items),
		["Superior Ring", "Stone"], "Superior Ring consumes no persistence blob")

	# Version gate: 1.1.0 exactly reads modern index widths, older boards
	# 9-bit indexes against the baked legacy count of 510.
	eq(dec.decode_item_names(encode_round([[1, 3, 4, 1, [0]]], modern), "1.1.0", _items),
		["Wooden Sword"], "1.1.0 exactly reads modern item data widths")
	eq(dec.decode_item_names(encode_round([[1, 3, 4, 1, [0]]], 510), "1.0.9", _items),
		["Wooden Sword"], "pre-1.1.0 boards read 9-bit legacy indexes")

	# Failure modes: every one is null, never an error.
	eq(dec.decode_item_names(encode_round([[331, 1, 1, 1, []]], modern), "1.1.8", _items),
		null, "index without a scene returns null")
	eq(dec.decode_item_names(encode_round([[modern, 1, 1, 1, []]], modern), "1.1.8", _items),
		null, "index >= num_items returns null")
	eq(dec.decode_item_names(encode_round([[1, 1, 1, 1, [34]]], modern), "1.1.8", _items),
		null, "gem index beyond num_gems returns null")
	var trunc = BitWriterScript.new()
	trunc.push(123, 999)
	trunc.push(456, 999)
	trunc.push_bitsize(0, 8)
	eq(dec.decode_item_names(trunc.to_godot_string(), "1.1.8", _items),
		null, "stream dying mid-item returns null")
	eq(dec.decode_item_names("~", "1.1.8", _items),
		null, "non-6-bit character returns null")

	# A null descriptor at an in-range index (production ItemBook can leave
	# descriptorList holes) is null, never an error - distinguishable from a
	# valid decode of the very same stream.
	eq(dec.decode_item_names(encode_round([[3, 1, 1, 1, []]], modern), "1.1.8", _items),
		["Broom"], "same stream decodes when the descriptor exists")
	var hole = DumpItemDataScript.new(_dump)
	hole._null_index = 3
	eq(dec.decode_item_names(encode_round([[3, 1, 1, 1, []]], modern), "1.1.8", hole),
		null, "null descriptor at an in-range index returns null")

# Decoding the committed golden DB through the real seam: every decoded
# name must exist in the item data (the decoder cannot invent names), and
# the bulk of rounds must decode (ADR 0002: ~98%, game-parity ceiling).
func test_decode_golden_smoke() -> void:
	print("[TEST] board decode smoke (golden DB x item dump)")
	var golden_path = ProjectSettings.globalize_path("res://").plus_file("../../seeder/LeaderboardSeeder.Tests/Fixtures/ghosts-fixture-64.gdb")
	if not File.new().file_exists(golden_path):
		# The file is committed; absence is a broken checkout, never a skip.
		ok(false, "golden fixture missing: " + golden_path)
		return
	var g = make_ghost(golden_path, user_path("golden_decode.log"), funcref(self, "golden_parse"))
	var res = g.db.load_ghosts({
		"player_r": 270.231926, "estimated_rank": 32, "db_row_count": 64,
		"player_id": 1, "window": 64,
	})
	eq(res.get("ok"), true, "golden DB loads for decode smoke")
	var known = {}
	for row in _dump["items"]:
		if row["name"] != null:
			known[row["name"]] = true
	var rounds = 0
	var decoded = 0
	var names = 0
	for run in res.get("runs"):
		for day in range(18):
			if not run.has(str(day)):
				continue
			rounds += 1
			var decoded_names = _decoder.decode_item_names(str(run[str(day)]), "1.1.8", _items)
			if decoded_names == null:
				continue
			decoded += 1
			names += decoded_names.size()
			for iname in decoded_names:
				if not known.has(iname):
					ok(false, "decoded name not in the item data: " + str(iname))
	ok(rounds > 0, "golden blobs carry day boards (rounds=%d)" % rounds)
	ok(decoded > 0, "at least one golden round decodes headless")
	ok(decoded * 5 >= rounds * 4, "at least 80%% of rounds decode (%d of %d)" % [decoded, rounds])
	ok(names > 0, "decodes yield item names (%d total)" % names)

# The adapter validates every exclude_items name against the ItemBook item data
# at load: unknown names warn (typos in ghost_filter.json must surface in
# bbof.log) but never block the download. Runs the real SteamWorkshop
# script; the test project's ItemBook autoload stub carries the known names.
func test_filter_unknown_item_warn() -> void:
	print("[TEST] filter unknown-item warn (load-time, non-blocking)")
	var sw = SteamWorkshopScript.new()
	var log_path = user_path("filter_warn.log")
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	# Same script resource as SteamWorkshop's own preload, or the typed
	# `var _log: BbofLog` rejects the instance.
	var blog = load("res://Core/BbofLog.gd").new()
	blog.open(log_path)
	sw._log = blog
	var filter_path = user_path("filter_warn.json")
	var f = File.new()
	f.open(filter_path, File.WRITE)
	f.store_line(to_json({"exclude_items": ["Wooden Sword", "Not An Item"]}))
	f.close()
	sw._filter_path = filter_path
	sw._load_filter()
	blog.close()
	eq(sw._excl_items, ["Wooden Sword", "Not An Item"], "warn never blocks: exclusions still load")
	var text = log_text(log_path)
	ok(text.find("filter_unknown_item name=Not An Item") != -1, "unknown item name warns")
	ok(text.find("filter_unknown_item name=Wooden Sword") == -1, "known item name stays silent")
	sw.free()

# exclude_perfect: default on (absent file or key), boolean opt-out, and a
# non-bool value disables the whole filter — same one-warn convention as the
# string lists. _filter_run reads the summary record: the seeder precomputed
# the perfect flag from the header results, so a classless undecodable run
# (missing/short header) cannot match and stays.
func test_filter_perfect_flag() -> void:
	print("[TEST] filter exclude_perfect (default on, opt-out, malformation)")
	var perfect = {"_summary": {"class": 0, "perfect": true, "undecodable": false, "items": []}}
	var beaten = {"_summary": {"class": 0, "perfect": false, "undecodable": false, "items": []}}
	var classless = {"_summary": {"class": 255, "perfect": false, "undecodable": true, "items": []}}

	var sw = SteamWorkshopScript.new()
	var log_path = user_path("filter_perfect.log")
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	# Same script resource as SteamWorkshop's own preload, or the typed
	# `var _log: BbofLog` rejects the instance.
	var blog = load("res://Core/BbofLog.gd").new()
	blog.open(log_path)
	sw._log = blog
	sw._filter_path = user_path("filter_perfect_absent.json")
	# Prior runs leave the file behind; the absent-file case must be real.
	if dir.file_exists(sw._filter_path):
		dir.remove(sw._filter_path)
	sw._load_filter()
	eq(sw._exclude_perfect, true, "missing file keeps default on")
	eq(sw._filter_run(perfect), "perfect", "perfect-flagged ghost drops by default")
	eq(sw._filter_run(beaten), "", "beaten ghost stays")
	eq(sw._filter_run(classless), "", "classless undecodable ghost stays (cannot match)")

	var f = File.new()
	f.open(sw._filter_path, File.WRITE)
	f.store_line(to_json({"exclude_perfect": false}))
	f.close()
	sw._load_filter()
	eq(sw._exclude_perfect, false, "explicit false wins over the default")
	eq(sw._filter_run(perfect), "", "opted-out perfect ghost stays")

	f.open(sw._filter_path, File.WRITE)
	f.store_line(to_json({"exclude_classes": ["Engineer"], "exclude_perfect": "yes"}))
	f.close()
	sw._load_filter()
	eq(sw._exclude_perfect, false, "non-bool flag disables the filter")
	eq(sw._excl_classes, [], "non-bool flag disables the lists too")
	eq(sw._filter_run(perfect), "", "disabled filter keeps the perfect ghost")
	blog.close()
	var text = log_text(log_path)
	ok(text.find("filter_malformed") != -1, "non-bool flag warns")
	ok(text.find("filter loaded classes=0 items=0 perfect=False") != -1, "load line logs the flag")
	sw.free()

# Test double parked over sw._decoder: counts decode_item_names calls (must
# stay 0 in a v2 sweep — the summary replaces board decode) and delegates
# the summary accessor to the real decoder so the item rule resolves live.
class SpyDecoder:
	var decode_calls: int = 0
	var real

	func decode_item_names(_round_string, _entry_version, _item_data):
		decode_calls += 1
		return null

	func item_names_for_indexes(indexes, item_data):
		return real.item_names_for_indexes(indexes, item_data)

# v2 exclusion sweep: with a summary on every run, the real _filter_run
# decides every rule from it — class from the summary class (255 classless
# skips), perfect from the flag, items resolved live from descriptor indexes
# through the facts accessor — and never decodes a board. An undecodable
# marker keeps the run unless another rule's fields match.
func test_filter_summary_v2() -> void:
	print("[TEST] v2 summary sweep (class/perfect/item rules, zero decode)")
	var db_path = user_path("summary_v2.db")
	var rows = []
	for rank in range(1, 13):
		rows.append(FIXTURE.row(100 + rank, rank, '{"score":%d,"id":%d}' % [rank, rank], {
			"r": float(rank),
			"summary": {
				1: {"class": 2, "perfect": false, "undecodable": false, "items": []},
				2: {"class": 0, "perfect": true, "undecodable": false, "items": []},
				3: {"class": 0, "perfect": false, "undecodable": false, "items": [390]},
				4: {"class": 0, "perfect": false, "undecodable": true, "items": []},
				5: {"class": 255, "perfect": false, "undecodable": false, "items": []},
				6: {"class": 0, "perfect": false, "undecodable": false, "items": [390, 505]},
			}.get(rank),
		}))
	FIXTURE.build(db_path, rows)

	# Real adapter, real decoder behind the spy, stubbed ItemBook global.
	var sw = SteamWorkshopScript.new()
	var log_path = user_path("summary_v2.log")
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	# Same script resource as SteamWorkshop's own preload, or the typed
	# `var _log: BbofLog` rejects the instance.
	var blog = load("res://Core/BbofLog.gd").new()
	blog.open(log_path)
	sw._log = blog
	var filter_path = user_path("summary_v2_filter.json")
	var f = File.new()
	f.open(filter_path, File.WRITE)
	f.store_line(to_json({"exclude_classes": ["Engineer"], "exclude_items": ["False Life"], "exclude_perfect": true}))
	f.close()
	sw._filter_path = filter_path
	sw._load_filter()
	var spy = SpyDecoder.new()
	spy.real = BoardDecoderScript.new()
	sw._decoder = spy

	var g = make_ghost(db_path, log_path)
	var res = g.db.load_ghosts({
		"player_r": 6.5, "estimated_rank": 7, "db_row_count": 12,
		"window": 100, "player_id": 999999,
		"filter_fn": funcref(sw, "_filter_run"),
	})
	var ids = []
	for run in res.get("runs"):
		ids.append(int(run["id"]))
	eq(ids, [4, 5, 7, 8, 9, 10, 11, 12],
		"summary rules kill class/perfect/item runs, keep classless and undecodable")
	ok(log_text(log_path).find("filter kept=8 filtered=4") != -1,
		"filter line counts the summary-driven kills")
	eq(spy.decode_calls, 0, "v2 sweep never calls decode_item_names")

	# The accessor skips out-of-range and descriptor-less indexes: cannot
	# match = keep, mirroring a null decode round.
	eq(spy.real.item_names_for_indexes([0, 331, 519, 390], _items),
		["Stone", "False Life"], "accessor resolves valid indexes, skips invalid")

	blog.close()
	sw.free()

# --- BitStream port ----------------------------------------------------------

# The port is pure math, so it is unit-testable headless - like the board
# decoder since decode_item_names took the item-data parameter (ADR 0002).
# "^A" encodes bits [1,0,0,0,0,0, 0,0,0,0,1,1] via 6-bit-per-char, offset 62.
func test_bitstream_port() -> void:
	var bs = BitStreamScript.new()
	ok(bs.from_godot_string("^A"), "6-bit chars decode")
	eq(bs.pull(999), 512, "pull consumes ceil(log2(n)) bits MSB-first")
	eq(bs.bits_left(), 2, "10 of 12 bits consumed")
	eq(bs.pull(1), 0, "rangeMax 1 consumes no bits")
	eq(bs.pull(4), 3, "remaining bits pull as 2-bit value 3")
	eq(bs.bits_left(), 0, "stream exhausted")
	eq(bs.pull(2), -1, "dry stream returns -1")
	var fresh = BitStreamScript.new()
	eq(fresh.pull(1), 0, "rangeMax 1 safe on empty stream")
	eq(fresh.pull(999), -1, "dry pull of wide field returns -1")
	ok(not BitStreamScript.new().from_godot_string("~"), "offset 64 rejected")
	ok(not BitStreamScript.new().from_godot_string("!"), "offset below 0 rejected")

# The char-wise reader must stay byte-identical to the per-bit math it
# replaced: same bits in, same values out, same cursor states. The reference
# re-implements the original per-bit reader over the BitWriter's public bits
# array; 60 seeded pseudo-random streams cover char boundaries, partial
# fields and dry pulls.
func test_bitstream_reference() -> void:
	var rng = RandomNumberGenerator.new()
	rng.set_seed(20261008)
	var mismatches = 0
	var pulls = 0
	for iter in range(60):
		var w = BitWriterScript.new()
		var n = rng.randi_range(24, 600)
		for i in range(n):
			w.bits.push_back(rng.randi_range(0, 1))
		var bs = BitStreamScript.new()
		if not bs.from_godot_string(w.to_godot_string()):
			mismatches += 1
			continue
		# The reader sees the string's zero padding to a 6-bit char multiple;
		# the reference must consume the same padded stream.
		var pad = w.bits.duplicate()
		while pad.size() % 6 != 0:
			pad.push_back(0)
		var ref = {"pos": 0}
		while true:
			# Board-decode-shaped schedule: wide fields, cell pairs, the
			# 2-bit field, gem range, a no-op pull and a raw bitsize pull.
			for width in [999, 999, 519, 10, 10, 4, 2, 64, 1, -7]:
				var got = bs.pull_bitsize(7) if width == -7 else bs.pull(width)
				var want = _ref_pull_bits(pad, 7, ref) if width == -7 \
						else (0 if width <= 1 else _ref_pull_bits(pad, int(ceil(log(width) / log(2))), ref))
				pulls += 1
				if got != want:
					mismatches += 1
			if bs.bits_left() < 8:
				break
		if bs.bits_left() != pad.size() - int(ref["pos"]):
			mismatches += 1
	eq(mismatches, 0, "char-wise reader matches the per-bit reference (%d pulls)" % pulls)

# Original per-bit pull semantics: exactly num_bits consumed MSB first, -1
# with the cursor stopped at the first missing bit. Callers mirror pull()'s
# rangeMax gate and width formula.
func _ref_pull_bits(bits: Array, num_bits: int, state: Dictionary) -> int:
	var value = 0
	for digit in range(num_bits - 1, -1, -1):
		if int(state["pos"]) == bits.size():
			return -1
		var bit = int(bits[int(state["pos"])])
		value = value + (bit << digit)
		state["pos"] = int(state["pos"]) + 1
	return value

# 10. Push anchor: a ranked upload must move the class anchor even though
# pushed metadata never carries ugc — the adapter injects it before the
# game's parser, same as GhostDb and the legacy-state migration do. Without
# the injection every push parses classless and no anchor ever moves.
func test_push_anchor() -> void:
	print("[TEST] push anchor (ugc-less pushed metadata still moves the anchor)")
	var db_path = user_path("push_anchor.db")
	var rows = []
	for rank in range(1, 4):
		rows.append(FIXTURE.row(1000 + rank, rank, '{"score":%d}' % rank, {"r": 11.0 - rank}))
	FIXTURE.build(db_path, rows)
	var sw = SteamWorkshopScript.new()
	var log_path = user_path("push_anchor.log")
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	# Same script resource as SteamWorkshop's own preload, or the typed
	# `var _log: BbofLog` rejects the instance.
	var blog = load("res://Core/BbofLog.gd").new()
	blog.open(log_path)
	sw._log = blog
	sw._db_path = db_path
	sw._ghost = GhostDbScript.new()
	sw._ghost.setup(db_path, blog, funcref(sw, "_parse_single"))
	var state_path = user_path("push_anchor_state.json")
	if dir.file_exists(state_path):
		dir.remove(state_path)
	sw._state_path = state_path
	# Pushed metadata carries r/p/d but never ugc. Class 0's anchor must
	# move to r=8.5: two ghosts rank above it (r=10.0, r=9.0), so rank 3.
	sw.pushScore('{"r":8.5,"p":"tester","d":"ODxx"}', 1)
	eq(sw._player_state.get("r_by_class", {}).get("0", null), 8.5, "push writes the class anchor")
	eq(int(sw._player_state.get("estimated_rank", -1)), 3, "push re-estimates the rank")
	eq(int(sw._player_state.get("anchor_class", -1)), 0, "push pins the anchor class")
	var text = log_text(log_path)
	ok(text.find("push no_class") == -1, "no no_class warn")
	ok(text.find("push db_ok rows=3 rank=3 class=0") != -1, "anchor log line present")
	# Sidecar persisted for the next session's window centering.
	var f = File.new()
	var saved = {}
	if f.file_exists(state_path) and f.open(state_path, File.READ) == OK:
		var p = JSON.parse(f.get_as_text())
		f.close()
		if p.error == OK and typeof(p.result) == TYPE_DICTIONARY:
			saved = p.result
	eq(saved.get("r_by_class", {}).get("0", null), 8.5, "anchor persisted to player_state.json")
	blog.close()
	sw.free()
