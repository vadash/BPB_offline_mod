using System;
using System.IO;
using System.Text.Json;

namespace LeaderboardSeeder;

// Item facts for board decoding, loaded from the committed item_book_dump.json
// (the mod's test fixture of the game's ItemBook). Array position = descriptor
// index. Valid mirrors the mod's _facts: descriptor present AND scene truthy.
// RingEffects carries the persistence blob width only where the name is
// exactly "Magic Ring" - other items with effects (Superior Ring) persist
// nothing.
internal sealed class ItemBook
{
	public int NumItems { get; private set; }
	public int NumGems { get; private set; }
	private bool[] _valid = Array.Empty<bool>();
	private int[] _sockets = Array.Empty<int>();
	private int[] _ringEffects = Array.Empty<int>();

	public static ItemBook Load() => Load(Path.Combine(AppContext.BaseDirectory, "item_book_dump.json"));

	public static ItemBook Load(string path)
	{
		if (!File.Exists(path))
		{
			throw new InvalidOperationException(
				"item_book_dump.json not found next to the executable (build must copy it); cannot decode board summaries.");
		}
		using JsonDocument doc = JsonDocument.Parse(File.ReadAllBytes(path));
		JsonElement root = doc.RootElement;

		ItemBook book = new();
		int numItems = root.GetProperty("num_items").GetInt32();
		book.NumGems = root.GetProperty("num_gems").GetInt32();
		JsonElement items = root.GetProperty("items");
		if (items.GetArrayLength() != numItems)
		{
			throw new InvalidOperationException(
				$"item_book_dump.json inconsistent: num_items {numItems} but {items.GetArrayLength()} item rows.");
		}
		book.NumItems = numItems;
		book._valid = new bool[numItems];
		book._sockets = new int[numItems];
		book._ringEffects = new int[numItems];
		int i = 0;
		foreach (JsonElement item in items.EnumerateArray())
		{
			bool scene = item.TryGetProperty("scene", out JsonElement sceneElement) && sceneElement.ValueKind == JsonValueKind.True;
			book._valid[i] = scene;
			if (item.TryGetProperty("sockets", out JsonElement socketsElement) && socketsElement.ValueKind == JsonValueKind.Number)
			{
				book._sockets[i] = socketsElement.GetInt32();
			}
			if (scene
				&& item.TryGetProperty("name", out JsonElement nameElement) && nameElement.ValueKind == JsonValueKind.String
				&& nameElement.GetString() == "Magic Ring"
				&& item.TryGetProperty("effects", out JsonElement effectsElement) && effectsElement.ValueKind == JsonValueKind.Number)
			{
				book._ringEffects[i] = effectsElement.GetInt32();
			}
			i++;
		}
		return book;
	}

	public bool IsValid(int index) => index >= 0 && index < NumItems && _valid[index];

	public int Sockets(int index) => _sockets[index];

	public int RingEffects(int index) => _ringEffects[index];
}
