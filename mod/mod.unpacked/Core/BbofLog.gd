extends Reference

# BbofLog — compact, persistent logging for BBOF.

const MAX_LOG_BYTES = 5 * 1024 * 1024  # 5 MB cap before rotation

var _file: File
var _path: String

func open(path: String) -> void:
	_path = path
	_file = File.new()

	# Try to open existing file for append (READ_WRITE preserves content).
	if _file.open(path, File.READ_WRITE) == OK:
		_file.seek_end()
		return

	# File doesn't exist — ensure directory exists, then create.
	var dir = Directory.new()
	var log_dir = path.get_base_dir()
	if not dir.dir_exists(log_dir):
		if dir.make_dir_recursive(log_dir) != OK:
			print("[BBOF] Failed to create log directory: ", log_dir)
			return

	if _file.open(path, File.WRITE) != OK:
		print("[BBOF] Failed to create log file: ", path)
		return
	_file.store_string("# BBOF log - one line per event, format: [HH:MM:SS] LEVEL msg\n")
	_file.close()

	# Reopen in READ_WRITE for future appends.
	if _file.open(path, File.READ_WRITE) != OK:
		print("[BBOF] Failed to reopen log file: ", path)
		return
	_file.seek_end()

func close() -> void:
	if _file:
		_file.close()

func info(msg: String) -> void:
	_write("INFO", msg)

func warn(msg: String) -> void:
	_write("WARN", msg)

func _write(level: String, msg: String) -> void:
	if not _file or not _file.is_open():
		return
	if _file.get_len() > MAX_LOG_BYTES:
		_rotate()
	var time = OS.get_time()
	var timestamp = "%02d:%02d:%02d" % [time.hour, time.minute, time.second]
	var line = "[%s] %-5s %s\n" % [timestamp, level, msg]
	_file.store_string(line)
	_file.flush()
	print(line.strip_edges())

func _rotate() -> void:
	_file.seek(MAX_LOG_BYTES / 2)
	var tail = _file.get_as_text()
	_file.close()
	_file = File.new()
	_file.open(_path, File.WRITE)
	_file.store_string("# BBOF log — rotated\n")
	_file.store_string(tail)
	_file.close()
	_file.open(_path, File.READ_WRITE)
	_file.seek_end()
