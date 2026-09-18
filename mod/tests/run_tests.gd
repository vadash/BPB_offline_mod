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

var checks: int = 0
var failures: int = 0

# Kills map driving fake_filter: id -> rule label the filter returns.
var _fake_filter_kills: Dictionary = {}

func _initialize() -> void:
	GhostDbScript = _core_script("GhostDb.gd")
	BbofLogScript = _core_script("BbofLog.gd")
	BitStreamScript = _core_script("BitStream.gd")
	if GhostDbScript == null or BbofLogScript == null or BitStreamScript == null:
		print("")
		print("checks=%d failures=%d" % [checks, failures])
		quit(1)
		return
	test_schema_gate()
	test_probe_min_d()
	test_window()
	test_zero_parse_fallback()
	test_estimate_rank()
	test_tier_offset()
	test_filter_exclusions()
	test_refill()
	test_bitstream_port()
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

func make_ghost(db_path: String, log_path: String) -> Dictionary:
	var dir = Directory.new()
	if dir.file_exists(log_path):
		dir.remove(log_path)
	var blog = BbofLogScript.new()
	blog.open(log_path)
	var gdb = GhostDbScript.new()
	gdb.setup(db_path, blog, funcref(self, "fake_parse"))
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

# --- tests ------------------------------------------------------------------

# 1. Schema gate: a BGDB file whose format_version does not match is rejected
# with the old fail_load string; an unreadable header gates as "unknown".
func test_schema_gate() -> void:
	print("[TEST] schema gate (format_version mismatch, garbage header)")
	var db_path = user_path("gate.db")
	FIXTURE.build(db_path, 0, [])
	var g = make_ghost(db_path, user_path("gate.log"))
	var res = g.db.load_ghosts({
		"player_r": null,
		"estimated_rank": -1,
		"db_row_count": 0,
		"player_id": 0,
		"window": 100,
	})
	eq(res.get("ok", "(missing)"), false, "format_version=0 rejected: ok=false")
	eq(res.get("reason", "(missing)"), "db_schema_version ver=0 expected=1",
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
	eq(res2.get("reason", "(missing)"), "db_schema_version ver=unknown expected=1",
		"header too short reports ver=unknown")

# 2. Min-d cutoff probe: rows walked oldest-d first; the first metadata the
# parser accepts marks the cutoff, cut to 2 chars, with the 1-based scan count.
func test_probe_min_d() -> void:
	print("[TEST] min-d cutoff probe (first parseable d wins)")
	var db_path = user_path("probe.db")
	FIXTURE.build(db_path, 1, [
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
	FIXTURE.build(db_path, 1, [
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
	FIXTURE.build(db_path, 1, rows)
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
	FIXTURE.build(empty_path, 1, [])
	var ge = make_ghost(empty_path, user_path("empty.log"))
	eq(ge.db.estimate_rank(100.0), -1, "empty DB estimates -1")
	eq(ge.db.row_count(), 0, "empty DB row count is 0")
	var db_path = user_path("estimate.db")
	FIXTURE.build(db_path, 1, [
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

# 6. Tier offset: the Grandma tier shifts the adjusted rank down 25%, moving
# the opponent window's hi edge with it (100 -> 75, hi 1100 -> 1075). Dense
# ranks 1076/1077 sit beyond the shifted edge.
func test_tier_offset() -> void:
	print("[TEST] tier offset (Grandma shifts window hi edge)")
	var db_path = user_path("tier.db")
	var rows = [FIXTURE.row(1, 100, '{"score":100,"me":1}', {"r": 100.0})]
	for rank in range(1, 1078):
		if rank == 100:
			continue
		rows.append(FIXTURE.row(1000 + rank, rank, '{"score":%d}' % rank))
	FIXTURE.build(db_path, 1, rows)
	var g = make_ghost(db_path, user_path("tier.log"))
	var res = g.db.load_ghosts({
		"player_r": 100.0, "estimated_rank": 100, "db_row_count": 1077,
		"window": 2000, "player_id": 1,
	})
	eq(res.get("rank"), 100, "cached rank reused")
	eq(res.get("db_rows"), 1077, "row count")
	var scores = {}
	for run in res.get("runs"):
		scores[int(run["score"])] = true
	ok(scores.has(1074), "rank 1074 inside shifted hi edge (75+1000=1075)")
	ok(not scores.has(1076), "rank 1076 beyond shifted hi edge")
	ok(not scores.has(100), "player excluded from own window")
	eq(res.get("runs").size(), 1074, "every other ghost in the window")

# 7. Ghost exclusions: an injected filter_fn labels runs to drop. GhostDb
# only forwards runs to the filter — it never reads run fields itself.
func test_filter_exclusions() -> void:
	print("[TEST] filter exclusions (filter_fn drops labeled runs)")
	_fake_filter_kills = {3: "class=Engineer", 5: "class=Engineer"}
	var db_path = user_path("filter.db")
	var rows = []
	for rank in range(1, 7):
		rows.append(FIXTURE.row(100 + rank, rank, '{"score":%d,"id":%d}' % [rank, rank]))
	FIXTURE.build(db_path, 1, rows)
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

# 8. Refill: a filter that guts the rank-centered window doubles the
# half-window until it covers the whole DB, deduping runs already kept.
func test_refill() -> void:
	print("[TEST] refill (widened window recovers filter survivors)")
	# Primary window: adjusted rank 1250 +/- 1000 with LIMIT 100 -> dense
	# ranks 250..349; 51 labeled dead leaves kept=49 < threshold=50 and the
	# window [250..2250] does not cover all 2500 rows, so one refill at
	# half=2000 (lo=1, hi=3250, LIMIT 3250) re-reads the whole DB:
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
	FIXTURE.build(db_path, 1, rows)
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
	_fake_filter_kills = {}

# --- BitStream port ----------------------------------------------------------

# The port is pure math, so it is unit-testable headless (unlike the decode
# family, which only runs inside the game - ADR 0002). "^A" encodes bits
# [1,0,0,0,0,0, 0,0,0,0,1,1] via 6-bit-per-char, offset 62.
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
