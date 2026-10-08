using System;
using System.Collections.Generic;

namespace LeaderboardSeeder;

// Port of the mod's Core/BoardDecoder.gd restricted to what the Ghost DB v2
// summary needs: the item descriptor INDEXES of one round (names never
// needed - ring persistence resolves through ItemBook by index), plus the
// run header decode from Utility/RunData.gd deserializeMetadata (entryVersion
// widths 2/4/6 bits, 18 x 2-bit results, class 3 bits on 1.0.0+ else 2 bits).
// A null return means "cannot decode" - the round/run contributes nothing and
// never an error, matching the mod's exclusion sweep.
internal static class BoardDecoder
{
	// Baked game constants (Game.MAX_HEALTH/MAX_STAMINA, Inventory 10x10);
	// first thing to re-check after a game update.
	private const int MaxHealth = 999;
	private const int MaxStamina = 999;
	private const int InventoryX = 10;
	private const int InventoryY = 10;
	private const int RoundResultSize = 4;   // Game.RoundResult: Win/Loss/Draw/RunOver
	private const int MaxRounds = 18;        // Game.MAX_ROUNDS
	private const int ClassesFullSize = 7;   // Game.Classes_Full (1.0.0+)
	private const int ClassesSize = 4;       // Game.Classes (legacy)
	public const int UnknownClass = 255;

	// Boards older than 1.1.0 encode item indexes against a fixed count.
	public const int LegacyNumItems = 510;

	// Descriptor indexes in stream order, or null when the round is invalid.
	public static List<int>? DecodeItemIndexes(string roundString, string entryVersion, ItemBook book)
	{
		BitStream bs = new();
		if (!bs.FromGodotString(roundString))
		{
			return null;
		}
		if (bs.Pull(MaxHealth) == -1 || bs.Pull(MaxStamina) == -1)
		{
			return null;
		}

		int numGems = book.NumGems;
		int gemRange = BinaryCeil(numGems + 1);
		int emptySocketId = gemRange - 1;

		int numItems = LaterOrEqual(entryVersion, "1.1.0") ? book.NumItems : LegacyNumItems;

		List<int> indexes = new();
		while (bs.BitsLeft() >= 8)
		{
			int index = bs.Pull(numItems);
			if (index == -1 || index >= numItems || !book.IsValid(index))
			{
				return null;
			}
			if (bs.Pull(InventoryX) == -1 || bs.Pull(InventoryY) == -1 || bs.Pull(4) == -1)
			{
				return null;
			}
			indexes.Add(index);

			int numSockets = book.Sockets(index);
			if (numSockets > 0)
			{
				int hasGems = bs.Pull(2);
				if (hasGems == -1)
				{
					return null;
				}
				if (hasGems == 1)
				{
					for (int socket = 0; socket < numSockets; socket++)
					{
						int gemIndex = bs.Pull(gemRange);
						if (gemIndex == -1)
						{
							return null;
						}
						if (gemIndex >= numGems && gemIndex != emptySocketId)
						{
							return null;
						}
					}
				}
			}

			// Exactly one item (Magic Ring) persists a blob of effects * 6
			// bits; every other index persists nothing.
			int effects = book.RingEffects(index);
			if (effects > 0 && bs.PullBitsize(effects * 6) == -1)
			{
				return null;
			}
		}
		return indexes;
	}

	public sealed record RunHeader(string EntryVersion, int[] Results, int Class);

	// Header of the packed d stream, or null on any decode failure (invalid
	// char, stream dry before results or class complete).
	public static RunHeader? DecodeHeader(string d)
	{
		BitStream bs = new();
		if (!bs.FromGodotString(d))
		{
			return null;
		}
		int major = bs.Pull(4);
		int minor = bs.Pull(16);
		int patch = bs.Pull(64);
		if (major == -1 || minor == -1 || patch == -1)
		{
			return null;
		}
		string entryVersion = major + "." + minor + "." + patch;
		int[] results = new int[MaxRounds];
		for (int i = 0; i < results.Length; i++)
		{
			results[i] = bs.Pull(RoundResultSize);
			if (results[i] == -1)
			{
				return null;
			}
		}
		int classWidth = LaterOrEqual(entryVersion, "1.0.0") ? ClassesFullSize : ClassesSize;
		int klass = bs.Pull(classWidth);
		if (klass == -1)
		{
			return null;
		}
		return new RunHeader(entryVersion, results, klass);
	}

	// Game parity: BitStream.binaryCeil = pow(2, ceil(log2(n))), float logs.
	private static int BinaryCeil(int number) =>
		(int)Math.Pow(2, Math.Ceiling(Math.Log(number) / Math.Log(2)));

	// Game parity: Util.laterOrEqual - numeric dot-part comparison; a version
	// with fewer parts than the baseline compares only its own parts.
	public static bool LaterOrEqual(string version, string baseline)
	{
		string[] parts = version.Split('.');
		string[] baseParts = baseline.Split('.');
		for (int i = 0; i < parts.Length; i++)
		{
			int part = ParseInt(parts[i]);
			int basePart = i < baseParts.Length ? ParseInt(baseParts[i]) : 0;
			if (part > basePart)
			{
				return true;
			}
			if (part < basePart)
			{
				return false;
			}
		}
		return true;
	}

	// GDScript int() parses to 0 on anything non-numeric.
	private static int ParseInt(string value) =>
		int.TryParse(value, out int parsed) ? parsed : 0;
}
