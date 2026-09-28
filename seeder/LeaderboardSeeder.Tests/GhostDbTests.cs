using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: the BGDB v1 file surface (GhostDb.Write / GhostDb.Read), per docs/ghost-db-format.md.
public class GhostDbTests
{
	private static string TempPath(string name)
	{
		string dir = Path.Combine(Path.GetTempPath(), "bpb-gdb-tests", Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(dir);
		return Path.Combine(dir, name + ".gdb");
	}

	private static string Metadata(ulong steamId, double r, string d) =>
		"{\"d\":\"" + d + "\",\"r\":" + r.ToString(System.Globalization.CultureInfo.InvariantCulture)
		+ ",\"p\":\"P" + steamId + "\",\"id\":\"id" + steamId + "\",\"0\":\"board0\"}";

	private static Entry Row(ulong steamId, double r, string d) =>
		new(steamId, 0, 0, r, d, Metadata(steamId, r, d));

	[Fact]
	public void Write_then_Read_preserves_rows_in_rank_order()
	{
		List<Entry> rows = new List<Entry>
		{
			Row(111, 100.5, "OCaa"),
			Row(222, 90.0, "ODbb"),
			Row(333, 80.0, "OCcc"),
		};
		string path = TempPath("roundtrip");

		GhostDb.Write(rows, path);

		GhostDb.ReadResult result = GhostDb.Read(path);
		Assert.Equal(0, result.Rejected);
		Assert.Equal(rows.Count, result.Rows.Count);
		Assert.Equal(rows.Select(e => e.SteamId), result.Rows.Select(e => e.SteamId));
		Assert.Equal(rows.Select(e => e.Metadata), result.Rows.Select(e => e.Metadata));
		Assert.Equal(rows.Select(e => e.R), result.Rows.Select(e => e.R));
		Assert.Equal(rows.Select(e => e.D), result.Rows.Select(e => e.D));
	}

	[Fact]
	public void Read_counts_row_without_numeric_r_as_rejected()
	{
		List<Entry> rows = new List<Entry>
		{
			Row(1, 5, "OCaa"),
			new Entry(2, 0, 0, 0.0, "OCbb", "{\"d\":\"OCbb\",\"p\":\"norating\"}"),
		};
		string path = TempPath("reject");

		GhostDb.Write(rows, path);

		GhostDb.ReadResult result = GhostDb.Read(path);
		Assert.Single(result.Rows);
		Assert.Equal(1, result.Rejected);
		Assert.Equal(1UL, result.Rows[0].SteamId);
	}

	[Fact]
	public void Read_throws_on_bad_magic()
	{
		string path = TempPath("badmagic");
		File.WriteAllBytes(path, new byte[] { (byte)'N', (byte)'O', (byte)'P', (byte)'E', 0, 0, 0, 0, 0, 0, 0, 0 });

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}

	[Fact]
	public void Read_throws_on_wrong_format_version()
	{
		string path = TempPath("badversion");
		byte[] bytes = new byte[12];
		bytes[0] = (byte)'B';
		bytes[1] = (byte)'G';
		bytes[2] = (byte)'D';
		bytes[3] = (byte)'B';
		bytes[4] = 2; // format_version = 2
		File.WriteAllBytes(path, bytes);

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}

	[Fact]
	public void Read_throws_on_truncated_file()
	{
		List<Entry> rows = new List<Entry> { Row(1, 5, "OCaa"), Row(2, 4, "OCbb") };
		string path = TempPath("truncated");
		GhostDb.Write(rows, path);
		byte[] bytes = File.ReadAllBytes(path);

		File.WriteAllBytes(path, bytes.AsSpan(0, 40).ToArray());

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}

	[Fact]
	public void Read_throws_on_huge_run_count()
	{
		// regression: run_count >= 2^31 used to OverflowException-crash instead of failing the merge
		string path = TempPath("hugeruncount");
		byte[] bytes = new byte[13];
		bytes[0] = (byte)'B';
		bytes[1] = (byte)'G';
		bytes[2] = (byte)'D';
		bytes[3] = (byte)'B';
		bytes[4] = 1; // format_version
		bytes[8] = 0x80; // run_count = 0x80000000
		File.WriteAllBytes(path, bytes);

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}

	[Fact]
	public void Read_throws_on_huge_blob_length()
	{
		// regression: comp_len >= 2^31 used to ArgumentOutOfRangeException-crash instead of failing the merge
		string path = TempPath("hugecomplen");
		byte[] bytes = new byte[51];
		bytes[0] = (byte)'B';
		bytes[1] = (byte)'G';
		bytes[2] = (byte)'D';
		bytes[3] = (byte)'B';
		bytes[4] = 1;  // format_version = 1
		bytes[8] = 1;  // run_count = 1
		bytes[12] = 0; // version_count = 0
		// steam_ids[0] @13..20, blob_offsets[0] @21..28 = 42, d_codes[0] @29, d_order @30..33, r_values @34..41
		bytes[21] = 42;
		// blob framing @42: comp_len = 0xFFFFFFFF, raw_len = 1
		bytes[42] = 0xFF;
		bytes[43] = 0xFF;
		bytes[44] = 0xFF;
		bytes[45] = 0xFF;
		bytes[46] = 1;
		File.WriteAllBytes(path, bytes);

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}
}
