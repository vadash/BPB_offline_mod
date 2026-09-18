using System;
using System.Collections.Generic;
using System.Linq;

namespace LeaderboardSeeder;

internal static class RunFilter
{
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
