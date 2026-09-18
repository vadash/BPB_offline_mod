using System.Runtime.InteropServices;

namespace LeaderboardSeeder;

internal struct SteamErrMsg
{
	[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
	public string Value;
}
