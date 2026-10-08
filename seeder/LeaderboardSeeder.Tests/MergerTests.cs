using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: Merger.Merge — dedup + filter over rows read from ghost DBs.
public class MergerTests
{
	private static Entry Row(ulong steamId, double r, string d, string? metadata = null) =>
		new(steamId, 0, 0, r, d, metadata ?? "{\"d\":\"" + d + "\",\"r\":" +
			r.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"p\":\"P" + steamId + "\"}");

	private static (string Name, IReadOnlyList<Entry> Rows, int Rejected) Input(string name, int rejected, params Entry[] rows) =>
		(name, rows, rejected);

	[Fact]
	public void Merge_drops_identical_duplicate_across_inputs()
	{
		Entry shared = Row(1000, 50.0, "OCaa", "{\"d\":\"OCaa\",\"r\":50,\"p\":\"P\",\"0\":\"boardA\"}");
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, shared, Row(2000, 40.0, "OCbb")),
			Input("b.gdb", 1, Row(1000, 50.0, "OCaa", shared.Metadata), Row(3000, 30.0, "ODcc")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 0);

		Assert.Equal(new ulong[] { 1000, 2000, 3000 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(1, result.Inputs.Single(i => i.Name == "b.gdb").Duplicates);
		Assert.Equal(1, result.Inputs.Single(i => i.Name == "b.gdb").Rejected);
		Assert.Equal(3, result.Inputs.Single(i => i.Name == "b.gdb").Total); // 2 accepted + 1 rejected
		Assert.Equal(0, result.Inputs.Single(i => i.Name == "a.gdb").Duplicates);
	}

	[Fact]
	public void Merge_keeps_same_player_runs_with_different_boards()
	{
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 50.0, "OCaa", "{\"d\":\"OCaa\",\"r\":50,\"0\":\"boardA\"}")),
			Input("b.gdb", 0, Row(1000, 60.0, "ODbb", "{\"d\":\"ODbb\",\"r\":60,\"0\":\"boardB\"}")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 0);

		Assert.Equal(2, result.Kept.Count);
		Assert.All(result.Inputs, i => Assert.Equal(0, i.Duplicates));
	}

	[Fact]
	public void Merge_keeps_identical_metadata_from_distinct_players()
	{
		string metadata = "{\"d\":\"OCaa\",\"r\":50,\"0\":\"boardA\"}";
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 50.0, "OCaa", metadata)),
			Input("b.gdb", 0, Row(2000, 50.0, "OCaa", metadata)),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 0);

		Assert.Equal(2, result.Kept.Count);
	}

	[Fact]
	public void Merge_applies_keep_d_over_union_of_versions()
	{
		// union of version codes = {OC, OD, OE}; keepD 2 keeps the newest two
		// (ordinal OD, OE) and cuts every OC row.
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("old.gdb", 0, Row(1000, 50.0, "OCaa"), Row(1001, 40.0, "OCbb")),
			Input("new.gdb", 0, Row(2000, 30.0, "ODcc"), Row(3000, 20.0, "OEdd")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 2, minR: 0);

		Assert.All(result.Kept, e => Assert.False(e.D.StartsWith("OC"), "OC rows must be cut by the keep-d window"));
		Assert.Equal(2, result.WindowCut);
		Assert.Equal(2, result.Kept.Count);
	}

	[Fact]
	public void Merge_breaks_rating_ties_by_steam_id()
	{
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(42, 50.0, "OCaa"), Row(7, 50.0, "OCbb"), Row(100, 60.0, "OCcc")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 0);

		Assert.Equal(new ulong[] { 100, 7, 42 }, result.Kept.Select(e => e.SteamId));
	}

	[Fact]
	public void Merge_reapplies_rating_floor_over_union()
	{
		// Same floor as a seed run: rows below 60 cut even when every input
		// row survived its own DB; the row exactly at 60 stays.
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 55.0, "OCaa"), Row(1001, 60.0, "OCbb")),
			Input("b.gdb", 0, Row(2000, 70.0, "ODcc"), Row(3000, 40.0, "ODdd")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 60.0);

		Assert.Equal(new ulong[] { 2000, 1001 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(2, result.FloorCut);
	}

	[Fact]
	public void Merge_explicit_min_r_cuts_by_that_threshold()
	{
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 65.0, "OCaa"), Row(1001, 75.0, "ODbb")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 70.0);

		Assert.Equal(new ulong[] { 1001 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(1, result.FloorCut);
	}

	[Fact]
	public void Merge_of_precut_inputs_cuts_nothing_new()
	{
		// Idempotence: merging inputs already cut at 60.0 cuts nothing new,
		// so a same-day rerun over older merge outputs is a no-op on r.
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 60.0, "OCaa"), Row(1001, 80.0, "OCbb")),
			Input("b.gdb", 0, Row(1000, 60.0, "OCaa"), Row(2000, 90.0, "ODcc")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, minR: 60.0);

		Assert.Equal(3, result.Kept.Count);
		Assert.Equal(0, result.FloorCut);
	}
}

