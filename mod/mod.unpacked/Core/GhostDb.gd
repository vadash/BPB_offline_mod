extends Reference

# ---------------------------------------------------------------------------
# GhostDb — deep module owning every ghost-DB read: schema gate, min-d cutoff
# probe, rank estimate, opponent window, and metadata parsing.
# Knows nothing about the game: the score parser is injected as a FuncRef by
# the adapter (wrapping RunDatabase.parseSingleScore). Reads the seeder's
# BGDB v2 file (docs/ghost-db-format.md) with plain File seek/read only. The
# header + dense-rank arrays are cached lazily per instance (the adapter
# holds one GhostDb for the session); the cache reloads when the file's
# mtime changes, so a seeder-replaced DB is picked up mid-session. Which
# file is loaded is pick_db_path's decision: the newest top-level *.gdb in
# the game folder, resolved once at startup. Metadata
# blobs are always read on demand, never cached. Vocabulary: a "ghost" is
# one parsed opponent run; the "opponent window" is the rank range ghosts
# are drawn from; the "min-d cutoff" is the oldest ghost version the live
# game still accepts.
# ---------------------------------------------------------------------------

const MAGIC = "BGDB"
# The seeder writes v2: the base layout plus per-row exclusion summaries
# after the dense-rank arrays. v1 DBs fail the gate (clean cutover); the
# gate-fail string reports this version as the expected one.
const FORMAT_VERSION = 2

# Probe cap: runs examined oldest-d first before giving up (the old SQL
# LIMIT 200 on the probe query).
const PROBE_SCAN_LIMIT = 200

# Literal fallback DB name for the newest-DB pick (pick_db_path).
const FALLBACK_DB_NAME = "ghosts.gdb"

# Newest-DB pick: the newest top-level *.gdb in dir is the Ghost DB the
# adapter loads (mtime; same-second tie -> lexicographically largest name,
# so date-suffixed names sort the newer date last). Directories named *.gdb
# never qualify; the extension matches case-insensitively. No candidates ->
# the literal ghosts.gdb path, so the miss surfaces as the usual
# db_open_fail. Resolved once at startup; a same-path replacement is still
# picked up mid-session by _refresh_cache. logger (optional) gets one info
# line when the pick falls back.
static func pick_db_path(dir: String, logger = null) -> String:
	var best_name: String = ""
	var best_mtime: int = -1
	var d = Directory.new()
	if d.open(dir) == OK:
		d.list_dir_begin(true)
		var name = d.get_next()
		while name != "":
			if not d.current_is_dir() and name.to_lower().ends_with(".gdb"):
				# get_modified_time returns 0 on error: oldest, but still
				# eligible inside an all-0 tie.
				var mtime = int(File.new().get_modified_time(dir.plus_file(name)))
				if mtime > best_mtime or (mtime == best_mtime and name > best_name):
					best_name = name
					best_mtime = mtime
			name = d.get_next()
		d.list_dir_end()
	if best_name == "":
		if logger != null:
			logger.info("db_none_found dir=%s fallback=%s" % [dir, FALLBACK_DB_NAME])
		return dir.plus_file(FALLBACK_DB_NAME)
	return dir.plus_file(best_name)

var _db_path: String
var _log
var _parse_fn: FuncRef

# Lazy cache of the file's immutable prefix (docs/ghost-db-format.md). A
# gate-failed or unreadable file stays uncached, so a later good write is
# always picked up; a gate-ok cache invalidates on mtime change.
var _loaded: bool = false
var _gate_ok: bool = false
var _ver: String = "unknown"
var _mtime: int = 0
var _flen: int = 0
var _n: int = 0
var _version_codes: PoolStringArray = PoolStringArray()
var _steam_ids: Array = []       # GDScript ints (u64 from file), rank-ordered
var _blob_offsets: Array = []    # GDScript ints (u64 file offsets), exact
var _d_codes: PoolByteArray = PoolByteArray()        # u8[N], version-table idx
var _d_order: PoolIntArray = PoolIntArray()          # u32[N], (d, index) order
var _r_values: Array = []        # GDScript floats (file f64), descending
var _summary_offsets: Array = [] # v2: u64 file offsets, row i = rank i+1


