using System.Runtime.InteropServices;

namespace LeaderboardSeeder;

internal static class Steam
{
	private const string Dll = "steam_api64";

	[DllImport("steam_api64")]
	public static extern ESteamApiInitResult SteamAPI_InitFlat(ref SteamErrMsg pOutErrMsg);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_InitSafe();

	[DllImport("steam_api64")]
	public static extern void SteamAPI_Shutdown();

	[DllImport("steam_api64")]
	public static extern void SteamAPI_RunCallbacks();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamFriends_v018();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamUserStats_v013();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamUtils_v010();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamUGC_v021();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamFriends_v017();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamUserStats_v012();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_SteamUGC_v018();

	[DllImport("steam_api64")]
	public static extern nint SteamAPI_ISteamFriends_GetPersonaName(nint self);

	[DllImport("steam_api64")]
	public static extern ulong SteamAPI_ISteamUserStats_FindLeaderboard(nint self, [MarshalAs(UnmanagedType.LPStr)] string pchLeaderboardName);

	[DllImport("steam_api64")]
	public static extern int SteamAPI_ISteamUserStats_GetLeaderboardEntryCount(nint self, ulong hSteamLeaderboard);

	[DllImport("steam_api64")]
	public static extern ulong SteamAPI_ISteamUserStats_DownloadLeaderboardEntries(nint self, ulong hSteamLeaderboard, ELeaderboardDataRequest eDataRequest, int nRangeStart, int nRangeEnd);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUserStats_GetDownloadedLeaderboardEntry(nint self, ulong hSteamLeaderboardEntries, int index, out LeaderboardEntryT pLeaderboardEntry, nint pDetails, int cDetailsMax);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUtils_IsAPICallCompleted(nint self, ulong hSteamApiCall, [MarshalAs(UnmanagedType.I1)] out bool pbFailed);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUtils_GetAPICallResult(nint self, ulong hSteamApiCall, nint pCallback, int cubCallback, int iCallbackExpected, [MarshalAs(UnmanagedType.I1)] out bool pbFailed);

	[DllImport("steam_api64")]
	public static extern ulong SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(nint self, nint pvecPublishedFileId, uint unNumPublishedFileIDs);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUGC_SetReturnMetadata(nint self, ulong handle, [MarshalAs(UnmanagedType.I1)] bool bReturnMetadata);

	[DllImport("steam_api64")]
	public static extern ulong SteamAPI_ISteamUGC_SendQueryUGCRequest(nint self, ulong handle);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUGC_GetQueryUGCMetadata(nint self, ulong handle, uint index, nint pchMetadata, uint cchMetadatasize);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUGC_GetQueryUGCResult(nint self, ulong handle, uint index, nint pDetails);

	[DllImport("steam_api64")]
	[return: MarshalAs(UnmanagedType.I1)]
	public static extern bool SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(nint self, ulong handle);
}
