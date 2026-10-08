extends Reference

# Writes throwaway ghost DBs in the seeder's BGDB v2 format
# (docs/ghost-db-format.md): little-endian, dense-rank arrays, gzip metadata
# blobs, per-run summary section (offsets + adjacent records). This is
# test-side emission only — the production writer is the seeder's GhostDb.cs.
# Gate-reject legs (wrong format_version) patch the header bytes after a
# build; the builder itself always writes v2. The row dicts keep the old
# column-shaped keys; "rank" orders the file (stable sort, mirroring the
# seeder's dense re-rank 1..N) and is not written; "workshop_id"/"score"/"p"
# are accepted for shape parity and dropped (ADR 0003). Rows may carry
# opts.summary = {"class": int, "perfect": bool, "undecodable": bool,
# "items": Array of descriptor indexes}; rows without it get the classless
# default record (class 255, no flags, no items).

class PairSort:
	# Stable comparator: by slot 0, ties by slot 1 (the dense index).
	static func less(a, b) -> bool:
		if a[0] < b[0]:
			return true
		if a[0] > b[0]:
			return false
		return a[1] < b[1]

# One runs row; opts overrides any field (e.g. {"r": 2.5} or {"d": "ab"}).
static func row(steam_id: int, rank: int, metadata: String, opts: Dictionary = {}) -> Dictionary:
	var out = {
		"steam_id": steam_id,
		"rank": rank,
		"workshop_id": 100 + rank,
		"score": rank,
		"r": 1.0,
		"p": "p",
		"d": "v1",
		"metadata": metadata,
	}
	for key in opts:
		out[key] = opts[key]
	return out

static func build(path: String, rows: Array) -> bool:
	var dir = Directory.new()
	var base = path.get_base_dir()
	if not dir.dir_exists(base):
		dir.make_dir_recursive(base)
	if dir.file_exists(path):
		dir.remove(path)

	# Dense rank 1..N: stable sort by the row's rank field.
	var pairs = []
	for i in range(rows.size()):
		pairs.append([rows[i].get("rank", 0), i])
	pairs.sort_custom(PairSort.new(), "less")
	var order = []
	for p in pairs:
		order.append(rows[p[1]])

	# Version table: distinct first-2-chars of d, ascending.
	var codes = []
	var seen = {}
	for r in order:
		var code = str(r.get("d", "v1")).substr(0, 2)
		if not seen.has(code):
			seen[code] = true
			codes.append(code)
	codes.sort()
	var code_rank = {}
	for i in range(codes.size()):
		code_rank[codes[i]] = i

	var n = order.size()
	var d_codes = []
	var d_order_pairs = []
	var r_values = []
	for i in range(n):
		var r = order[i]
		var ci = int(code_rank[str(r.get("d", "v1")).substr(0, 2)])
		d_codes.append(ci)
		d_order_pairs.append([ci, i])
		r_values.append(float(r.get("r", 1.0)))
	d_order_pairs.sort_custom(PairSort.new(), "less")
	var d_order = []
	for p in d_order_pairs:
		d_order.append(p[1])
	r_values.sort()

	# Blob section: framing header (comp_len u32, raw_len u32) + gzip stream.
	# The summary section (u64[N] offsets + adjacent records) sits between
	# r_values and the blobs, so the blobs shift by its size.
	var summary_payloads = []
	var summary_rel_offsets = []
	var payload_size = 0
	for r in order:
		var payload = _encode_summary(r.get("summary", null))
		summary_rel_offsets.append(payload_size)
		summary_payloads.append(payload)
		payload_size += payload.size()
	var prefix = 12 + 1 + 2 * codes.size() + 29 * n
	prefix += 8 * n + payload_size
	# The summary offsets array (8 * n) sits between r_values and the
	# records, so the records begin at prefix minus the payload size.
	var record_base = prefix - payload_size
	var comp_blobs = []
	var blob_offsets = []
	var next_off = prefix
	for r in order:
		var raw_bytes = str(r.get("metadata", "")).to_utf8()
		# Godot 3.6 signature: compress(compression_mode) — one arg, the mode
		# (Godot 4 moved buffer_size in). GZIP mode emits RFC 1952.
		var comp = raw_bytes.compress(File.COMPRESSION_GZIP)
		comp_blobs.append([comp, raw_bytes.size()])
		blob_offsets.append(next_off)
		next_off += 8 + comp.size()

	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		push_error("fixture: cannot write " + path)
		return false
	f.store_buffer("BGDB".to_ascii())
	f.store_32(2) # format_version: the seeder's only output
	f.store_32(n)
	f.store_8(codes.size())
	for code in codes:
		f.store_buffer(code.to_ascii())
	for r in order:
		f.store_64(int(r.get("steam_id", 0)))
	for off in blob_offsets:
		f.store_64(off)
	for ci in d_codes:
		f.store_8(ci)
	for idx in d_order:
		f.store_32(idx)
	for i in range(n - 1, -1, -1):
		f.store_double(r_values[i])
	for off in summary_rel_offsets:
		f.store_64(record_base + off)
	for payload in summary_payloads:
		f.store_buffer(payload)
	for i in range(n):
		f.store_32(comp_blobs[i][0].size())
		f.store_32(comp_blobs[i][1])
		f.store_buffer(comp_blobs[i][0])
	f.close()
	return true


# v2 summary record bytes (test-side twin of the seeder's EncodeSummary):
# u8 class (255 = classless/unknown), u8 flags (bit0 perfect, bit1
# undecodable), LEB128 item count, then count LEB128 varints — the first an
# absolute descriptor index, each next the gap to the previous (>= 1).
# summary is {"class": int, "perfect": bool, "undecodable": bool,
# "items": Array} or null for the classless default record.
static func _encode_summary(summary) -> PoolByteArray:
	var s = {"class": 255, "perfect": false, "undecodable": false, "items": []}
	if summary != null:
		for key in summary:
			s[key] = summary[key]
	var out = PoolByteArray()
	out.append(int(s["class"]))
	out.append((1 if s["perfect"] else 0) | (2 if s["undecodable"] else 0))
	out = _store_uvarint(out, s["items"].size())
	var prev = 0
	for i in range(s["items"].size()):
		var idx = int(s["items"][i])
		out = _store_uvarint(out, idx if i == 0 else idx - prev)
		prev = idx
	return out


static func _store_uvarint(out: PoolByteArray, value: int) -> PoolByteArray:
	while value >= 0x80:
		out.append((value & 0x7F) | 0x80)
		value >>= 7
	out.append(value)
	return out