func setup(db_path: String, logger, parse_fn) -> void:
	_db_path = db_path
	_log = logger
	_parse_fn = parse_fn


# Milliseconds elapsed since a OS.get_ticks_usec() timestamp.
func _ms_since(t0: int) -> int:
	return int((OS.get_ticks_usec() - t0) / 1000.0)


# Read ghosts around the player for one download. state:
#   player_r (cached Elo or null), estimated_rank, db_row_count (cached
#   sidecar value), window (opponent window row limit), player_id (steam id,
#   -1 when unknown), cached_min_d (sidecar min_d for the no-parse warn),
#   filter_fn (optional FuncRef: "" keeps a run, any other return is the
#   rule label that kills it).
# Returns: ok/reason, runs (parser results), rank, db_rows, db_changed,
# json_ok/parse_ok counts, min_d/scanned from the cutoff probe.
# ok=false carries the old fail_load string: db_open_fail, db_schema_version.
func load_ghosts(state: Dictionary) -> Dictionary:
	var out = {
		"ok": false, "reason": "", "runs": [], "rank": -1, "db_rows": 0,
		"db_changed": false, "json_ok": 0, "parse_ok": 0,
		"min_d": "", "scanned": 0,
	}
	# Schema gate — only accept a DB built by the current seeder. No log
	# here: reason carries the old fail_load string so the adapter's single
	# warn matches the previous log byte for byte.
	var gate = _refresh_cache()
	if gate == "open_fail":
		out["reason"] = "db_open_fail"
		return out
	if gate == "schema":
		out["reason"] = "db_schema_version ver=%s expected=%d" % [_ver, FORMAT_VERSION]
		return out
	out["ok"] = true

	# Detect the game's live minimum ghost version before windowing.
	_probe_min_d(out, state)

	# Determine player rank for opponent window centering. Re-estimate iff
	# the live row count differs from the cached one (DB was replaced) or
	# the anchor class changed: each class anchors its own r, so a class
	# switch must recenter even on an unchanged DB.
	var player_rank = -1
	if state["player_id"] != -1:
		var cached_r = state["player_r"]
		var cached_rows = int(state["db_row_count"])
		var anchor_class = int(state.get("anchor_class", -1))
		var current_class = int(state.get("current_class", anchor_class))

		out["db_rows"] = _n

		if cached_r != null:
			var rows_changed = out["db_rows"] != cached_rows
			var class_changed = current_class != anchor_class
			if rows_changed:
				_log.info("db_changed old_rows=%d new_rows=%d re-estimating rank from r=%s" % [cached_rows, out["db_rows"], str(cached_r)])
			elif class_changed:
				_log.info("class_changed anchor=%d current=%d re-estimating rank from r=%s" % [anchor_class, current_class, str(cached_r)])
			if rows_changed or class_changed:
				out["db_changed"] = true
				player_rank = _estimate_rank(float(cached_r))
				if player_rank >= 0:
					_log.info("re_estimate rank=%d" % player_rank)
				else:
					player_rank = int(state["estimated_rank"])
					_log.warn("re_estimate_no_rows fallback cached_rank=%d" % player_rank)
			else:
				player_rank = int(state["estimated_rank"])
				_log.info("db_unchanged rows=%d cached_rank=%d" % [out["db_rows"], player_rank])
		else:
			_log.info("no_cached_r rank window will use global fallback")
	out["rank"] = player_rank

	# Read runs around the player's rank.
	# Ghost exclusions: the adapter may inject a filter that labels runs to
	# drop. GhostDb only forwards runs to it — game fields stay unread here.
	var filter_fn = state.get("filter_fn", null)
	var io_ms = 0
	var parse_ms = 0
	var filter_ms = 0
	var t0 = OS.get_ticks_usec()
	var swept = _query_runs(player_rank, state["player_id"], state["window"])
	io_ms += _ms_since(t0)
	var rows: Array = swept["rows"]
	var raw_rows = rows.size()
	_log.info("query_rows=%d" % raw_rows)
	var totals = _parse_rows(rows, swept.get("summaries"))
	parse_ms += int(totals["ms"])
	out["runs"] = totals["runs"]
	out["json_ok"] = totals["json_ok"]
	out["parse_ok"] = totals["parse_ok"]
	if filter_fn != null:
		t0 = OS.get_ticks_usec()
		out["runs"] = _apply_filter(out["runs"], filter_fn)
		filter_ms += _ms_since(t0)
	if out["parse_ok"] == 0 and raw_rows > 0:
		_log.warn("parse_zero primary window yielded no parseable runs, retrying with middle-50% window")
		var total_rows = out["db_rows"] if out["db_rows"] > 0 else _n
		var lo_rank = int(total_rows * 0.25) + 1
		var hi_rank = int(total_rows * 0.75)
		t0 = OS.get_ticks_usec()
		var fb = _window_rows(lo_rank, hi_rank, state["player_id"], state["window"])
		io_ms += _ms_since(t0)
		if fb["hi"] >= fb["lo"]:
			swept = fb
		var fb_parsed = _parse_rows(fb["rows"], fb.get("summaries"))
		parse_ms += int(fb_parsed["ms"])
		out["runs"] += fb_parsed["runs"]
		out["json_ok"] += fb_parsed["json_ok"]
		out["parse_ok"] += fb_parsed["parse_ok"]
		_log.info("fallback rows=%d parse_ok=%d" % [fb["rows"].size(), fb_parsed["parse_ok"]])
		if filter_fn != null:
			t0 = OS.get_ticks_usec()
			out["runs"] = _apply_filter(out["runs"], filter_fn)
			filter_ms += _ms_since(t0)

	# A filter that gutted the rank-centered window widens it: double the
	# half-window until it covers the whole DB so exclusions cannot starve
	# the match. The no-rank middle-50% fallback window is never refilled.
	# Widening reads only the ring the earlier sweep did not cover (left slab
	# then right slab, ascending, so the pool keeps its dense-rank order) —
	# re-reading the swept range would make strict filters cost O(N).
	if filter_fn != null and player_rank > 0:
		var threshold = int(state["window"] / 2)
		var bounds = _window_bounds(player_rank)
		var seen = {}
		for run in out["runs"]:
			var rid = _run_key(run)
			if rid != null:
				seen[rid] = true
		var half = 1000
		while out["runs"].size() < threshold and not (bounds["lo"] <= 1 and bounds["hi"] >= out["db_rows"]):
			half *= 2
			var lo = max(1, player_rank - half)
			var hi = player_rank + half
			var ring_ms = 0
			for side in [[lo, int(swept["lo"]) - 1], [int(swept["hi"]) + 1, hi]]:
				var side_lo: int = max(1, side[0])
				var side_hi: int = min(hi, side[1])
				if side_lo > side_hi:
					continue
				t0 = OS.get_ticks_usec()
				var rp_rows = _window_rows(side_lo, side_hi, state["player_id"], side_hi - side_lo + 1)
				var side_io = _ms_since(t0)
				io_ms += side_io
				var rp = _parse_rows(rp_rows["rows"], rp_rows.get("summaries"))
				parse_ms += int(rp["ms"])
				ring_ms += side_io + int(rp["ms"])
				out["json_ok"] += rp["json_ok"]
				out["parse_ok"] += rp["parse_ok"]
				t0 = OS.get_ticks_usec()
				var refill = _apply_filter(rp["runs"], filter_fn)
				var side_filter = _ms_since(t0)
				filter_ms += side_filter
				ring_ms += side_filter
				for run in refill:
					var rid = _run_key(run)
					if rid != null:
						if seen.has(rid):
							continue
						seen[rid] = true
					out["runs"].push_back(run)
			bounds["lo"] = lo
			bounds["hi"] = hi
			swept = {"lo": lo, "hi": hi}
			_log.info("refill half=%d lo=%d hi=%d kept=%d ms=%d" % [half, lo, hi, out["runs"].size(), ring_ms])

	_log.info("load db_rows=%d rank=%d runs=%d json_ok=%d parse_ok=%d io_ms=%d parse_ms=%d filter_ms=%d" % [out["db_rows"], player_rank, out["runs"].size(), out["json_ok"], out["parse_ok"], io_ms, parse_ms, filter_ms])
	return out


