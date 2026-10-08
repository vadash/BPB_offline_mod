using System;

namespace LeaderboardSeeder;

// Faithful port of the mod's Core/BitStream.gd reader (6-bit-per-char Godot
// strings, MSB-first pulls). Game parity rules the summary decode depends on:
// the field width is the float formula ceil(log(rangeMax)/log(2)) - never an
// integer bit trick; rangeMax <= 1 consumes 0 bits; a dry pull returns -1 and
// pins the cursor at the stream end (a partial field may already be consumed).
internal sealed class BitStream
{
	private const int Base64Offset = 62;

	// Raw char values, each in [Base64Offset, Base64Offset + 63].
	private byte[] _bytes = Array.Empty<byte>();
	private int _numBits;
	private int _currentBit;

	public bool FromGodotString(string value)
	{
		_bytes = new byte[value.Length];
		_numBits = value.Length * 6;
		_currentBit = 0;
		for (int i = 0; i < value.Length; i++)
		{
			int c = value[i];
			if (c < Base64Offset || c > Base64Offset + 63)
			{
				return false;
			}
			_bytes[i] = (byte)c;
		}
		return true;
	}

	public int BitsLeft() => _numBits - _currentBit;

	public int Pull(int rangeMax) => rangeMax <= 1 ? 0 : PullBitsize(NumBits(rangeMax));

	public int PullBitsize(int numBits)
	{
		int end = _currentBit + numBits;
		if (end > _numBits)
		{
			_currentBit = _numBits;
			return -1;
		}
		int value = 0;
		int remaining = numBits;
		while (remaining > 0)
		{
			int bitInChar = _currentBit % 6;
			int take = 6 - bitInChar;
			if (take > remaining)
			{
				take = remaining;
			}
			int charVal = _bytes[_currentBit / 6] - Base64Offset;
			value = (value << take) | ((charVal >> (6 - bitInChar - take)) & ((1 << take) - 1));
			_currentBit += take;
			remaining -= take;
		}
		return value;
	}

	// Board pulls repeat a handful of widths millions of times per merge, so
	// the two log() calls are cached. 0 means "not computed" - safe sentinel,
	// every rangeMax >= 2 needs at least 1 bit. Benign race: all threads
	// compute and store the same value.
	private static readonly int[] _widthCache = new int[1024];

	public static int NumBits(int rangeMax)
	{
		if (rangeMax > 1 && rangeMax < _widthCache.Length)
		{
			int cached = _widthCache[rangeMax];
			if (cached != 0)
			{
				return cached;
			}
			int width = (int)Math.Ceiling(Math.Log(rangeMax) / Math.Log(2));
			_widthCache[rangeMax] = width;
			return width;
		}
		return (int)Math.Ceiling(Math.Log(rangeMax) / Math.Log(2));
	}
}
