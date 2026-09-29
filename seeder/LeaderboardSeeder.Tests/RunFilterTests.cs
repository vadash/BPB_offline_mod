using System;
using System.Collections.Generic;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: RunFilter.Admit — scrape admission over rank-ordered raw leaderboard entries.
public class AdmitTests
{
	private static LeaderboardEntryT Raw(ulong steamId, int rank, ulong workshopId) =>
		new() { m_steamIDUser = steamId, m_nGlobalRank = rank, m_hUGC = workshopId };

	private static IReadOnlyDictionary<ulong, string> Metadata(params (ulong WorkshopId, string Json)[] items) =>
		items.ToDictionary(i => i.WorkshopId, i => i.Json);

	[Fact]
	public void Admit_skips_no_workshop_missing_metadata_and_duplicate_steam_ids_in_order()
	{
		// Row 1 (workshop 0) must not consume steam id 1's dedup slot; row 3
		// (metadata missing) must consume steam id 2's slot so row 4 is dropped
		// even though its metadata is valid; steam id 3 keeps its first row.
		var raw = new List<LeaderboardEntryT>
		{
			Raw(1, 1, 0),
			Raw(1, 2, 11),
			Raw(2, 3, 10),
			Raw(2, 4, 12),
			Raw(3, 5, 13),
			Raw(3, 6, 14),
		};
		var metadata = Metadata(
			(11UL, "{\"r\":50,\"d\":\"OCaa\"}"),
			(12UL, "{\"r\":60,\"d\":\"ODbb\"}"),
			(13UL, "{\"r\":30,\"d\":\"OCcc\"}"),
			(14UL, "{\"r\":40,\"d\":\"ODdd\"}"));

		RunFilter.AdmitResult admit = RunFilter.Admit(raw, metadata);

		Assert.Equal(new Entry[]
		{
			new(1, 2, 11, 50.0, "OCaa", "{\"r\":50,\"d\":\"OCaa\"}"),
			new(3, 5, 13, 30.0, "OCcc", "{\"r\":30,\"d\":\"OCcc\"}"),
		}, admit.Candidates);
	}

	[Fact]
	public void Admit_counts_totals_per_code_ordinal_with_question_code()
	{
		// Rows without a usable version code count under "?" but never become
		// candidates; rows without numeric r or with unparseable JSON are not
		// counted at all.
		var raw = new List<LeaderboardEntryT>
		{
			Raw(4, 1, 15),
			Raw(5, 2, 16),
			Raw(6, 3, 17),
			Raw(7, 4, 18),
			Raw(8, 5, 19),
			Raw(9, 6, 20),
		};
		var metadata = Metadata(
			(15UL, "{\"r\":1.5}"),
			(16UL, "{\"r\":2,\"d\":\"OCx\"}"),
			(17UL, "{\"d\":\"ODbb\"}"),
			(18UL, "{\"r\":9,\"d\":42}"),
			(19UL, "{\"r\":7,\"d\":\"O\"}"),
			(20UL, "{\"r\":8,\"d\":\"OCy\"}"));

		RunFilter.AdmitResult admit = RunFilter.Admit(raw, metadata);

		Assert.Equal(new Entry[]
		{
			new(5, 2, 16, 2.0, "OCx", "{\"r\":2,\"d\":\"OCx\"}"),
			new(9, 6, 20, 8.0, "OCy", "{\"r\":8,\"d\":\"OCy\"}"),
		}, admit.Candidates);
		// ordinal: '?' (0x3F) sorts before letters
		Assert.Equal(new[] { ("?", 3, 0), ("OC", 2, 0) },
			admit.PerCode.Select(c => (c.Code, c.Total, c.Kept)));
	}

	[Fact]
	public void Admit_preserves_rank_order_and_counts_totals_per_code()
	{
		var raw = new List<LeaderboardEntryT>
		{
			Raw(1, 1, 11),
			Raw(2, 2, 12),
			Raw(3, 3, 13),
			Raw(4, 4, 14),
		};
		var metadata = Metadata(
			(11UL, "{\"r\":10,\"d\":\"OCa\"}"),
			(12UL, "{\"r\":20,\"d\":\"ODb\"}"),
			(13UL, "{\"r\":30,\"d\":\"OCc\"}"),
			(14UL, "{\"r\":40,\"d\":\"PEd\"}"));

		RunFilter.AdmitResult admit = RunFilter.Admit(raw, metadata);

		Assert.Equal(new ulong[] { 1, 2, 3, 4 }, admit.Candidates.Select(e => e.SteamId));
		Assert.Equal(new int[] { 1, 2, 3, 4 }, admit.Candidates.Select(e => e.OrigRank));
		Assert.Equal(new[] { ("OC", 2, 0), ("OD", 1, 0), ("PE", 1, 0) },
			admit.PerCode.Select(c => (c.Code, c.Total, c.Kept)));
	}
}