# Dedupe key for refill: test doubles carry "id", game RunData objects keep
# the metadata id in playerId (their runId is the UGC handle, always 1 in
# this mod, so it cannot dedupe). Missing key = run always kept.
func _run_key(run):
	var rid = run.get("id")
	if rid == null:
		rid = run.get("playerId")
	return rid


# Rank of an Elo score: COUNT(*) + 1 ghosts above it. -1 when the DB is
# empty, cannot be opened, or fails the schema gate.
func estimate_rank(r: float) -> int:
	if _refresh_cache() != "ok":
		return -1
	if _n == 0:
		return -1
	return _estimate_rank(r)


# Live ghost count. -1 when the DB cannot be opened or fails the schema
# gate (no header means no count), so the adapter can distinguish "empty DB"
# from "missing DB" on the upload path.
func row_count() -> int:
	if _refresh_cache() != "ok":
		return -1
	return _n


# Loads (or refreshes) the header + array cache. Returns "ok", "open_fail"
# (file missing/unreadable — warns db_open_fail like the old per-call open)
# or "schema" (gate mismatch; _ver carries the found format version).
func _refresh_cache() -> String:
	var probe = File.new()
	var mtime = int(probe.get_modified_time(_db_path))
	var flen = 0
	if mtime != 0 and probe.open(_db_path, File.READ) == OK:
		flen = int(probe.get_len())
		probe.close()
	# mtime alone has 1-second resolution; size too so a same-second
	# replacement is not served from the stale cache.
	if _loaded and mtime != 0 and mtime == _mtime and flen == _flen:
		return "ok" if _gate_ok else "schema"
	var f = File.new()
	if f.open(_db_path, File.READ) != OK:
		_log.warn("db_open_fail path=%s" % _db_path.get_file())
		return "open_fail"
	_loaded = false
	_gate_ok = false
	_ver = "unknown"
	_n = 0
	if f.get_len() >= 12:
		var magic = f.get_buffer(4).get_string_from_utf8()
		var ver = f.get_32()
		_ver = str(ver)
		if magic == MAGIC:
			_n = f.get_32()
			if ver == FORMAT_VERSION:
				_read_arrays(f)
				_gate_ok = true
	f.close()
	if _gate_ok:
		_mtime = mtime
		_flen = flen
		_loaded = true
	return "ok" if _gate_ok else "schema"


