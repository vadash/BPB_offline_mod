using System.Runtime.InteropServices;

namespace LeaderboardSeeder;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct LeaderboardEntryT
{
	public ulong m_steamIDUser;

	public int m_nGlobalRank;

	public int m_nScore;

	public int m_cDetails;

	public ulong m_hUGC;
}
