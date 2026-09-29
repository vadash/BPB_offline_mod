using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace LeaderboardSeeder;

internal static class RunFilter
{
	internal enum Dedup { None, SteamId, SteamIdAndContent }

	internal sealed record FilterSettings(int KeepD, int CutBottom)
	{
		internal static readonly FilterSettings Seed = new(4, 50);

		// Merge re-applies only the version window (same keep-d as a seed
		// run, walk-back from the union's newest code). The rating floor
		// never re-applies: inputs are already pre-cut.
		internal static FilterSettings Merge => ForMerge(Seed.KeepD);

		internal static FilterSettings ForMerge(int keepD) => new(keepD, 0);
	}

	internal sealed record CodeStat(string Code, int Total, int Kept);

	internal sealed record InputDup(string Input, int Duplicates);

	internal sealed record AdmitResult(IReadOnlyList<Entry> Candidates, IReadOnlyList<CodeStat> PerCode);

	internal sealed record FilterResult(IReadOnlyList<Entry> Kept, IReadOnlyList<CodeStat> PerCode,
		int WindowCut, int FloorCut, double Floor, IReadOnlyList<InputDup> InputDups);

	// Version code: first two characters of a run's `d` (see CONTEXT.md);
	// the rest of `d` is opaque packed bytes.
	private static string VersionCode(string? d) => d != null && d.Length >= 2 ? d.Substring(0, 2) : "?";

	// Scrape admission over the raw leaderboard, already ordered by rank.
	// Check order matters: the steam-id dedup fires before the metadata
	// lookup, so a player whose best-rank row has bad or missing metadata
	// is dropped entirely. "?"-code runs (no usable `d`) count toward their
	// code's total but never become candidates.
	internal static AdmitResult Admit(IReadOnlyList<LeaderboardEntryT> rankOrderedRaw,
		IReadOnlyDictionary<ulong, string> metadataMap)
	{
		List<Entry> candidates = new List<Entry>(rankOrderedRaw.Count);
		Dictionary<string, CodeStat> byCode = new Dictionary<string, CodeStat>(StringComparer.Ordinal);
		HashSet<ulong> seen = new HashSet<ulong>();
		for (int i = 0; i < rankOrderedRaw.Count; i++)
		{
			LeaderboardEntryT raw = rankOrderedRaw[i];
			if (raw.m_hUGC == 0 || !seen.Add(raw.m_steamIDUser) || !metadataMap.TryGetValue(raw.m_hUGC, out string? metadata))
			{
				continue;
			}
			double r;
			string? d = null;
			try
			{
				using JsonDocument jsonDocument = JsonDocument.Parse(metadata);
				JsonElement rootElement = jsonDocument.RootElement;
				if (!rootElement.TryGetProperty("r", out JsonElement rValue) || rValue.ValueKind != JsonValueKind.Number)
				{
					continue;
				}
				r = rValue.GetDouble();
				if (rootElement.TryGetProperty("d", out JsonElement dValue) && dValue.ValueKind == JsonValueKind.String)
				{
					d = dValue.GetString();
				}
			}
			catch
			{
				continue;
			}
			string code = VersionCode(d);
			if (!byCode.TryGetValue(code, out CodeStat? stat))
			{
				byCode[code] = stat = new CodeStat(code, 0, 0);
			}
			byCode[code] = stat with { Total = stat.Total + 1 };
			if (code == "?")
			{
				continue;
			}
			candidates.Add(new Entry(raw.m_steamIDUser, raw.m_nGlobalRank, raw.m_hUGC, r, d!, metadata));
		}
		List<CodeStat> perCode = byCode.OrderBy(s => s.Key, StringComparer.Ordinal).Select(s => s.Value).ToList();
		return new AdmitResult(candidates, perCode);
	}

