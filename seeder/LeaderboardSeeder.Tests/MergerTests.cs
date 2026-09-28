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

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, cutBottom: 0);

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

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, cutBottom: 0);

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

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, cutBottom: 0);

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

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 2, cutBottom: 0);

		Assert.All(result.Kept, e => Assert.False(e.D.StartsWith("OC"), "OC rows must be cut by the keep-d window"));
		Assert.Equal(2, result.WindowCut);
		Assert.Equal(2, result.Kept.Count);
	}

	[Fact]
	public void Merge_applies_rating_floor_and_orders_by_rating_desc()
	{
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(1000, 10.0, "OCaa"), Row(1001, 20.0, "OCbb"), Row(1002, 30.0, "OCcc"), Row(1003, 40.0, "OCdd")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, cutBottom: 25);

		// floor = sorted[4*25/100] = 20; R >= floor survives
		Assert.Equal(new ulong[] { 1003, 1002, 1001 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(1, result.FloorCut);
	}

	[Fact]
	public void Merge_breaks_rating_ties_by_steam_id()
	{
		var inputs = new List<(string, IReadOnlyList<Entry>, int)>
		{
			Input("a.gdb", 0, Row(42, 50.0, "OCaa"), Row(7, 50.0, "OCbb"), Row(100, 60.0, "OCcc")),
		};

		Merger.MergeResult result = Merger.Merge(inputs, keepD: 4, cutBottom: 0);

		Assert.Equal(new ulong[] { 100, 7, 42 }, result.Kept.Select(e => e.SteamId));
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
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1, 1, "OCaa") }, Path.Combine(dir, "only.gdb"));

		int code = Merger.RunMerge(dir, keepD: 4, cutBottom: 25, _log, _err);

		Assert.Equal(1, code);
		Assert.Contains("at least 2", _err.ToString());
		Assert.False(File.Exists(Path.Combine(dir, GhostDb.MergeFileName)));
	}

	[Fact]
	public void RunMerge_fails_on_missing_folder()
	{
		int code = Merger.RunMerge(Path.Combine(TempFolder(), "nope"), 4, 25, _log, _err);

		Assert.Equal(1, code);
	}

	[Fact]
	public void RunMerge_merges_skips_own_output_and_overwrites()
	{
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1000, 50.0, "OCaa"), Row(1001, 40.0, "OCbb") }, Path.Combine(dir, "a.gdb"));
		GhostDb.Write(new List<Entry> { Row(1000, 50.0, "OCaa"), Row(2000, 30.0, "ODcc") }, Path.Combine(dir, "b.gdb"));

		int first = Merger.RunMerge(dir, keepD: 4, cutBottom: 0, _log, _err);
		Assert.Equal(0, first);
		string output = Path.Combine(dir, GhostDb.MergeFileName);
		GhostDb.ReadResult merged = GhostDb.Read(output);
		Assert.Equal(3, merged.Rows.Count); // 1000 deduped, 1001 + 2000 kept

		// second run: output must not feed itself; overwrite succeeds
		int second = Merger.RunMerge(dir, keepD: 4, cutBottom: 0, _log, _err);
		Assert.Equal(0, second);
		merged = GhostDb.Read(output);
		Assert.Equal(3, merged.Rows.Count);
		Assert.Contains("a.gdb", _log.ToString());
		Assert.Contains("b.gdb", _log.ToString());
		Assert.DoesNotContain("ghosts-merged.gdb:", _log.ToString().Replace("-> " + Path.Combine(dir, GhostDb.MergeFileName), ""));
	}

	[Fact]
	public void RunMerge_fails_whole_merge_on_corrupt_input()
	{
		string dir = TempFolder();
		GhostDb.Write(new List<Entry> { Row(1, 1, "OCaa") }, Path.Combine(dir, "good.gdb"));
		File.WriteAllBytes(Path.Combine(dir, "bad.gdb"), new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 });

		int code = Merger.RunMerge(dir, keepD: 4, cutBottom: 25, _log, _err);

		Assert.Equal(1, code);
		Assert.Contains("bad.gdb", _err.ToString());
		Assert.False(File.Exists(Path.Combine(dir, GhostDb.MergeFileName)), "nothing must be written on failure");
	}
}
