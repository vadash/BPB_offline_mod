extends Reference

# ---------------------------------------------------------------------------
# GhostDb — deep module owning every ghost-DB read: schema gate, min-d cutoff
# probe, rank estimate, opponent window, and metadata parsing.
# Knows nothing about the game: the score parser is injected as a FuncRef by
# the adapter (wrapping RunDatabase.parseSingleScore). Reads the seeder's
# BGDB v1 file (docs/ghost-db-format.md) with plain File seek/read only. The
# header + dense-rank arrays are cached lazily per instance (the adapter
# holds one GhostDb for the session); the cache reloads when the file's
# mtime changes, so a seeder-replaced DB is picked up mid-session. Metadata
# blobs are always read on demand, never cached. Vocabulary: a "ghost" is
# one parsed opponent run; the "opponent window" is the rank range ghosts
# are drawn from; the "min-d cutoff" is the oldest ghost version the live
# game still accepts.
# ---------------------------------------------------------------------------

const MAGIC = "BGDB"
const FORMAT_VERSION = 1

# Probe cap: runs examined oldest-d first before giving up (the old SQL
# LIMIT 200 on the probe query).
const PROBE_SCAN_LIMIT = 200

# Rank tier offsets for progression tuning (negative shifts = easier opponents)
const ELO_TIER_BRONZE_SILVER = 0     # Ranks ~100k+
const ELO_TIER_GOLD_PLATINUM = 1     # Ranks ~50k-100k
const ELO_TIER_DIAMOND = 2           # Ranks ~15k-50k
const ELO_TIER_MASTER = 3            # Ranks ~5k-15k
const ELO_TIER_GRANDMASTER = 4       # Ranks ~1k-5k
const ELO_TIER_GRANDMA = 5           # Ranks ~1-1k

const TIER_OFFSETS = {
	ELO_TIER_BRONZE_SILVER: 0.00,    # No shift - fair matches
	ELO_TIER_GOLD_PLATINUM: 0.00,    # No shift - fair matches
	ELO_TIER_DIAMOND: -0.10,         # Shift 10% toward lower ranks
	ELO_TIER_MASTER: -0.15,          # Shift 15% toward lower ranks
	ELO_TIER_GRANDMASTER: -0.20,     # Shift 20% toward lower ranks
	ELO_TIER_GRANDMA: -0.25,         # Shift 25% toward lower ranks
}

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


func setup(db_path: String, logger, parse_fn) -> void:
	_db_path = db_path
	_log = logger
	_parse_fn = parse_fn


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
	# the live row count differs from the cached one (DB was replaced).
	var player_rank = -1
	if state["player_id"] != -1:
		var cached_r = state["player_r"]
		var cached_rows = int(state["db_row_count"])

		out["db_rows"] = _n

		if cached_r != null:
			if out["db_rows"] != cached_rows:
				# DB was replaced — recompute rank against new distribution.
				_log.info("db_changed old_rows=%d new_rows=%d re-estimating rank from cached r=%s" % [cached_rows, out["db_rows"], str(cached_r)])
				out["db_changed"] = true
				player_rank = _estimate_rank(float(cached_r))
				if player_rank >= 0:
					_log.info("db_changed rank=%d" % player_rank)
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
	var rows = _query_runs(player_rank, state["player_id"], state["window"])
	var raw_rows = rows.size()
	_log.info("query_rows=%d" % raw_rows)
	var totals = _parse_rows(rows)
	out["runs"] = totals["runs"]
	out["json_ok"] = totals["json_ok"]
	out["parse_ok"] = totals["parse_ok"]
	if filter_fn != null:
		out["runs"] = _apply_filter(out["runs"], filter_fn)
	if out["parse_ok"] == 0 and raw_rows > 0:
		_log.warn("parse_zero primary window yielded no parseable runs, retrying with middle-50% window")
		var total_rows = out["db_rows"] if out["db_rows"] > 0 else _n
		var lo_rank = int(total_rows * 0.25) + 1
		var hi_rank = int(total_rows * 0.75)
		var fb_rows = _window_rows(lo_rank, hi_rank, state["player_id"], state["window"])
		var fb = _parse_rows(fb_rows)
		out["runs"] += fb["runs"]
		out["json_ok"] += fb["json_ok"]
		out["parse_ok"] += fb["parse_ok"]
		_log.info("fallback rows=%d parse_ok=%d" % [fb_rows.size(), fb["parse_ok"]])
		if filter_fn != null:
			out["runs"] = _apply_filter(out["runs"], filter_fn)

	# A filter that gutted the rank-centered window widens it: double the
	# half-window until it covers the whole DB so exclusions cannot starve
	# the match. The no-rank middle-50% fallback window is never refilled.
	if filter_fn != null and player_rank > 0:
		var threshold = int(state["window"] / 2)
		var bounds = _window_bounds(player_rank, out["db_rows"])
		var seen = {}
		for run in out["runs"]:
			var rid = _run_key(run)
			if rid != null:
				seen[rid] = true
		var half = 1000
		while out["runs"].size() < threshold and not (bounds["lo"] <= 1 and bounds["hi"] >= out["db_rows"]):
			half *= 2
			var lo = max(1, bounds["adjusted"] - half)
			var hi = bounds["adjusted"] + half
			var rp_rows = _window_rows(lo, hi, state["player_id"], hi - lo + 1)
			var rp = _parse_rows(rp_rows)
			out["json_ok"] += rp["json_ok"]
			out["parse_ok"] += rp["parse_ok"]
			var refill = _apply_filter(rp["runs"], filter_fn)
			for run in refill:
				var rid = _run_key(run)
				if rid != null:
					if seen.has(rid):
						continue
					seen[rid] = true
				out["runs"].push_back(run)
			bounds["lo"] = lo
			bounds["hi"] = hi
			_log.info("refill half=%d lo=%d hi=%d kept=%d" % [half, lo, hi, out["runs"].size()])

	_log.info("load db_rows=%d rank=%d runs=%d json_ok=%d parse_ok=%d" % [out["db_rows"], player_rank, out["runs"].size(), out["json_ok"], out["parse_ok"]])
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
# blob_offsets, d_codes, d_order, r_values. Integer arrays use GDScript's
# 64-bit int via plain Array (PoolRealArray is f32 and corrupts u64s and
# offsets above 2^24; PoolIntArray covers the u32 d_order exactly).
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


