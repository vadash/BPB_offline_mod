using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace LeaderboardSeeder;

// Deduplicates rows read from several ghost DBs and applies the seeder's
// filters (RunFilter) over the union. Output row order is rating order
// (r descending, steam id ascending on ties), which becomes the merged DB's
// dense-rank order.
internal static class Merger
{
	public sealed record InputReport(string Name, int Total, int Rejected, int Duplicates);

	public sealed record MergeResult(
		IReadOnlyList<Entry> Kept,
		IReadOnlyList<InputReport> Inputs,
		int WindowCut,
		int FloorCut);

	public static MergeResult Merge(IList<(string Name, IReadOnlyList<Entry> Rows, int Rejected)> inputs, int keepD, int cutBottom)
	{
		List<Entry> union = new List<Entry>();
		List<InputReport> reports = new List<InputReport>(inputs.Count);
		HashSet<(ulong SteamId, string Metadata)> seen = new HashSet<(ulong, string)>();
		foreach ((string name, IReadOnlyList<Entry> rows, int rejected) in inputs)
		{
			int duplicates = 0;
			foreach (Entry row in rows)
			{
				// duplicate = same steam id and byte-identical metadata text
				if (!seen.Add((row.SteamId, row.Metadata)))
				{
					duplicates++;
					continue;
				}
				union.Add(row);
			}
			reports.Add(new InputReport(name, rows.Count + rejected, rejected, duplicates));
		}

		HashSet<string> window = new HashSet<string>(RunFilter.VersionWindow(union.Select(e => e.D.Substring(0, 2)), keepD));
		List<Entry> inWindow = union.Where(e => window.Contains(e.D.Substring(0, 2))).ToList();
		int windowCut = union.Count - inWindow.Count;

		double floor = RunFilter.RatingFloor(inWindow.Select(e => e.R), cutBottom);
		List<Entry> kept = inWindow.Where(e => e.R >= floor).ToList();
		int floorCut = inWindow.Count - kept.Count;

		kept.Sort((a, b) =>
		{
			int byRating = b.R.CompareTo(a.R);
			return byRating != 0 ? byRating : a.SteamId.CompareTo(b.SteamId);
		});

		return new MergeResult(kept, reports, windowCut, floorCut);
	}

	// Folder orchestration: scan top-level *.gdb (skipping the merged output
	// itself), fail the whole merge on any unreadable input, write
	// <folder>/ghosts-merged.gdb atomically. Returns a process exit code.
	public static int RunMerge(string folder, int keepD, int cutBottom, TextWriter log, TextWriter err)
	{
		if (!Directory.Exists(folder))
		{
			err.WriteLine($"[ERR] Folder not found: {folder}");
			return 1;
		}
		string outputPath = Path.Combine(folder, GhostDb.MergeFileName);
		List<string> candidates;
		try
		{
			candidates = Directory.EnumerateFiles(folder, "*.gdb", SearchOption.TopDirectoryOnly)
				.Where(f => !string.Equals(Path.GetFileName(f), GhostDb.MergeFileName, StringComparison.OrdinalIgnoreCase))
				.OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal)
				.ToList();
		}
		catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
		{
			err.WriteLine($"[ERR] Cannot list {folder}: {ex.Message}");
			return 1;
		}
		if (candidates.Count < 2)
		{
			err.WriteLine($"[ERR] Need at least 2 ghost DBs to merge, found {candidates.Count} in {folder}:");
			foreach (string candidate in candidates)
			{
				err.WriteLine("      " + candidate);
			}
			return 1;
		}

		List<(string Name, IReadOnlyList<Entry> Rows, int Rejected)> inputs = new List<(string, IReadOnlyList<Entry>, int)>(candidates.Count);
		foreach (string file in candidates)
		{
			try
			{
				GhostDb.ReadResult read = GhostDb.Read(file);
				string name = Path.GetFileName(file);
				log.WriteLine($"[OK]  {name}: {read.Rows.Count:N0} rows, {read.Rejected} rejected.");
				inputs.Add((name, read.Rows, read.Rejected));
			}
			catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException)
			{
				err.WriteLine($"[ERR] {file}: {ex.Message}");
				err.WriteLine("[ERR] Failing the whole merge; nothing was written.");
				return 1;
			}
		}

		MergeResult result;
		int unionCount;
		int totalDuplicates;
		int totalRejected;
		try
		{
			result = Merge(inputs, keepD, cutBottom);
			unionCount = result.Kept.Count + result.WindowCut + result.FloorCut;
			totalDuplicates = result.Inputs.Sum(i => i.Duplicates);
			totalRejected = result.Inputs.Sum(i => i.Rejected);
			log.WriteLine($"[..] {unionCount:N0} unique rows across {inputs.Count} inputs, {totalDuplicates} duplicates, {totalRejected} rejected.");
			log.WriteLine($"[..] Version window cut {result.WindowCut:N0}, rating floor cut {result.FloorCut:N0}.");

			log.Write("[..] Writing " + outputPath + " ...");
			GhostDb.Write(result.Kept, outputPath, (done, total) =>
			{
				if (done % 10000 == 0)
				{
					log.Write($"\r[..] Writing {outputPath} ... [compressing {done:N0}/{total:N0}]   ");
				}
			});
		}
		catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
		{
			err.WriteLine($"\n[ERR] Merging or writing {outputPath} failed: {ex.Message}");
			err.WriteLine("[ERR] Failing the whole merge; the output was not updated.");
			return 1;
		}
		int n = result.Kept.Count;
		long length = new FileInfo(outputPath).Length;
		log.WriteLine($"\r[OK]  {n:N0} rows -> {outputPath} ({(double)length / 1048576.0:F1} MB).{new string(' ', 20)}");
		foreach (InputReport report in result.Inputs)
		{
			log.WriteLine($"     {report.Name}  total {report.Total,9:N0}  dup {report.Duplicates,9:N0}  rejected {report.Rejected,6:N0}");
		}
		return 0;
	}
}
