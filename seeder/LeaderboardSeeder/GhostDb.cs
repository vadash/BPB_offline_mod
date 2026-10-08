using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace LeaderboardSeeder;

// BGDB v2 (see docs/ghost-db-format.md): the v1 layout plus a per-run
// exclusion summary section. The seeder and the merger (seeder --merge) both
// write through this type so the byte layout stays single-sourced. The read
// gate accepts format_version 2 only; the mod-side reader is equally strict.
internal static class GhostDb
{
	// Header-unreadable runs get no class; mirrors the mod's "cannot match"
	// handling, which keeps such runs.
	public const int UnknownClass = BoardDecoder.UnknownClass;

	public sealed record RunSummary(int Class, bool Perfect, bool Undecodable, IReadOnlyList<int> ItemIndexes);

	// Output names carry the local date, so a folder of scrapes becomes a
	// history: same-day reruns overwrite (Write is atomic), other days keep.
	public static string SeedFileName(DateOnly date) => $"ghosts-{date:dd-MM-yy}.gdb";

	public static string MergeFileName(DateOnly date) => $"ghosts-merged-{date:dd-MM-yy}.gdb";

	// Rows are written in the given list order; that order IS dense-rank order
	// (index i = rank i + 1). Returns the row count written.
	// Atomic: writes path + ".tmp" then File.Move(overwrite: true).
	public static int Write(IReadOnlyList<Entry> rows, string path, ItemBook book, Action<int, int>? progress = null)
	{
		int n = rows.Count;
		// The BGDB version table stores exactly the first 2 chars of d, and
		// the read gate (and RunFilter.Admit) enforce d >= 2 chars - rows
		// below that are unrepresentable, so fail loudly instead of emitting
		// a misaligned file. Header DECODE failures are different: they mark
		// the row undecodable and never throw.
		if (rows.Any(e => e.D.Length < 2))
		{
			throw new ArgumentException("every entry needs a d of at least 2 chars.", nameof(rows));
		}
		string[] versionCodes = rows.Select(e => e.D.Substring(0, 2)).Distinct().OrderBy(c => c, StringComparer.Ordinal).ToArray();
		Dictionary<string, byte> versionIndex = new Dictionary<string, byte>(versionCodes.Length);
		for (int i = 0; i < versionCodes.Length; i++)
		{
			versionIndex[versionCodes[i]] = (byte)i;
		}
		byte[] dCodes = new byte[n];
		for (int i = 0; i < n; i++)
		{
			dCodes[i] = versionIndex[rows[i].D.Substring(0, 2)];
		}
		int[] dOrder = Enumerable.Range(0, n).OrderBy(i => dCodes[i]).ThenBy(i => i).ToArray();
		double[] rValues = rows.Select(e => e.R).OrderByDescending(r => r).ToArray();
		// Summaries first: the absolute blob offsets must account for the
		// summary section sitting between r_values and the blob section.
		RunSummary[] summaries = new RunSummary[n];
		byte[][] summaryPayloads = new byte[n][];
		long summaryPayloadSize = 0;
		for (int i = 0; i < n; i++)
		{
			summaries[i] = BuildSummary(rows[i], book);
			summaryPayloads[i] = EncodeSummary(summaries[i]);
			summaryPayloadSize += summaryPayloads[i].Length;
		}
		long prefixSize = 12L + 1L + 2L * versionCodes.Length + 29L * n + 8L * n + summaryPayloadSize;
		byte[][] compBlobs = new byte[n][];
		long[] blobOffsets = new long[n];
		long[] summaryOffsets = new long[n];
		long summaryOffsetCursor = 0;
		for (int i = 0; i < n; i++)
		{
			summaryOffsets[i] = prefixSize - summaryPayloadSize + summaryOffsetCursor;
			summaryOffsetCursor += summaryPayloads[i].Length;
		}
		string tmpPath = path + ".tmp";
		using (MemoryStream blobMs = new MemoryStream())
		{
			for (int i = 0; i < n; i++)
			{
				byte[] rawBytes = Encoding.UTF8.GetBytes(rows[i].Metadata);
				using MemoryStream srcMs = new MemoryStream(rawBytes);
				using MemoryStream dstMs = new MemoryStream(rawBytes.Length / 2 + 64);
				using (GZipStream gzipStream = new GZipStream(dstMs, CompressionLevel.Optimal))
				{
					srcMs.CopyTo(gzipStream);
				}
				compBlobs[i] = dstMs.ToArray();
				blobOffsets[i] = prefixSize + blobMs.Position;
				blobMs.Write(BitConverter.GetBytes((uint)compBlobs[i].Length), 0, 4);
				blobMs.Write(BitConverter.GetBytes((uint)rawBytes.Length), 0, 4);
				blobMs.Write(compBlobs[i], 0, compBlobs[i].Length);
				progress?.Invoke(i + 1, n);
			}
			using (FileStream fileStream = new FileStream(tmpPath, FileMode.Create, FileAccess.Write, FileShare.None))
			{
				using BinaryWriter binaryWriter = new BinaryWriter(fileStream);
				binaryWriter.Write("BGDB"u8);
				binaryWriter.Write(2u);
				binaryWriter.Write((uint)n);
				binaryWriter.Write((byte)versionCodes.Length);
				foreach (string versionCode in versionCodes)
				{
					binaryWriter.Write(Encoding.ASCII.GetBytes(versionCode));
				}
				foreach (Entry row in rows)
				{
					binaryWriter.Write(row.SteamId);
				}
				foreach (long blobOffset in blobOffsets)
				{
					binaryWriter.Write((ulong)blobOffset);
				}
				foreach (byte dCode in dCodes)
				{
					binaryWriter.Write(dCode);
				}
				foreach (int runIndex in dOrder)
				{
					binaryWriter.Write((uint)runIndex);
				}
				foreach (double rValue in rValues)
				{
					binaryWriter.Write(rValue);
				}
				foreach (long summaryOffset in summaryOffsets)
				{
					binaryWriter.Write((ulong)summaryOffset);
				}
				binaryWriter.Flush();
				foreach (byte[] summaryPayload in summaryPayloads)
				{
					fileStream.Write(summaryPayload, 0, summaryPayload.Length);
				}
				blobMs.WriteTo(fileStream);
			}
		}
		File.Move(tmpPath, path, overwrite: true);
		return n;
	}