// Seam: RunFilter.Apply — dedup, version window, rating floor over candidate rows.
public class ApplyTests
{
	private static Entry Row(ulong steamId, double r, string d, string? metadata = null) =>
		new(steamId, 0, 0, r, d, metadata ?? "{\"d\":\"" + d + "\",\"r\":" +
			r.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");

	[Fact]
	public void Apply_seed_settings_windows_and_floors_in_input_order()
	{
		// Distinct codes {OA..OE}: keepD 4 cuts the one OA row; floor at
		// sorted[6*50/100] = 50 cuts the three rows below 50. Kept stays in
		// input order — Apply never sorts.
		var rows = new List<Entry>
		{
			Row(1, 10.0, "OAa"),
			Row(2, 20.0, "OBh"),
			Row(3, 30.0, "OCc"),
			Row(4, 40.0, "ODd"),
			Row(5, 50.0, "OEe"),
			Row(6, 60.0, "OEf"),
			Row(7, 70.0, "OBg"),
		};

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.None, RunFilter.FilterSettings.Seed);

		Assert.Equal(new ulong[] { 5, 6, 7 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(1, result.WindowCut);
		Assert.Equal(3, result.FloorCut);
		Assert.Equal(50.0, result.Floor);
		Assert.Empty(result.PerCode);
		Assert.Empty(result.InputDups);
	}

	[Fact]
	public void Apply_merge_settings_keep_everything()
	{
		var rows = new List<Entry>
		{
			Row(1, 10.0, "OAa"),
			Row(2, 20.0, "ODb"),
			Row(3, 30.0, "OCc"),
		};

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.None, RunFilter.FilterSettings.Merge);

		Assert.Equal(3, result.Kept.Count);
		Assert.Equal(0, result.WindowCut);
		Assert.Equal(0, result.FloorCut);
		Assert.Equal(double.NegativeInfinity, result.Floor);
	}

	[Fact]
	public void Apply_dedup_steam_id_first_wins_in_input_order()
	{
		var rows = new List<Entry> { Row(5, 50.0, "OCx"), Row(5, 60.0, "OCy"), Row(7, 40.0, "OCz") };

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.SteamId, RunFilter.FilterSettings.Merge);

		Assert.Equal(new ulong[] { 5, 7 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(50.0, result.Kept[0].R);
		Assert.Equal("OCx", result.Kept[0].D);
	}

	[Fact]
	public void Apply_dedup_steam_id_and_content_keeps_metadata_variants()
	{
		string m3 = "{\"d\":\"OCz\",\"r\":30}";
		var rows = new List<Entry>
		{
			Row(5, 50.0, "OCx", "{\"d\":\"OCx\",\"r\":50}"),
			Row(5, 60.0, "OCy", "{\"d\":\"OCy\",\"r\":60}"),
			Row(8, 30.0, "OCz", m3),
			Row(8, 35.0, "OCw", m3),
		};

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.SteamIdAndContent, RunFilter.FilterSettings.Merge);

		Assert.Equal(new ulong[] { 5, 5, 8 }, result.Kept.Select(e => e.SteamId));
	}

	[Fact]
	public void Apply_input_tags_count_duplicates_per_tag_in_encounter_order()
	{
		var rows = new List<Entry>
		{
			Row(5, 50, "OCa"), Row(5, 50, "OCa"), Row(5, 50, "OCa"), Row(6, 40, "OCb"), Row(7, 30, "OCc"),
		};
		var tags = new List<string?> { "b.gdb", "b.gdb", "a.gdb", "a.gdb", "b.gdb" };

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.SteamId, RunFilter.FilterSettings.Merge, tags);

		Assert.Equal(new ulong[] { 5, 6, 7 }, result.Kept.Select(e => e.SteamId));
		// first duplicate comes from b.gdb, then from a.gdb; the b.gdb repeat
		// after row 0 counts as a duplicate within one input too
		Assert.Equal(new[] { ("b.gdb", 1), ("a.gdb", 1) }, result.InputDups.Select(d => (d.Input, d.Duplicates)));
	}

	[Fact]
	public void Apply_without_dedup_or_input_tags_reports_no_duplicates()
	{
		var rows = new List<Entry> { Row(5, 50, "OCa"), Row(5, 60, "OCb") };
		var tags = new List<string?> { "a.gdb", "b.gdb" };

		RunFilter.FilterResult deduped = RunFilter.Apply(rows, RunFilter.Dedup.None, RunFilter.FilterSettings.Merge, tags);
		RunFilter.FilterResult untagged = RunFilter.Apply(rows, RunFilter.Dedup.SteamId, RunFilter.FilterSettings.Merge);

		Assert.Equal(2, deduped.Kept.Count);
		Assert.Empty(deduped.InputDups);
		Assert.Single(untagged.Kept);
		Assert.Empty(untagged.InputDups);
	}

	[Fact]
	public void Apply_updates_per_code_kept_from_totals()
	{
		var rows = new List<Entry> { Row(1, 10.0, "OCa"), Row(2, 20.0, "OCb"), Row(3, 30.0, "ODc") };
		var totals = new List<RunFilter.CodeStat> { new("OC", 2, 0), new("OD", 1, 0) };

		RunFilter.FilterResult result = RunFilter.Apply(rows, RunFilter.Dedup.None, RunFilter.FilterSettings.Seed, perCodeTotals: totals);

		// floor over [10,20,30] at 50% = sorted[1] = 20: the 10.0 row is cut
		Assert.Equal(new ulong[] { 2, 3 }, result.Kept.Select(e => e.SteamId));
		Assert.Equal(new[] { ("OC", 2, 1), ("OD", 1, 1) }, result.PerCode.Select(c => (c.Code, c.Total, c.Kept)));
		Assert.Equal(20.0, result.Floor);
	}

	[Fact]
	public void Apply_does_not_mutate_caller_supplied_totals()
	{
		var rows = new List<Entry> { Row(1, 10.0, "OCa") };
		var totals = new List<RunFilter.CodeStat> { new("OC", 1, 0) };

		RunFilter.Apply(rows, RunFilter.Dedup.None, RunFilter.FilterSettings.Merge, perCodeTotals: totals);

		Assert.Equal(0, totals[0].Kept);
	}
}
