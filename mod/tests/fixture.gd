extends Reference

# Writes throwaway ghost DBs in the seeder's BGDB v1 format
# (docs/ghost-db-format.md): little-endian, dense-rank arrays, gzip metadata
# blobs. format_version is parameterized because tests exercise both the
# matching and the mismatching schema gate. The row dicts keep the old
# column-shaped keys; "rank" orders the file (stable sort, mirroring the
# seeder's dense re-rank 1..N) and is not written; "workshop_id"/"score"/"p"
# are accepted for shape parity and dropped (ADR 0003).

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

static func build(path: String, format_version: int, rows: Array) -> bool:
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
	var prefix = 12 + 1 + 2 * codes.size() + 29 * n
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
	f.store_32(format_version)
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
	for i in range(n):
		f.store_32(comp_blobs[i][0].size())
		f.store_32(comp_blobs[i][1])
		f.store_buffer(comp_blobs[i][0])
	f.close()
	return true