	// Summary content is decode-equivalent by construction with the mod's
	// exclusion sweep: class/perfect from the d header, the item set the union
	// over present board rounds of successfully decoded indexes, undecodable
	// set iff the header or at least one present board failed. A failed round
	// contributes nothing (the run survives, mod parity), never a crash.
	private static RunSummary BuildSummary(Entry row, ItemBook book)
	{
		BoardDecoder.RunHeader? header = BoardDecoder.DecodeHeader(row.D);
		if (header == null)
		{
			return new RunSummary(UnknownClass, Perfect: false, Undecodable: true, Array.Empty<int>());
		}
		// Game.RoundResult.Win = 0; perfect = first Game.MAX_WINS results all
		// wins (the results all decoded, or the header would have failed).
		bool perfect = true;
		for (int i = 0; i < 10; i++)
		{
			if (header.Results[i] != 0)
			{
				perfect = false;
				break;
			}
		}
		bool undecodable = false;
		HashSet<int> items = new();
		try
		{
			using JsonDocument doc = JsonDocument.Parse(row.Metadata);
			foreach (JsonProperty property in doc.RootElement.EnumerateObject())
			{
				if (!IsBoardKey(property.Name, out int _))
				{
					continue;
				}
				if (property.Value.ValueKind != JsonValueKind.String)
				{
					// Present round the mod could not decode as a board string.
					undecodable = true;
					continue;
				}
				List<int>? decoded = BoardDecoder.DecodeItemIndexes(property.Value.GetString()!, header.EntryVersion, book);
				if (decoded == null)
				{
					undecodable = true;
					continue;
				}
				items.UnionWith(decoded);
			}
		}
		catch (JsonException)
		{
			// No parseable metadata: no boards present, nothing to mark.
		}
		return new RunSummary(header.Class, perfect, undecodable, items.OrderBy(index => index).ToArray());
	}

	// Boards are the top-level JSON keys "0".."17" (game's deserializeMetadata
	// rounds). Anything digit-named beyond 17 is not a board.
	private static bool IsBoardKey(string name, out int day)
	{
		day = -1;
		if (name.Length is < 1 or > 2)
		{
			return false;
		}
		int value = 0;
		foreach (char c in name)
		{
			if (c < '0' || c > '9')
			{
				return false;
			}
			value = value * 10 + (c - '0');
		}
		if (value > 17)
		{
			return false;
		}
		day = value;
		return true;
	}

