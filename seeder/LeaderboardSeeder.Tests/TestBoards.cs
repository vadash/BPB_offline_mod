using System;
using System.Collections.Generic;
using System.Linq;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Test-side inverse of LeaderboardSeeder's BitStream, ported from the mod's
// tests/bit_writer.gd: builds the Godot string encoding of a bit stream the
// way the game writes boards. Push mirrors BitStream.Pull: ceil(log2 n) bits,
// MSB first, no bits for rangeMax <= 1. ToGodotString packs the bits 6 per
// char as chr(v + 62), zero-padding the final char - exactly what
// BitStream.FromGodotString reads back.
internal sealed class TestBitWriter
{
	private const int Base64Offset = 62;

	public List<int> Bits { get; } = new();

	public void Push(int value, int rangeMax)
	{
		if (rangeMax <= 1)
		{
			return;
		}
		PushBitsize(value, NumBits(rangeMax));
	}

	public void PushBitsize(int value, int numBits)
	{
		for (int digit = numBits - 1; digit >= 0; digit--)
		{
			Bits.Add((value >> digit) & 1);
		}
	}

	public string ToGodotString()
	{
		List<int> padded = new(Bits);
		while (padded.Count % 6 != 0)
		{
			padded.Add(0);
		}
		char[] chars = new char[padded.Count / 6];
		for (int i = 0; i < padded.Count; i += 6)
		{
			int v = 0;
			for (int b = 0; b < 6; b++)
			{
				v = (v << 1) | padded[i + b];
			}
			chars[i / 6] = (char)(v + Base64Offset);
		}
		return new string(chars);
	}

	// Game parity: same expression as BitStream's width formula.
	public static int NumBits(int rangeMax) => (int)Math.Ceiling(Math.Log(rangeMax) / Math.Log(2));
}

// One board item as the game writes it: descriptor index, inventory cell,
// per-item field, and the gem indexes when the item has sockets.
internal sealed record TestItem(int Index, int X, int Y, int Face, int[] Gems);

// Encodes synthetic rounds and run headers exactly the way the game writes
// them, mirroring the mod's run_tests.gd encode_round/encode-header shaping,
// so decoder tests pin every format constant at the public seam: health and
// stamina range 999, item index width (num_items now, 510 legacy), 10x10
// inventory cells, the 2-bit per-item field, gem range binary_ceil
// (num_gems + 1) = 64, Magic Ring's 12-bit persistence blob, entryVersion
// widths 2/4/6 bits, 18 x 2-bit results, class 3 bits (2 on legacy versions).
internal static class TestBoards
{
	// Pinned dump facts (mod/tests/fixtures/item_book_dump.json).
	public const int NumItems = 519;
	public const int LegacyNumItems = 510;
	public const int NumGems = 34;
	public const int WoodenSword = 1;
	public const int RibSawBlade = 43;
	public const int SceneLess = 331;      // Book of Ice New, no scene
	public const int MagicRing = 505;      // effects 2 => 12-bit blob
	public const int SuperiorRing = 506;   // effects 3, persists nothing

	public static string EncodeRound(ItemBook book, int numItems, params TestItem[] specs)
	{
		TestBitWriter w = new();
		w.Push(123, 999);
		w.Push(456, 999);
		foreach (TestItem spec in specs)
		{
			w.Push(spec.Index, numItems);
			w.Push(spec.X, 10);
			w.Push(spec.Y, 10);
			w.Push(spec.Face, 4);
			if (spec.Index >= 0 && spec.Index < book.NumItems)
			{
				if (book.Sockets(spec.Index) > 0)
				{
					if (spec.Gems.Length > 0)
					{
						w.Push(1, 2);
						foreach (int gem in spec.Gems)
						{
							w.Push(gem, 64);
						}
					}
					else
					{
						w.Push(0, 2);
					}
				}
				if (book.RingEffects(spec.Index) > 0)
				{
					w.PushBitsize((1 << 12) - 1, 12);
				}
			}
		}
		// Real boards end with the 6-bit char padding only, so the reader's
		// item loop stops; pad the same way.
		while (w.Bits.Count % 6 != 0)
		{
			w.PushBitsize(0, 1);
		}
		return w.ToGodotString();
	}

	public static string EncodeHeader(string version, int[] results, int klass)
	{
		int[] parts = version.Split('.').Select(int.Parse).ToArray();
		TestBitWriter w = new();
		w.Push(parts[0], 4);
		w.Push(parts[1], 16);
		w.Push(parts[2], 64);
		foreach (int result in results)
		{
			w.Push(result, 4);
		}
		w.Push(klass, LaterOrEqualOneZeroZero(parts) ? 7 : 4);
		return w.ToGodotString();
	}

	private static bool LaterOrEqualOneZeroZero(int[] parts)
	{
		int[] baseline = { 1, 0, 0 };
		for (int i = 0; i < parts.Length; i++)
		{
			int basePart = i < baseline.Length ? baseline[i] : 0;
			if (parts[i] > basePart)
			{
				return true;
			}
			if (parts[i] < basePart)
			{
				return false;
			}
		}
		return true;
	}
}

public class TestBoardsTests
{
	// Meta-test: the writer round-trips through the production BitStream, so
	// encoder drift breaks loudly here instead of inside every decoder test.
	[Fact]
	public void Encoded_round_reads_back_through_production_decoder()
	{
		ItemBook book = ItemBook.Load();
		string round = TestBoards.EncodeRound(book, TestBoards.NumItems,
			new TestItem(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 }),
			new TestItem(0, 1, 2, 2, Array.Empty<int>()));

		Assert.Equal(new[] { TestBoards.WoodenSword, 0 }, BoardDecoder.DecodeItemIndexes(round, "1.1.8", book));
	}

	[Fact]
	public void Encoded_header_reads_back_through_production_decoder()
	{
		int[] results = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 3 };

		BoardDecoder.RunHeader? header = BoardDecoder.DecodeHeader(TestBoards.EncodeHeader("1.1.6", results, 2));

		Assert.NotNull(header);
		Assert.Equal("1.1.6", header!.EntryVersion);
		Assert.Equal(results, header.Results);
		Assert.Equal(2, header.Class);
	}
}
