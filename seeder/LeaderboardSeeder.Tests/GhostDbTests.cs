using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: the BGDB v2 file surface (GhostDb.Write / GhostDb.Read), per docs/ghost-db-format.md.
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

	private static readonly ItemBook Book = ItemBook.Load();

	private static string MetadataWithBoards(ulong steamId, double r, string d, params (string Key, string Board)[] boards)
	{
		string json = "{\"d\":\"" + d + "\",\"r\":" + r.ToString(System.Globalization.CultureInfo.InvariantCulture)
			+ ",\"p\":\"P" + steamId + "\",\"id\":\"id" + steamId + "\"";
		foreach ((string key, string board) in boards)
		{
			json += ",\"" + key + "\":\"" + board + "\"";
		}
		return json + "}";
	}

	private static Entry Row(ulong steamId, double r, string d, string metadata) => new(steamId, 0, 0, r, d, metadata);

	// A decodable run header for synthetic rows; results default to a mixed
	// non-perfect spread unless overridden.
	private static string Header(int[]? results = null, int klass = 2, string version = "1.1.6") =>
		TestBoards.EncodeHeader(version, results ?? new[] { 1, 0, 2, 1, 0, 2, 1, 0, 2, 1, 3, 3, 3, 3, 3, 3, 3, 3 }, klass);

	private static readonly int[] PerfectResults = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 3 };


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

		GhostDb.Write(rows, path, Book);

		GhostDb.ReadResult result = GhostDb.Read(path);
		Assert.Equal(0, result.Rejected);
		Assert.Equal(rows.Count, result.Rows.Count);
		Assert.Equal(rows.Select(e => e.SteamId), result.Rows.Select(e => e.SteamId));
		Assert.Equal(rows.Select(e => e.Metadata), result.Rows.Select(e => e.Metadata));
		Assert.Equal(rows.Select(e => e.R), result.Rows.Select(e => e.R));
		Assert.Equal(rows.Select(e => e.D), result.Rows.Select(e => e.D));
	}

	[Fact]
	public void File_names_carry_zero_padded_dd_MM_yy_date()
	{
		DateOnly date = new(2026, 10, 4);
		DateOnly singleDigit = new(2026, 1, 5);

		Assert.Equal("ghosts-04-10-26.gdb", GhostDb.SeedFileName(date));
		Assert.Equal("ghosts-merged-04-10-26.gdb", GhostDb.MergeFileName(date));
		Assert.Equal("ghosts-05-01-26.gdb", GhostDb.SeedFileName(singleDigit));
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

		GhostDb.Write(rows, path, Book);

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
		// Strict v2: v1 is retired with the summary-carrying layout; 3 is the
		// next unknown. Both must fail the schema gate itself (the header is
		// otherwise well-formed and empty, so no later framing guard can
		// throw in its place).
		foreach (uint version in new uint[] { 1, 3 })
		{
			string path = TempPath("badversion" + version);
			byte[] bytes = new byte[13];
			bytes[0] = (byte)'B';
			bytes[1] = (byte)'G';
			bytes[2] = (byte)'D';
			bytes[3] = (byte)'B';
			bytes[4] = (byte)version; // format_version
			bytes[8] = 0;             // run_count = 0
			bytes[12] = 0;            // version_count = 0
			File.WriteAllBytes(path, bytes);

			InvalidDataException ex = Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
			Assert.Contains($"unsupported format_version {version}", ex.Message);
		}
	}

	[Fact]
	public void Read_throws_on_truncated_file()
	{
		List<Entry> rows = new List<Entry> { Row(1, 5, "OCaa"), Row(2, 4, "OCbb") };
		string path = TempPath("truncated");
		GhostDb.Write(rows, path, Book);
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
		bytes[4] = 2; // format_version
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
		bytes[4] = 2;  // format_version = 2
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

	[Fact]
	public void Read_throws_on_overflowing_summary_varints()
	{
		// regression: a corrupt summary record used to OverflowException-crash instead of failing the merge
		string path = TempPath("hugegap");
		byte[] bytes = new byte[69];
		bytes[0] = (byte)'B';
		bytes[1] = (byte)'G';
		bytes[2] = (byte)'D';
		bytes[3] = (byte)'B';
		bytes[4] = 2;  // format_version = 2
		bytes[8] = 1;  // run_count = 1
		bytes[12] = 1; // version_count = 1
		bytes[13] = (byte)'O';
		bytes[14] = (byte)'C';
		// steam_ids[0] @15..22, blob_offsets[0] @23..30 = 61, d_codes[0] @31, d_order[0] @32..35, r_values[0] @36..43
		bytes[23] = 61;
		// summary_offsets[0] @44..51 = 52
		bytes[44] = 52;
		bytes[52] = 0; // class
		bytes[53] = 0; // flags
		bytes[54] = 2; // item count = 2
		bytes[55] = 0xFF;
		bytes[56] = 0xFF;
		bytes[57] = 0xFF;
		bytes[58] = 0xFF;
		bytes[59] = 0x07; // first index = 0x7FFFFFFF
		bytes[60] = 2;    // gap overflows the int accumulator
		// blob framing @61: comp_len = 0, raw_len = 0
		File.WriteAllBytes(path, bytes);

		Assert.Throws<InvalidDataException>(() => GhostDb.Read(path));
	}

	[Fact]
	public void V2_write_read_round_trip_preserves_rows_and_exposes_summaries()
	{
		string d = Header();
		List<Entry> rows = new List<Entry>
		{
			Row(111, 100.5, d, MetadataWithBoards(111, 100.5, d,
				("0", TestBoards.EncodeRound(Book, TestBoards.NumItems, new TestItem(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 }))))),
			Row(222, 90.0, Header(klass: 5), MetadataWithBoards(222, 90.0, Header(klass: 5))),
		};
		string path = TempPath("v2roundtrip");

		GhostDb.Write(rows, path, Book);

		GhostDb.ReadResult result = GhostDb.Read(path);
		Assert.Equal(2u, result.FormatVersion);
		Assert.Equal(0, result.Rejected);
		Assert.Equal(rows.Select(e => e.SteamId), result.Rows.Select(e => e.SteamId));
		Assert.Equal(rows.Select(e => e.Metadata), result.Rows.Select(e => e.Metadata));
		Assert.Equal(rows.Count, result.Summaries.Count);
	}

	[Fact]
	public void V2_summary_flags_perfect_run()
	{
		string d = Header(PerfectResults);
		string path = TempPath("v2perfect");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d)) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.True(summary.Perfect);
		Assert.False(summary.Undecodable);
		Assert.Equal(2, summary.Class);
		Assert.Empty(summary.ItemIndexes);
	}

	[Fact]
	public void V2_summary_later_loss_is_not_perfect()
	{
		int[] results = (int[])PerfectResults.Clone();
		results[5] = 1;
		string d = Header(results);
		string path = TempPath("v2beaten");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d)) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.False(summary.Perfect);
		Assert.False(summary.Undecodable);
	}

	[Fact]
	public void V2_summary_draw_in_first_ten_is_not_perfect()
	{
		int[] results = (int[])PerfectResults.Clone();
		results[9] = 2;
		string d = Header(results);
		string path = TempPath("v2drawn");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d)) }, path, Book);

		Assert.False(GhostDb.Read(path).Summaries.Single().Perfect);
	}

	[Fact]
	public void V2_summary_short_header_marks_undecodable_with_defaults()
	{
		// Version only: the results loop runs dry.
		TestBitWriter w = new();
		w.Push(1, 4);
		w.Push(1, 16);
		w.Push(6, 64);
		string d = w.ToGodotString();
		string path = TempPath("v2shortheader");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d,
			("0", TestBoards.EncodeRound(Book, TestBoards.NumItems, new TestItem(0, 1, 2, 2, Array.Empty<int>()))))) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.Equal(GhostDb.UnknownClass, summary.Class);
		Assert.False(summary.Perfect);
		Assert.True(summary.Undecodable);
		Assert.Empty(summary.ItemIndexes);
	}

	[Fact]
	public void V2_summary_invalid_header_chars_mark_undecodable()
	{
		string path = TempPath("v2badheader");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, "~~", MetadataWithBoards(1, 100.0, "~~")) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.Equal(GhostDb.UnknownClass, summary.Class);
		Assert.True(summary.Undecodable);
		Assert.Empty(summary.ItemIndexes);
	}

	[Fact]
	public void V2_summary_board_failure_marks_but_keeps_decoded_rounds_items()
	{
		string d = Header();
		string woodenSword = TestBoards.EncodeRound(Book, TestBoards.NumItems,
			new TestItem(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 }));
		string path = TempPath("v2badboard");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d, ("0", "~"), ("7", woodenSword))) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.True(summary.Undecodable);
		Assert.Equal(new[] { TestBoards.WoodenSword }, summary.ItemIndexes);
		Assert.Equal(2, summary.Class);
	}

	[Fact]
	public void V2_summary_absent_boards_leave_no_marker()
	{
		string d = Header();
		string path = TempPath("v2nobards");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d)) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.False(summary.Undecodable);
		Assert.Empty(summary.ItemIndexes);
	}

	[Fact]
	public void V2_summary_unions_items_across_rounds_and_dedupes()
	{
		string d = Header();
		string twoSwords = TestBoards.EncodeRound(Book, TestBoards.NumItems,
			new TestItem(TestBoards.WoodenSword, 1, 2, 1, Array.Empty<int>()),
			new TestItem(TestBoards.WoodenSword, 5, 6, 0, Array.Empty<int>()));
		string stone = TestBoards.EncodeRound(Book, TestBoards.NumItems,
			new TestItem(0, 3, 4, 2, Array.Empty<int>()));
		string path = TempPath("v2union");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, MetadataWithBoards(1, 100.0, d, ("0", twoSwords), ("17", stone))) }, path, Book);

		Assert.Equal(new[] { 0, TestBoards.WoodenSword }, GhostDb.Read(path).Summaries.Single().ItemIndexes);
	}

	[Fact]
	public void V2_summary_unparseable_metadata_keeps_header_class_without_marker()
	{
		string d = Header();
		string path = TempPath("v2badjson");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, "{not json") }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.Equal(2, summary.Class);
		Assert.False(summary.Undecodable);
		Assert.Empty(summary.ItemIndexes);
	}

	[Fact]
	public void V2_summary_non_string_board_value_marks_undecodable_but_keeps_other_rounds()
	{
		string d = Header();
		string woodenSword = TestBoards.EncodeRound(Book, TestBoards.NumItems,
			new TestItem(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 }));
		string metadata = "{\"d\":\"" + d + "\",\"r\":100,\"p\":\"P1\",\"id\":\"id1\",\"0\":5,\"7\":\"" + woodenSword + "\"}";
		string path = TempPath("v2nonstringboard");
		GhostDb.Write(new List<Entry> { Row(1, 100.0, d, metadata) }, path, Book);

		GhostDb.RunSummary summary = GhostDb.Read(path).Summaries.Single();

		Assert.True(summary.Undecodable);
		Assert.Equal(new[] { TestBoards.WoodenSword }, summary.ItemIndexes);
	}
}
