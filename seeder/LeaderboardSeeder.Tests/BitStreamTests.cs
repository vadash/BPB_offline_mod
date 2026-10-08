using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: BitStream, the faithful port of the mod's Core/BitStream.gd. Pins
// mirror the mod's test_bitstream_port plus the width table the board format
// depends on.
public class BitStreamTests
{
	[Fact]
	public void Pull_consumes_width_bits_MSB_first()
	{
		// "^A" encodes bits [1,0,0,0,0,0, 0,0,0,0,1,1] via 6-bit-per-char, offset 62.
		BitStream bs = new();
		Assert.True(bs.FromGodotString("^A"));
		Assert.Equal(512, bs.Pull(999));
		Assert.Equal(2, bs.BitsLeft());
		Assert.Equal(0, bs.Pull(1));
		Assert.Equal(3, bs.Pull(4));
		Assert.Equal(0, bs.BitsLeft());
		Assert.Equal(-1, bs.Pull(2));
	}

	[Fact]
	public void Empty_stream_is_safe()
	{
		BitStream fresh = new();
		Assert.Equal(0, fresh.Pull(1));
		Assert.Equal(-1, fresh.Pull(999));
	}

	[Fact]
	public void Non_6bit_characters_are_rejected()
	{
		Assert.False(new BitStream().FromGodotString("~")); // offset 64
		Assert.False(new BitStream().FromGodotString("!")); // offset below 0
	}

	[Fact]
	public void Width_table_matches_the_game_formula()
	{
		// (rangeMax, expected width in bits), pinned from the game parity
		// ceil(log(rangeMax)/log(2)): health/stamina 999 -> 10, num_items
		// 519/510 -> 10/9, gem range 64 -> 6, version 16 -> 4, cells 10 -> 4,
		// classes_full 7 -> 3, results/results-range 4 -> 2, bits 2 -> 1.
		(int RangeMax, int Width)[] table = { (999, 10), (519, 10), (510, 9), (64, 6), (16, 4), (10, 4), (7, 3), (4, 2), (2, 1) };
		foreach ((int rangeMax, int width) in table)
		{
			TestBitWriter w = new();
			w.PushBitsize(0, 30); // 5 full chars
			BitStream bs = new();
			Assert.True(bs.FromGodotString(w.ToGodotString()));
			Assert.Equal(0, bs.Pull(rangeMax));
			Assert.Equal(30 - width, bs.BitsLeft());
		}
	}

	[Fact]
	public void RangeMax_of_one_consumes_no_bits()
	{
		TestBitWriter w = new();
		w.PushBitsize(0, 6);
		BitStream bs = new();
		Assert.True(bs.FromGodotString(w.ToGodotString()));
		Assert.Equal(0, bs.Pull(1));
		Assert.Equal(6, bs.BitsLeft());
	}

	[Fact]
	public void Dry_pull_pins_cursor_at_stream_end()
	{
		BitStream bs = new();
		Assert.True(bs.FromGodotString("^")); // 6 bits
		Assert.Equal(-1, bs.Pull(999));       // needs 10
		Assert.Equal(0, bs.BitsLeft());
		Assert.Equal(-1, bs.Pull(2));         // still dry, still pinned
		Assert.Equal(0, bs.BitsLeft());
	}
}
