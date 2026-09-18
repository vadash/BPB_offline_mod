using System.Runtime.InteropServices;

namespace LeaderboardSeeder;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct LeaderboardScoresDownloadedT
{
	public const int KiCallback = 1105;

	public ulong m_hSteamLeaderboard;

	public ulong m_hSteamLeaderboardEntries;

	public int m_cEntryCount;
}