	// Record: u8 class, u8 flags (bit0 perfect, bit1 undecodable), LEB128 item
	// count, then count LEB128 varints - first the absolute descriptor index,
	// each next the gap to the previous (>= 1, so indexes are sorted and
	// distinct without a length field).
	private static byte[] EncodeSummary(RunSummary summary)
	{
		using MemoryStream ms = new MemoryStream();
		ms.WriteByte((byte)summary.Class);
		ms.WriteByte((byte)((summary.Perfect ? 0x01 : 0) | (summary.Undecodable ? 0x02 : 0)));
		WriteVarint(ms, (ulong)summary.ItemIndexes.Count);
		int previous = 0;
		for (int i = 0; i < summary.ItemIndexes.Count; i++)
		{
			int index = summary.ItemIndexes[i];
			WriteVarint(ms, (ulong)(i == 0 ? index : index - previous));
			previous = index;
		}
		return ms.ToArray();
	}

	private static void WriteVarint(Stream stream, ulong value)
	{
		while (value >= 0x80)
		{
			stream.WriteByte((byte)(value | 0x80));
			value >>= 7;
		}
		stream.WriteByte((byte)value);
	}

	public sealed record ReadResult(
		IReadOnlyList<Entry> Rows,
		int Rejected,
		uint FormatVersion,
		IReadOnlyList<RunSummary> Summaries);

	// Reads rows in dense-rank order (file order). Rows whose metadata lacks a
	// numeric "r" or a >=2-char "d" are counted in Rejected, mirroring the
	// seeder's parse-time rejection. Throws InvalidDataException on schema-gate
	// or framing violations. Each row's summary is Summaries[row.OrigRank - 1].
	public static ReadResult Read(string path)
	{
		byte[] bytes = File.ReadAllBytes(path);
		if (bytes.Length < 12 || bytes[0] != (byte)'B' || bytes[1] != (byte)'G' || bytes[2] != (byte)'D' || bytes[3] != (byte)'B')
		{
			throw new InvalidDataException("bad magic (not a BGDB ghost DB).");
		}
		uint formatVersion = BitConverter.ToUInt32(bytes, 4);
		if (formatVersion != 2u)
		{
			throw new InvalidDataException($"unsupported format_version {formatVersion} (expected 2).");
		}
		uint nRaw = BitConverter.ToUInt32(bytes, 8);
		if (nRaw > (uint)int.MaxValue)
		{
			throw new InvalidDataException($"run_count {nRaw} too large (corrupt file).");
		}
		int n = (int)nRaw;
		int p = 12;
		if (p >= bytes.Length)
		{
			throw new InvalidDataException("truncated header.");
		}
		int v = bytes[p++];
		if (p + 2 * v + 29L * n > bytes.Length)
		{
			throw new InvalidDataException("truncated prefix tables.");
		}
		p += 2 * v; // version table (codes are re-derived from blobs)
		ulong[] steamIds = new ulong[n];
		Buffer.BlockCopy(bytes, p, steamIds, 0, 8 * n);
		p += 8 * n;
		ulong[] blobOffsets = new ulong[n];
		Buffer.BlockCopy(bytes, p, blobOffsets, 0, 8 * n);
		p += 8 * n;
		p += n; // d_codes
		p += 4 * n; // d_order
		p += 8 * n; // r_values
		if (p + 8L * n > bytes.Length)
		{
			throw new InvalidDataException("truncated summary offsets.");
		}
		ulong[] summaryOffsets = new ulong[n];
		Buffer.BlockCopy(bytes, p, summaryOffsets, 0, 8 * n);
		p += 8 * n;
		List<Entry> rows = new List<Entry>(n);
		int rejected = 0;
		for (int i = 0; i < n; i++)
		{
			long offset = (long)blobOffsets[i];
			if (offset < 0 || offset + 8 > bytes.Length)
			{
				throw new InvalidDataException($"blob {i} offset out of range.");
			}
			uint compLenRaw = BitConverter.ToUInt32(bytes, (int)offset);
			uint rawLenRaw = BitConverter.ToUInt32(bytes, (int)offset + 4);
			if (compLenRaw > (uint)(bytes.Length - (int)offset - 8))
			{
				throw new InvalidDataException($"blob {i} framing out of range.");
			}
			if (rawLenRaw > 512 * 1024 * 1024u)
			{
				throw new InvalidDataException($"blob {i} raw_len {rawLenRaw} too large (corrupt file).");
			}
			int compLen = (int)compLenRaw;
			int rawLen = (int)rawLenRaw;
			string metadata;
			try
			{
				using MemoryStream src = new MemoryStream(bytes, (int)offset + 8, compLen, writable: false);
				using GZipStream gzip = new GZipStream(src, CompressionMode.Decompress);
				using MemoryStream dst = new MemoryStream(rawLen);
				gzip.CopyTo(dst);
				if (dst.Length != rawLen)
				{
					throw new InvalidDataException($"blob {i} decompressed to {dst.Length} bytes, expected {rawLen}.");
				}
				// Game-produced metadata is always valid UTF-8 JSON. Invalid bytes
				// decode with replacement chars; such rows may then collapse in
				// content dedup (spec: byte-identical) — accepted, never produced.
				metadata = Encoding.UTF8.GetString(dst.ToArray());
			}
			catch (InvalidDataException ex)
			{
				throw new InvalidDataException(ex.Message);
			}
			double r;
			string? d = null;
			try
			{
				using JsonDocument doc = JsonDocument.Parse(metadata);
				if (!doc.RootElement.TryGetProperty("r", out JsonElement rElement) || rElement.ValueKind != JsonValueKind.Number
					|| !rElement.TryGetDouble(out r))
				{
					rejected++;
					continue;
				}
				if (doc.RootElement.TryGetProperty("d", out JsonElement dElement) && dElement.ValueKind == JsonValueKind.String)
				{
					d = dElement.GetString();
				}
			}
			catch (JsonException)
			{
				rejected++;
				continue;
			}
			if (d == null || d.Length < 2)
			{
				rejected++;
				continue;
			}
			rows.Add(new Entry(steamIds[i], i + 1, 0, r, d, metadata));
		}
		RunSummary[] summaries = new RunSummary[n];
		for (int i = 0; i < n; i++)
		{
			long offset = (long)summaryOffsets[i];
			// Records are adjacent; the last ends where the blob section
			// starts (the first blob's absolute offset).
			long end = i + 1 < n ? (long)summaryOffsets[i + 1] : (long)blobOffsets[0];
			if (offset < 0 || offset > bytes.Length || end < offset || end > bytes.Length)
			{
				throw new InvalidDataException($"summary {i} offset out of range.");
			}
			summaries[i] = ParseSummary(bytes, (int)offset, (int)end);
		}
		return new ReadResult(rows, rejected, formatVersion, summaries);
	}