	// Shared pipeline: optional dedup, then version window, then rating
	// floor. Never sorts; row order in equals Kept order out. Runs without a
	// usable version code were already excluded at admission, so every row
	// here has a two-character code.
	internal static FilterResult Apply(IReadOnlyList<Entry> rows, Dedup dedup, FilterSettings settings,
		IReadOnlyList<string>? inputTags = null, IReadOnlyList<CodeStat>? perCodeTotals = null)
	{
		if (inputTags is not null && inputTags.Count != rows.Count)
		{
			throw new ArgumentException("Input tags must pair 1:1 with rows.", nameof(inputTags));
		}
		List<CodeStat> perCode;
		Dictionary<string, int>? perCodeSlot = null;
		if (perCodeTotals is null)
		{
			perCode = new List<CodeStat>();
		}
		else
		{
			perCode = perCodeTotals.ToList();
			perCodeSlot = new Dictionary<string, int>(perCode.Count, StringComparer.Ordinal);
			for (int i = 0; i < perCode.Count; i++)
			{
				perCodeSlot[perCode[i].Code] = i;
			}
		}
		List<InputDup> inputDups = new List<InputDup>();
		Dictionary<string, int>? dupSlot = inputTags is null ? null : new Dictionary<string, int>(StringComparer.Ordinal);
		HashSet<ulong>? seenIds = dedup == Dedup.SteamId ? new HashSet<ulong>() : null;
		HashSet<(ulong SteamId, string Metadata)>? seenIdContent =
			dedup == Dedup.SteamIdAndContent ? new HashSet<(ulong, string)>() : null;
		List<Entry> survivors = new List<Entry>(rows.Count);
		for (int i = 0; i < rows.Count; i++)
		{
			Entry row = rows[i];
			bool duplicate = dedup switch
			{
				Dedup.SteamId => !seenIds!.Add(row.SteamId),
				// duplicate = same steam id and byte-identical metadata text
				Dedup.SteamIdAndContent => !seenIdContent!.Add((row.SteamId, row.Metadata)),
				_ => false,
			};
			if (duplicate)
			{
				if (dupSlot is not null)
				{
					string tag = inputTags![i];
					if (!dupSlot.TryGetValue(tag, out int slot))
					{
						dupSlot[tag] = slot = inputDups.Count;
						inputDups.Add(new InputDup(tag, 0));
					}
					inputDups[slot] = inputDups[slot] with { Duplicates = inputDups[slot].Duplicates + 1 };
				}
				continue;
			}
			survivors.Add(row);
		}

		HashSet<string> window = new HashSet<string>(VersionWindow(survivors.Select(e => VersionCode(e.D)), settings.KeepD));
		List<Entry> inWindow = survivors.Where(e => window.Contains(VersionCode(e.D))).ToList();
		int windowCut = survivors.Count - inWindow.Count;

		double floor = RatingFloor(inWindow.Select(e => e.R), settings.CutBottom);
		List<Entry> kept = new List<Entry>(inWindow.Count);
		int floorCut = 0;
		foreach (Entry row in inWindow)
		{
			if (row.R >= floor)
			{
				if (perCodeSlot is not null && perCodeSlot.TryGetValue(VersionCode(row.D), out int slot))
				{
					perCode[slot] = perCode[slot] with { Kept = perCode[slot].Kept + 1 };
				}
				kept.Add(row);
			}
			else
			{
				floorCut++;
			}
		}
		return new FilterResult(kept, perCode, windowCut, floorCut, floor, inputDups);
	}

	public static string[] VersionWindow(IEnumerable<string> codes, int keep)
	{
		string[] distinct = codes.Distinct().OrderBy(c => c, StringComparer.Ordinal).ToArray();
		if (keep >= distinct.Length)
		{
			return distinct;
		}
		string[] window = new string[keep];
		Array.Copy(distinct, distinct.Length - keep, window, 0, keep);
		return window;
	}

	public static double RatingFloor(IEnumerable<double> ratings, int percent)
	{
		if (percent <= 0)
		{
			return double.NegativeInfinity;
		}
		double[] sorted = ratings.OrderBy(r => r).ToArray();
		if (sorted.Length == 0)
		{
			return double.NegativeInfinity;
		}
		// at most index = n*P/100 rows sort strictly below sorted[index], so ties at the threshold keep cut <= P%
		int index = (int)((long)sorted.Length * percent / 100);
		if (index >= sorted.Length)
		{
			index = sorted.Length - 1;
		}
		return sorted[index];
	}
}
