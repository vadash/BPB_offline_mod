using System.Runtime.InteropServices;

namespace LeaderboardSeeder;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct LeaderboardFindResultT
{
	public const int KiCallback = 1104;

	public ulong m_hSteamLeaderboard;

	public byte m_bLeaderboardFound;
}