	private static RunSummary ParseSummary(byte[] bytes, int offset, int end)
	{
		int p = offset;
		if (p + 2 > end)
		{
			throw new InvalidDataException("truncated summary record.");
		}
		int klass = bytes[p++];
		byte flags = bytes[p++];
		(ulong count, p) = ReadVarint(bytes, p, end);
		if (count > (ulong)(end - p))
		{
			throw new InvalidDataException("summary item count exceeds record.");
		}
		int[] indexes = new int[count];
		int index = 0;
		for (ulong k = 0; k < count; k++)
		{
			(ulong value, p) = ReadVarint(bytes, p, end);
			if (value > int.MaxValue || (k > 0 && value == 0) || value > (ulong)(int.MaxValue - index))
			{
				throw new InvalidDataException("summary varint out of range.");
			}
			index = k == 0 ? (int)value : index + (int)value;
			indexes[k] = index;
		}
		return new RunSummary(klass, (flags & 0x01) != 0, (flags & 0x02) != 0, indexes);
	}

	// Unsigned LEB128: 7-bit little-endian groups, continuation bit 0x80.
	private static (ulong Value, int Position) ReadVarint(byte[] bytes, int p, int end)
	{
		ulong value = 0;
		int shift = 0;
		while (true)
		{
			if (p >= end || shift >= 64)
			{
				throw new InvalidDataException("truncated summary varint.");
			}
			byte b = bytes[p++];
			value |= (ulong)(b & 0x7F) << shift;
			if ((b & 0x80) == 0)
			{
				return (value, p);
			}
			shift += 7;
		}
	}
}