// Seam: Merger.RunMerge — folder scan, per-file read, write; console behavior excluded.
public class RunMergeTests
{
	private readonly StringWriter _log = new();
	private readonly StringWriter _err = new();

	private string TempFolder()
	{
		string dir = Path.Combine(Path.GetTempPath(), "bpb-runmerge", Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(dir);
		return dir;
	}

	private static Entry Row(ulong steamId, double r, string d) =>
		new(steamId, 0, 0, r, d, "{\"d\":\"" + d + "\",\"r\":" +
			r.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"p\":\"P" + steamId + "\"}");

	[Fact]
	public void RunMerge_fails_when_fewer_than_two_dbs()
	{
		DateOnly today = new(2026, 1, 10);
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1, 1, "OCaa") }, Path.Combine(dir, "only.gdb"));

		int code = Merger.RunMerge(dir, keepD: 4, minR: 60.0, _log, _err, today);

		Assert.Equal(1, code);
		Assert.Contains("at least 2", _err.ToString());
		Assert.False(File.Exists(Path.Combine(dir, GhostDb.MergeFileName(today))));
	}

	[Fact]
	public void RunMerge_fails_on_missing_folder()
	{
		int code = Merger.RunMerge(Path.Combine(TempFolder(), "nope"), 4, 60.0, _log, _err);

		Assert.Equal(1, code);
	}

	[Fact]
	public void RunMerge_same_day_rerun_excludes_existing_output_and_overwrites()
	{
		DateOnly today = new(2026, 1, 10);
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1000, 70.0, "OCaa"), Row(1001, 65.0, "OCbb") }, Path.Combine(dir, "a.gdb"));
		GhostDb.Write(new List<Entry> { Row(1000, 70.0, "OCaa"), Row(2000, 62.0, "ODcc") }, Path.Combine(dir, "b.gdb"));
		string output = Path.Combine(dir, "ghosts-merged-10-01-26.gdb");
		// A garbage same-day output must not poison the rerun: it is the
		// merge target, excluded from the input scan.
		File.WriteAllBytes(output, new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 });

		int code = Merger.RunMerge(dir, keepD: 4, minR: 60.0, _log, _err, today);

		Assert.Equal(0, code);
		GhostDb.ReadResult merged = GhostDb.Read(output);
		Assert.Equal(3, merged.Rows.Count); // 1000 deduped, 1001 + 2000 kept
		Assert.Contains("a.gdb", _log.ToString());
		Assert.Contains("b.gdb", _log.ToString());
		Assert.Contains("Excluding today's merge output", _log.ToString());
	}

	[Fact]
	public void RunMerge_merges_previous_output_with_new_dump()
	{
		// the user's chain: an older merge result is the only history left,
		// plus one fresh dump — that folder must merge without renaming;
		// only today's own output name is excluded from the scan
		DateOnly today = new(2026, 1, 10);
		DateOnly yesterday = today.AddDays(-1);
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1000, 70.0, "OCaa"), Row(1001, 65.0, "OCbb") },
			Path.Combine(dir, GhostDb.MergeFileName(yesterday)));
		GhostDb.Write(new List<Entry> { Row(2000, 62.0, "ODcc") }, Path.Combine(dir, "new.gdb"));

		int code = Merger.RunMerge(dir, keepD: 4, minR: 60.0, _log, _err, today);

		Assert.Equal(0, code);
		GhostDb.ReadResult merged = GhostDb.Read(Path.Combine(dir, GhostDb.MergeFileName(today)));
		Assert.Equal(3, merged.Rows.Count);
		Assert.Contains("ghosts-merged-09-01-26.gdb", _log.ToString());
	}

	[Fact]
	public void RunMerge_fails_whole_merge_on_corrupt_input()
	{
		DateOnly today = new(2026, 1, 10);
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1, 1, "OCaa") }, Path.Combine(dir, "good.gdb"));
		File.WriteAllBytes(Path.Combine(dir, "bad.gdb"), new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 });

		int code = Merger.RunMerge(dir, keepD: 4, minR: 60.0, _log, _err, today);

		Assert.Equal(1, code);
		Assert.Contains("bad.gdb", _err.ToString());
		Assert.False(File.Exists(Path.Combine(dir, GhostDb.MergeFileName(today))), "nothing must be written on failure");
	}

	[Fact]
	public void RunMerge_prints_floor_cut_next_to_window_line()
	{
		DateOnly today = new(2026, 1, 10);
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1000, 70.0, "OCaa"), Row(1001, 50.0, "OCbb") }, Path.Combine(dir, "a.gdb"));
		GhostDb.Write(new List<Entry> { Row(2000, 65.0, "ODcc") }, Path.Combine(dir, "b.gdb"));

		int code = Merger.RunMerge(dir, keepD: 4, minR: 60.0, _log, _err, today);

		Assert.Equal(0, code);
		Assert.Contains("Version window cut", _log.ToString());
		Assert.Contains("Rating floor 60 cut 1", _log.ToString());
	}
}
