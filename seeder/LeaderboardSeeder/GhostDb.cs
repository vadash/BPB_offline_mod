using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace LeaderboardSeeder;

// BGDB v1 (see docs/ghost-db-format.md). The seeder and the merger (seeder --merge)
// both write through this type so the byte layout stays single-sourced.
internal static class GhostDb
{
	public const string MergeFileName = "ghosts-merged.gdb";

	// Rows are written in the given list order; that order IS dense-rank order
	// (index i = rank i + 1). Returns the row count written.
	// Atomic: writes path + ".tmp" then File.Move(overwrite: true).
	public static int Write(IReadOnlyList<Entry> rows, string path, Action<int, int>? progress = null)
	{
		int n = rows.Count;
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
		long prefixSize = 12L + 1L + 2L * versionCodes.Length + 29L * n;
		byte[][] compBlobs = new byte[n][];
		long[] blobOffsets = new long[n];
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
				binaryWriter.Write(1u);
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
				binaryWriter.Flush();
				blobMs.WriteTo(fileStream);
			}
		}
		File.Move(tmpPath, path, overwrite: true);
		return n;
	}

	public sealed record ReadResult(IReadOnlyList<Entry> Rows, int Rejected);

	// Reads rows in dense-rank order (file order). Rows whose metadata lacks a
	// numeric "r" or a >=2-char "d" are counted in Rejected, mirroring the
	// seeder's parse-time rejection. Throws InvalidDataException on schema-gate
	// or framing violations.
	public static ReadResult Read(string path)
	{
		byte[] bytes = File.ReadAllBytes(path);
		if (bytes.Length < 12 || bytes[0] != (byte)'B' || bytes[1] != (byte)'G' || bytes[2] != (byte)'D' || bytes[3] != (byte)'B')
		{
			throw new InvalidDataException("bad magic (not a BGDB ghost DB).");
		}
		uint formatVersion = BitConverter.ToUInt32(bytes, 4);
		if (formatVersion != 1u)
		{
			throw new InvalidDataException($"unsupported format_version {formatVersion} (expected 1).");
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
		return new ReadResult(rows, rejected);
	}
}