func _get_rank_tier(rank: int, total_rows: int) -> int:
	if total_rows < 100:
		return ELO_TIER_BRONZE_SILVER
	var pct = 1.0 - (float(rank) / float(total_rows))
	if pct < 0.33:
		return ELO_TIER_BRONZE_SILVER
	elif pct < 0.66:
		return ELO_TIER_GOLD_PLATINUM
	elif rank < 1000:
		return ELO_TIER_GRANDMA
	elif rank < 5000:
		return ELO_TIER_GRANDMASTER
	elif rank < 15000:
		return ELO_TIER_MASTER
	else:
		return ELO_TIER_DIAMOND


# Opponent-window arithmetic shared by _query_runs and the filter refill:
# tier-adjusted center, 1000-rank half-window, lo clamped to 1.
func _window_bounds(rank: int, total_rows: int) -> Dictionary:
	var tier = _get_rank_tier(rank, total_rows)
	var offset_pct = TIER_OFFSETS.get(tier, 0.0)
	var adjusted_rank = max(1, int(rank + (rank * offset_pct)))
	return {
		"tier": tier, "offset": offset_pct, "adjusted": adjusted_rank,
		"lo": max(1, adjusted_rank - 1000), "hi": adjusted_rank + 1000,
	}


# The old WINDOW_SQL as array arithmetic: dense ranks lo..hi ascending
# (index = rank - 1, lo clamped to 1, hi clamped to N), raw_len > 10, own
# steam_id excluded, at most limit rows.
func _window_rows(lo: int, hi: int, player_id: int, limit: int) -> Array:
	var rows: Array = []
	if limit <= 0:
		return rows
	var lo_i = max(1, lo) - 1
	var hi_i = min(hi, _n) - 1
	if lo_i > hi_i:
		return rows
	var f = File.new()
	if f.open(_db_path, File.READ) != OK:
		return rows
	for i in range(lo_i, hi_i + 1):
		if player_id != -1 and int(_steam_ids[i]) == player_id:
			continue
		f.seek(int(_blob_offsets[i]))
		var comp_len = f.get_32()
		var raw_len = f.get_32()
		if raw_len <= 10:
			continue
		rows.push_back(_blob_string(f, comp_len, raw_len))
		if rows.size() >= limit:
			break
	f.close()
	return rows


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


func _query_runs(rank: int, player_id: int, limit: int) -> Array:
	if rank > 0:
		var b = _window_bounds(rank, _n)
		if b["offset"] != 0.0:
			_log.info("rank_adjust tier=%d rank=%d->%d offset=%.0f%%" % [b["tier"], rank, b["adjusted"], b["offset"] * 100])
		var rows = _window_rows(b["lo"], b["hi"], player_id, limit)
		if not rows.empty():
			return rows

	if _n > 0:
		var lo_rank = int(_n * 0.25) + 1
		var hi_rank = int(_n * 0.75)
		_log.warn("no_rank using middle-50%% window=[%d-%d] total_rows=%d" % [lo_rank, hi_rank, _n])
		return _window_rows(lo_rank, hi_rank, player_id, limit)
	return []


# Apply an injected exclusion filter: "" keeps a run, any other return is a
# rule label. Runs are forwarded untouched — GhostDb never reads game fields.
func _apply_filter(runs: Array, filter_fn) -> Array:
	var kept: Array = []
	var kills: Dictionary = {}
	for run in runs:
		var rule = filter_fn.call_func(run)
		if rule == "":
			kept.push_back(run)
		else:
			kills[rule] = int(kills.get(rule, 0)) + 1
	_log.info("filter kept=%d filtered=%d rules=%s" % [kept.size(), runs.size() - kept.size(), str(kills)])
	return kept


# Parse metadata strings through the injected game parser. Returns the
# parser's own results (plain dictionaries in tests, game run objects in the
# mod) plus the json/parse counters — same keys, same slicing, same failure
# counting as before the split.
func _parse_rows(rows: Array) -> Dictionary:
	var json_ok = 0
	var parse_ok = 0
	var runs: Array = []
	for meta in rows:
		var parsed = JSON.parse(meta)
		if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
			json_ok += 1
			var dict = parsed.result
			dict["ugc"] = 1
			var runData = _parse_fn.call_func(dict)
			if runData:
				runs.push_back(runData)
				parse_ok += 1
			elif parse_ok == 0 and json_ok <= 3:
				_log.warn("parse_fail row=%d keys=%s" % [json_ok, str(dict.keys().slice(0, 6))])
		elif json_ok == 0:
			_log.warn("json_fail error=%d type=%d preview=%s" % [parsed.error, typeof(parsed.result), meta.substr(0, 60)])
	return {"json_ok": json_ok, "parse_ok": parse_ok, "runs": runs}
