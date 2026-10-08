using System;
using LeaderboardSeeder;
using Xunit;

namespace LeaderboardSeeder.Tests;

// Seam: BoardDecoder, the port of the mod's Core/BoardDecoder.gd restricted
// to descriptor indexes (the v2 summary never needs names). Pins mirror the
// mod's test_decode_item_names matrix; failure modes are null, never an
// error or a partial item set.
public class BoardDecoderTests
{
	private static readonly ItemBook Book = ItemBook.Load();

	private static string Round(params TestItem[] specs) =>
		TestBoards.EncodeRound(Book, TestBoards.NumItems, specs);

	private static TestItem Item(int index, int x, int y, int face, int[] gems) => new(index, x, y, face, gems);

	[Fact]
	public void Socketed_item_with_one_gem_decodes()
	{
		Assert.Equal(new[] { TestBoards.WoodenSword }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 })), "1.1.8", Book));
	}

	[Fact]
	public void Empty_socket_gem_id_is_accepted()
	{
		Assert.Equal(new[] { TestBoards.WoodenSword }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.WoodenSword, 3, 4, 1, new[] { 63 })), "1.1.8", Book));
	}

	[Fact]
	public void HasGems_zero_consumes_no_gem_bits()
	{
		Assert.Equal(new[] { TestBoards.WoodenSword, 0 }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.WoodenSword, 3, 4, 0, Array.Empty<int>()), Item(0, 1, 2, 2, Array.Empty<int>())), "1.1.8", Book));
	}

	[Fact]
	public void Three_socket_item_consumes_a_three_gem_block()
	{
		// Rib Saw Blade has 3 sockets, so hasGems=1 must consume exactly
		// 3 * 6 gem bits or the next field misaligns.
		Assert.Equal(new[] { TestBoards.RibSawBlade }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.RibSawBlade, 2, 3, 1, new[] { 1, 2, 63 })), "1.1.8", Book));
	}

	[Fact]
	public void Magic_Ring_persistence_blob_is_consumed()
	{
		// The 12-bit blob must be consumed exactly, or the trailing padding
		// would decode as another item.
		Assert.Equal(new[] { 0, TestBoards.MagicRing }, BoardDecoder.DecodeItemIndexes(
			Round(Item(0, 1, 2, 1, Array.Empty<int>()), Item(TestBoards.MagicRing, 3, 4, 2, Array.Empty<int>())), "1.1.8", Book));
	}

	[Fact]
	public void Superior_Ring_consumes_no_persistence_blob()
	{
		Assert.Equal(new[] { TestBoards.SuperiorRing, 0 }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.SuperiorRing, 3, 4, 2, Array.Empty<int>()), Item(0, 5, 6, 3, Array.Empty<int>())), "1.1.8", Book));
	}

	[Fact]
	public void Version_1_1_0_exactly_reads_modern_widths()
	{
		Assert.Equal(new[] { TestBoards.WoodenSword }, BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 })), "1.1.0", Book));
	}

	[Fact]
	public void Pre_1_1_0_boards_read_legacy_9_bit_indexes()
	{
		string round = TestBoards.EncodeRound(Book, TestBoards.LegacyNumItems,
			Item(TestBoards.WoodenSword, 3, 4, 1, new[] { 0 }));

		Assert.Equal(new[] { TestBoards.WoodenSword }, BoardDecoder.DecodeItemIndexes(round, "1.0.9", Book));
	}

	[Fact]
	public void Index_without_a_scene_returns_null()
	{
		Assert.Null(BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.SceneLess, 1, 1, 1, Array.Empty<int>())), "1.1.8", Book));
	}

	[Fact]
	public void Index_at_num_items_returns_null()
	{
		Assert.Null(BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.NumItems, 1, 1, 1, Array.Empty<int>())), "1.1.8", Book));
	}

	[Fact]
	public void Gem_index_beyond_num_gems_returns_null()
	{
		Assert.Null(BoardDecoder.DecodeItemIndexes(
			Round(Item(TestBoards.WoodenSword, 1, 1, 1, new[] { TestBoards.NumGems })), "1.1.8", Book));
	}

	[Fact]
	public void Stream_dying_mid_item_returns_null()
	{
		TestBitWriter trunc = new();
		trunc.Push(123, 999);
		trunc.Push(456, 999);
		trunc.PushBitsize(0, 8); // half an item index

		Assert.Null(BoardDecoder.DecodeItemIndexes(trunc.ToGodotString(), "1.1.8", Book));
	}

	[Fact]
	public void Non_6bit_round_returns_null()
	{
		Assert.Null(BoardDecoder.DecodeItemIndexes("~", "1.1.8", Book));
	}

	[Fact]
	public void Header_round_trips_version_results_and_class()
	{
		int[] results = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 3 };

		BoardDecoder.RunHeader? header = BoardDecoder.DecodeHeader(TestBoards.EncodeHeader("1.1.6", results, 2));

		Assert.NotNull(header);
		Assert.Equal("1.1.6", header!.EntryVersion);
		Assert.Equal(results, header.Results);
		Assert.Equal(2, header.Class);
	}

	[Fact]
	public void Legacy_header_reads_the_2_bit_class()
	{
		// Pre-1.0.0 runs encode the class against the 4-entry Classes enum.
		int[] results = { 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2 };

		BoardDecoder.RunHeader? header = BoardDecoder.DecodeHeader(TestBoards.EncodeHeader("0.9.1", results, 3));

		Assert.NotNull(header);
		Assert.Equal("0.9.1", header!.EntryVersion);
		Assert.Equal(3, header.Class);
	}

	[Fact]
	public void Short_header_returns_null()
	{
		// Version only: the results loop runs dry.
		TestBitWriter w = new();
		w.Push(1, 4);
		w.Push(1, 16);
		w.Push(6, 64);

		Assert.Null(BoardDecoder.DecodeHeader(w.ToGodotString()));
	}

	[Fact]
	public void Non_6bit_header_returns_null()
	{
		Assert.Null(BoardDecoder.DecodeHeader("~"));
	}
}