# Section order (docs/ghost-db-format.md): version table, steam_ids,
# blob_offsets, d_codes, d_order, r_values, then summary_offsets
# (u64[N], file row i's summary record is at summary_offsets[i]). Integer
# arrays use GDScript's 64-bit int via plain Array (PoolRealArray is f32 and
# corrupts u64s and offsets above 2^24; PoolIntArray covers the u32 d_order
# exactly).
func _read_arrays(f) -> void:
	var vcount = f.get_8()
	var vbytes = f.get_buffer(2 * vcount)
	_version_codes = PoolStringArray()
	_version_codes.resize(vcount)
	for i in range(vcount):
		_version_codes[i] = vbytes.subarray(i * 2, i * 2 + 1).get_string_from_utf8()
	_steam_ids = []
	_steam_ids.resize(_n)
	for i in range(_n):
		_steam_ids[i] = f.get_64()
	_blob_offsets = []
	_blob_offsets.resize(_n)
	for i in range(_n):
		_blob_offsets[i] = f.get_64()
	_d_codes = f.get_buffer(_n)
	_d_order = PoolIntArray()
	_d_order.resize(_n)
	for i in range(_n):
		_d_order[i] = f.get_32()
	_r_values = []
	_r_values.resize(_n)
	for i in range(_n):
		_r_values[i] = f.get_double()
	_summary_offsets = []
	_summary_offsets.resize(_n)
	for i in range(_n):
		_summary_offsets[i] = f.get_64()


# v2 summary record for file row i (dense rank i+1): u8 class (255 =
# classless/unknown), u8 flags (bit0 perfect, bit1 undecodable), LEB128
# item count, then count LEB128 varints — the first an absolute descriptor
# index, each next the gap to the previous. Self-delimiting: the count
# fixes the record length, no end offset needed. Reading summary bytes is
# not board decoding — the v2 sweep never touches BitStream/BoardDecoder.
func _read_summary(f, i: int) -> Dictionary:
	f.seek(int(_summary_offsets[i]))
	var cls = f.get_8()
	var flags = f.get_8()
	var count = _read_uvarint(f)
	var items: Array = []
	var prev = 0
	for k in range(count):
		var idx = _read_uvarint(f)
		if k > 0:
			idx += prev
		items.push_back(idx)
		prev = idx
	return {
		"class": cls, "perfect": (flags & 1) != 0,
		"undecodable": (flags & 2) != 0, "items": items,
	}


