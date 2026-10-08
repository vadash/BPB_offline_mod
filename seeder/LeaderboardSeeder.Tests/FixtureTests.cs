using System;
using System.IO;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Real-world fixture: the first 64 dense-rank rows of a genuine seeded dump.
// Regeneration re-emits the committed file's own rows through the production
// Read->Write path; other environments consume the committed file.
public static class Fixture
{
	public const int PlayerCount = 64;
	public const string FileName = "ghosts-fixture-64.gdb";

	// committed artifact location (project dir); written by Regenerate_fixture
	public static string SourcePath =>
		Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "Fixtures", FileName);

	// per-test-run copy shipped via CopyToOutputDirectory
	public static string OutputPath =>
		Path.Combine(AppContext.BaseDirectory, "Fixtures", FileName);
}

public class FixtureTests
{
	[Fact]
	public void Regenerate_fixture()
	{
		// Explicit opt-in: rewrites the tracked golden. Sources the committed
		// golden's rows through the production Read->Write path, so a
		// regeneration always emits exactly what the current writer produces
		// for those rows - no dependence on the machine that has the
		// original dump.
		if (Environment.GetEnvironmentVariable("BPB_REGENERATE_FIXTURE") != "1")
		{
			return;
		}

		GhostDb.ReadResult golden = GhostDb.Read(Fixture.SourcePath);

		Directory.CreateDirectory(Path.GetDirectoryName(Fixture.SourcePath)!);
		GhostDb.Write(golden.Rows, Fixture.SourcePath, ItemBook.Load());
	}

	[Fact]
	public void Golden_fixture_reads_with_wellformed_summaries()
	{
		int numItems = ItemBook.Load().NumItems;
		GhostDb.ReadResult result = GhostDb.Read(Fixture.OutputPath);

		Assert.Equal(2u, result.FormatVersion);
		Assert.Equal(0, result.Rejected);
		Assert.Equal(Fixture.PlayerCount, result.Rows.Count);
		Assert.Equal(Fixture.PlayerCount, result.Summaries.Count);
		for (int i = 0; i < result.Summaries.Count; i++)
		{
			GhostDb.RunSummary summary = result.Summaries[i];
			Assert.True(summary.Class is >= 0 and <= 6 || summary.Class == GhostDb.UnknownClass,
				$"summary {i}: class byte {summary.Class} outside 0..6/255");
			if (summary.Class == GhostDb.UnknownClass)
			{
				// header-undecodable runs carry defaults and an empty set
				Assert.True(summary.Undecodable, $"summary {i}: classless run must carry the undecodable marker");
				Assert.False(summary.Perfect, $"summary {i}: classless run cannot be perfect");
				Assert.Empty(summary.ItemIndexes);
			}
			int previous = -1;
			foreach (int index in summary.ItemIndexes)
			{
				Assert.True(index > previous, $"summary {i}: item indexes must be strictly ascending");
				Assert.True(index < numItems, $"summary {i}: item index {index} beyond num_items {numItems}");
				previous = index;
			}
		}
	}

	[Fact]
	public void Golden_fixture_rows_keep_their_dense_ranks()
	{
		GhostDb.ReadResult result = GhostDb.Read(Fixture.OutputPath);

		Assert.Equal(Fixture.PlayerCount, result.Rows.Count);
		Assert.All(result.Rows, row => Assert.True(row.D.Length >= 2));
		Assert.Equal(Enumerable.Range(1, Fixture.PlayerCount), result.Rows.Select(row => row.OrigRank));
	}

	[Fact]
	public void Fixture_holds_dense_top_ranks_without_rejects()
	{
		if (!File.Exists(Fixture.OutputPath))
		{
			return; // fixture not yet generated/committed
		}

		GhostDb.ReadResult result = GhostDb.Read(Fixture.OutputPath);

		Assert.Equal(Fixture.PlayerCount, result.Rows.Count);
		Assert.Equal(0, result.Rejected);
		Assert.Equal(2u, result.FormatVersion);
		Assert.All(result.Rows, row => Assert.True(row.D.Length >= 2));
		// NOTE: file rank order is upstream leaderboard order and is NOT rating
		// order (verified against real data: scores ≠ r). The r_values array is
		// separately sorted descending by the writer.
	}
}
