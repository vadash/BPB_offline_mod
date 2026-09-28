using System;
using System.IO;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Real-world fixture: the first 64 dense-rank rows of a genuine seeded dump.
// Regenerate where the dump exists (the author's machine); other environments
// consume the committed file.
public static class Fixture
{
	public const string RealDumpPath = @"R:\SteamLibrary\steamapps\common\Backpack Battles\ghosts_28_09_26.gdb";
	public const int PlayerCount = 64;
	public const string FileName = "ghosts-fixture-64.gdb";

	// committed artifact location (project dir); written by Regenerate_fixture_from_real_dump
	public static string SourcePath =>
		Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "Fixtures", FileName);

	// per-test-run copy shipped via CopyToOutputDirectory
	public static string OutputPath =>
		Path.Combine(AppContext.BaseDirectory, "Fixtures", FileName);
}

public class FixtureTests
{
	[Fact]
	public void Regenerate_fixture_from_real_dump()
	{
		// explicit opt-in: writes a tracked file, only where the real dump exists
		if (Environment.GetEnvironmentVariable("BPB_REGENERATE_FIXTURE") != "1" || !File.Exists(Fixture.RealDumpPath))
		{
			return;
		}

		GhostDb.ReadResult dump = GhostDb.Read(Fixture.RealDumpPath);
		System.Collections.Generic.List<Entry> chunk = dump.Rows.Take(Fixture.PlayerCount).ToList();

		Directory.CreateDirectory(Path.GetDirectoryName(Fixture.SourcePath)!);
		GhostDb.Write(chunk, Fixture.SourcePath);
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
		Assert.All(result.Rows, row => Assert.True(row.D.Length >= 2));
		// NOTE: file rank order is upstream leaderboard order and is NOT rating
		// order (verified against real data: scores ≠ r). The r_values array is
		// separately sorted descending by the writer.
	}
}