# Unsigned LEB128: 7-bit little-endian groups, bit 8 continues.
func _read_uvarint(f) -> int:
	var value = 0
	var shift = 0
	while shift < 64:
		var b = f.get_8()
		value |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			break
		shift += 7
	return value


# COUNT(*) + 1 ghosts above r, via binary search over the descending
# r_values: the first index with r_values[i] <= r is the count of strictly
# greater values (matches the old COUNT WHERE r > ?).
func _estimate_rank(r: float) -> int:
	var lo = 0
	var hi = _n
	while lo < hi:
		var mid = (lo + hi) >> 1
		if _r_values[mid] > r:
			lo = mid + 1
		else:
			hi = mid
	return lo + 1


# Probe the game's minimum accepted ghost version: walk rows oldest-d first
# through the game's own parser; first parseable d marks the live cutoff.
# Reported via out (min_d, scanned) so the adapter can persist it to
# player_state.json for reference; the seeder derives its version window
# on its own (--keep-d).
func _probe_min_d(out: Dictionary, state: Dictionary) -> void:
	var f = File.new()
	if f.open(_db_path, File.READ) != OK:
		_log.warn("probe_no_parse cached_min_d=%s" % str(state.get("cached_min_d", "(none)")))
		return
	var scanned = 0
	for k in range(_n):
		if scanned >= PROBE_SCAN_LIMIT:
			break
		var idx = int(_d_order[k])
		if idx < 0 or idx >= _n:
			continue
		scanned += 1
		var parsed = JSON.parse(_read_blob(f, idx))
		if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
			continue
		var dict = parsed.result
		dict["ugc"] = 1
		if _parse_fn.call_func(dict):
			# Version codes are exactly 2 chars (the old d column's substr(0, 2)).
			var min_d = _version_codes[int(_d_codes[idx])]
			out["min_d"] = min_d
			out["scanned"] = scanned
			_log.info("probe min_d=%s scanned=%d" % [min_d, scanned])
			f.close()
			return
	f.close()
	_log.warn("probe_no_parse cached_min_d=%s" % str(state.get("cached_min_d", "(none)")))


# Reads one metadata blob at its framing header (comp_len u32, raw_len u32,
# gzip stream) and returns the UTF-8 string; "" when unreadable/corrupt.
func _read_blob(f, idx: int) -> String:
	f.seek(int(_blob_offsets[idx]))
	var comp_len = f.get_32()
	var raw_len = f.get_32()
	var comp = f.get_buffer(comp_len)
	if comp.size() != comp_len or raw_len <= 0:
		return ""
	var raw = comp.decompress(raw_len, File.COMPRESSION_GZIP)
	if raw.size() != raw_len:
		return ""
	return raw.get_string_from_utf8()


# Opponent-window arithmetic shared by _query_runs and the filter refill:
# rank-centered 1000-rank half-window, lo clamped to 1.
func _window_bounds(rank: int) -> Dictionary:
	return {
		"lo": max(1, rank - 1000), "hi": rank + 1000,
	}


# The old WINDOW_SQL as array arithmetic: dense ranks lo..hi ascending
# (index = rank - 1, lo clamped to 1, hi clamped to N), raw_len > 10, own
# steam_id excluded, at most limit rows. Returns the rows plus the swept
# dense range (1-based inclusive, hi=0 when nothing was processed): the
# ranks the loop actually iterated, skips included - a refill widens around
# them instead of re-reading them.
func _window_rows(lo: int, hi: int, player_id: int, limit: int) -> Dictionary:
	var rows: Array = []
	var summaries: Array = []
	var swept_hi = 0
	if limit <= 0:
		return {"rows": rows, "summaries": summaries, "lo": 0, "hi": 0}
	var lo_i = max(1, lo) - 1
	var hi_i = min(hi, _n) - 1
	if lo_i > hi_i:
		return {"rows": rows, "summaries": summaries, "lo": 0, "hi": 0}
	var f = File.new()
	if f.open(_db_path, File.READ) != OK:
		return {"rows": rows, "summaries": summaries, "lo": 0, "hi": 0}
	for i in range(lo_i, hi_i + 1):
		swept_hi = i + 1
		if player_id != -1 and int(_steam_ids[i]) == player_id:
			continue
		f.seek(int(_blob_offsets[i]))
		var comp_len = f.get_32()
		var raw_len = f.get_32()
		if raw_len <= 10:
			continue
		rows.push_back(_blob_string(f, comp_len, raw_len))
		# The summary record rides along, same array slot as its row.
		summaries.push_back(_read_summary(f, i))
		if rows.size() >= limit:
			break
	f.close()
	return {"rows": rows, "summaries": summaries, "lo": max(1, lo), "hi": swept_hi}


func _query_runs(rank: int, player_id: int, limit: int) -> Dictionary:
	if rank > 0:
		var b = _window_bounds(rank)
		var primary = _window_rows(b["lo"], b["hi"], player_id, limit)
		if not primary["rows"].empty():
			return primary

	if _n > 0:
		var lo_rank = int(_n * 0.25) + 1
		var hi_rank = int(_n * 0.75)
		_log.warn("no_rank using middle-50%% window=[%d-%d] total_rows=%d" % [lo_rank, hi_rank, _n])
		return _window_rows(lo_rank, hi_rank, player_id, limit)
	return {"rows": [], "summaries": [], "lo": 0, "hi": 0}


# Decompresses the gzip stream just read at the cursor into a UTF-8 string;
# "" when unreadable/corrupt.
func _blob_string(f, comp_len: int, raw_len: int) -> String:
	var comp = f.get_buffer(comp_len)
	if comp.size() != comp_len or raw_len <= 0:
		return ""
	var raw = comp.decompress(raw_len, File.COMPRESSION_GZIP)
	if raw.size() != raw_len:
		return ""
	return raw.get_string_from_utf8()


# Apply an injected exclusion filter: "" keeps a run, any other return is a
# rule label. Runs are forwarded untouched — GhostDb never reads game fields.
# Times itself: the sweep is the load's dominant cost and the load line
# reports its total.
func _apply_filter(runs: Array, filter_fn) -> Array:
	var t0 = OS.get_ticks_usec()
	var kept: Array = []
	var kills: Dictionary = {}
	for run in runs:
		var rule = filter_fn.call_func(run)
		if rule == "":
			kept.push_back(run)
		else:
			kills[rule] = int(kills.get(rule, 0)) + 1
	_log.info("filter kept=%d filtered=%d ms=%d rules=%s" % [kept.size(), runs.size() - kept.size(), _ms_since(t0), str(kills)])
	return kept


# Parse metadata strings through the injected game parser. summaries rides
# in from _window_rows (same slot per row). Returns the parser's own results
# (plain dictionaries in tests, game run objects in the mod) plus the
# json/parse counters and its own ms — same keys, same slicing, same failure
# counting as before the split.
func _parse_rows(rows: Array, summaries: Array) -> Dictionary:
	var t0 = OS.get_ticks_usec()
	var json_ok = 0
	var parse_ok = 0
	var runs: Array = []
	for ri in range(rows.size()):
		var meta = rows[ri]
		var parsed = JSON.parse(meta)
		if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
			json_ok += 1
			var dict = parsed.result
			dict["ugc"] = 1
			var runData = _parse_fn.call_func(dict)
			if runData:
				# The summary rides the parsed run — dictionaries take the
				# key, game RunData objects take an Object meta (they have
				# no such declared member to set).
				if typeof(runData) == TYPE_DICTIONARY:
					runData["_summary"] = summaries[ri]
				else:
					runData.set_meta("_summary", summaries[ri])
				runs.push_back(runData)
				parse_ok += 1
			elif parse_ok == 0 and json_ok <= 3:
				_log.warn("parse_fail row=%d keys=%s" % [json_ok, str(dict.keys().slice(0, 6))])
		elif json_ok == 0:
			_log.warn("json_fail error=%d type=%d preview=%s" % [parsed.error, typeof(parsed.result), meta.substr(0, 60)])
	return {"json_ok": json_ok, "parse_ok": parse_ok, "runs": runs, "ms": _ms_since(t0)}
