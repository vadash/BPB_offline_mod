using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.IO.Compression;
using System.Text;
using System.Threading;
using LeaderboardSeeder;

[CompilerGenerated]
internal class Program
{
	private static int Main(string[] args)
	{
		string text = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "ghosts.gdb");
		string? mergeDir = null;
		bool dbFromFlag = false;
		int keepD = RunFilter.FilterSettings.Seed.KeepD;
		bool keepDFromFlag = false;
		int cutBottom = RunFilter.FilterSettings.Seed.CutBottom;
		bool cutBottomFromFlag = false;
		for (int i = 0; i < args.Length; i++)
		{
			if (args[i] == "--db" && i + 1 < args.Length)
			{
				text = args[++i];
				dbFromFlag = true;
			}
			if (args[i] == "--merge")
			{
				if (i + 1 >= args.Length)
				{
					Console.Error.WriteLine("[ERR] --merge requires a folder argument.");
					return 1;
				}
				mergeDir = args[++i];
			}
			if (args[i] == "--keep-d" && i + 1 < args.Length)
			{
				if (!int.TryParse(args[++i], out keepD) || keepD < 1)
				{
					Console.Error.WriteLine("[ERR] --keep-d must be an integer >= 1.");
					return 1;
				}
				keepDFromFlag = true;
			}
			if (args[i] == "--cut-bottom" && i + 1 < args.Length)
			{
				if (!int.TryParse(args[++i], out cutBottom))
				{
					Console.Error.WriteLine("[ERR] --cut-bottom must be an integer.");
					return 1;
				}
				if (cutBottom < 0)
				{
					cutBottom = 0;
				}
				if (cutBottom > 100)
				{
					cutBottom = 100;
				}
				cutBottomFromFlag = true;
			}
		}
		if (mergeDir != null)
		{
			// inputs are already keep-d/cut-bottom filtered by the seeder that
			// wrote them; re-applying would double-cut. Flags override.
			int mergeKeepD = keepDFromFlag ? keepD : int.MaxValue;
			int mergeCutBottom = cutBottomFromFlag ? cutBottom : 0;
			Console.WriteLine("[..] Mode: merge folder " + mergeDir);
			if (dbFromFlag)
			{
				Console.WriteLine("[..] --db ignored in merge mode; output is " + Path.Combine(mergeDir, GhostDb.MergeFileName));
			}
			Console.WriteLine("[..] Output: " + Path.Combine(mergeDir, GhostDb.MergeFileName));
			Console.WriteLine("[..] Keep window: " + (keepDFromFlag ? "last " + keepD + " versions (flag)" : "all versions in union (inputs pre-filtered)"));
			Console.WriteLine("[..] Cut bottom: " + (cutBottomFromFlag ? cutBottom + "% (flag)" : "off (inputs pre-filtered)"));
			return Merger.RunMerge(mergeDir, mergeKeepD, mergeCutBottom, Console.Out, Console.Error);
		}
		Console.WriteLine("[..] Keep window: last " + keepD + " versions" + (keepDFromFlag ? " (flag)" : " (default)"));
		Console.WriteLine("[..] Cut bottom: " + cutBottom + "%" + (cutBottomFromFlag ? " (flag)" : " (default)"));
		Console.WriteLine("[..] Output: " + text);
		bool flag;
		try
		{
			SteamErrMsg pOutErrMsg = default(SteamErrMsg);
			flag = Steam.SteamAPI_InitFlat(ref pOutErrMsg) == ESteamApiInitResult.Ok;
			if (!flag)
			{
				Console.Error.WriteLine("[ERR] SteamAPI_InitFlat failed: " + pOutErrMsg.Value);
			}
		}
		catch (EntryPointNotFoundException)
		{
			flag = Steam.SteamAPI_InitSafe();
			if (!flag)
			{
				Console.Error.WriteLine("[ERR] SteamAPI_InitSafe failed");
			}
		}
		if (!flag)
		{
			return 1;
		}
		nint self = GetAccessor(Steam.SteamAPI_SteamFriends_v018, Steam.SteamAPI_SteamFriends_v017);
		nint pUserStats = GetAccessor(Steam.SteamAPI_SteamUserStats_v013, Steam.SteamAPI_SteamUserStats_v012);
		nint pUtils = Steam.SteamAPI_SteamUtils_v010();
		nint pUgc = GetAccessor(Steam.SteamAPI_SteamUGC_v021, Steam.SteamAPI_SteamUGC_v018);
		string text2 = Marshal.PtrToStringUTF8(Steam.SteamAPI_ISteamFriends_GetPersonaName(self)) ?? "?";
		Console.WriteLine("[OK]  Steam: " + text2);
		Console.Write("[..] Finding leaderboard 'bpb-runs3' ...");
		LeaderboardFindResultT leaderboardFindResultT = WaitFor<LeaderboardFindResultT>(Steam.SteamAPI_ISteamUserStats_FindLeaderboard(pUserStats, "bpb-runs3"), 1104);
		if (leaderboardFindResultT.m_bLeaderboardFound == 0)
		{
			Console.Error.WriteLine("\n[ERR] Leaderboard not found.");
			Steam.SteamAPI_Shutdown();
			return 1;
		}
		ulong lbHandle = leaderboardFindResultT.m_hSteamLeaderboard;
		int num = Steam.SteamAPI_ISteamUserStats_GetLeaderboardEntryCount(pUserStats, lbHandle);
		Console.WriteLine($" cached total={num:N0}");
		List<(int rank, ulong steamId, int score, ulong workshopId)> list = new List<(int rank, ulong steamId, int score, ulong workshopId)>((num > 0) ? num : 1000000);
		Console.Write("[..] Fetching leaderboard ...");
		Stopwatch stopwatch = Stopwatch.StartNew();
		nint num2 = Marshal.AllocHGlobal(8);
		int num3 = Marshal.SizeOf<LeaderboardScoresDownloadedT>();
		bool pbFailed2;
		try
		{
			Queue<(int bStart, ulong call)> pending = new Queue<(int, ulong)>(8);
			int nextStart = 1;
			bool exhausted = false;
			for (int j = 0; j < 4; j++)
			{
				Issue();
			}
			while (pending.Count > 0)
			{
				Steam.SteamAPI_RunCallbacks();
				(int bStart, ulong call)[] array = pending.ToArray();
				pending.Clear();
				(int, ulong)[] array2 = array;
				for (int k = 0; k < array2.Length; k++)
				{
					var (item, num4) = array2[k];
					if (!Steam.SteamAPI_ISteamUtils_IsAPICallCompleted(pUtils, num4, out var pbFailed))
					{
						pending.Enqueue((item, num4));
						continue;
					}
					if (pbFailed)
					{
						throw new Exception("Steam I/O failure on leaderboard fetch");
					}
					nint num5 = Marshal.AllocHGlobal(num3);
					LeaderboardScoresDownloadedT leaderboardScoresDownloadedT;
					try
					{
						if (!Steam.SteamAPI_ISteamUtils_GetAPICallResult(pUtils, num4, num5, num3, 1105, out pbFailed2))
						{
							throw new Exception("GetAPICallResult failed");
						}
						leaderboardScoresDownloadedT = Marshal.PtrToStructure<LeaderboardScoresDownloadedT>(num5);
					}
					finally
					{
						Marshal.FreeHGlobal(num5);
					}
					if (leaderboardScoresDownloadedT.m_cEntryCount == 0)
					{
						exhausted = true;
						continue;
					}
					for (int l = 0; l < leaderboardScoresDownloadedT.m_cEntryCount; l++)
					{
						Marshal.WriteInt64(num2, 0L);
						Steam.SteamAPI_ISteamUserStats_GetDownloadedLeaderboardEntry(pUserStats, leaderboardScoresDownloadedT.m_hSteamLeaderboardEntries, l, out var pLeaderboardEntry, num2, 2);
						ulong item2 = ((ulong)(uint)Marshal.ReadInt32(num2, 0) << 32) | (uint)Marshal.ReadInt32(num2, 4);
						list.Add((pLeaderboardEntry.m_nGlobalRank, pLeaderboardEntry.m_steamIDUser, pLeaderboardEntry.m_nScore, item2));
					}
					Issue();
				}
				double value = (double)list.Count / Math.Max(stopwatch.Elapsed.TotalSeconds, 0.001);
				string value2 = ((num > 0) ? $"{list.Count * 100 / num}%" : "?");
				Console.Write($"\r[..] Fetching leaderboard ... [{list.Count:N0} | {value2} | {value:F0}/s]   ");
				Thread.Sleep(10);
			}
			void Issue()
			{
				if (!exhausted)
				{
					ulong item3 = Steam.SteamAPI_ISteamUserStats_DownloadLeaderboardEntries(pUserStats, lbHandle, ELeaderboardDataRequest.Global, nextStart, nextStart + 5000 - 1);
					pending.Enqueue((nextStart, item3));
					nextStart += 5000;
				}
			}
		}
		finally
		{
			Marshal.FreeHGlobal(num2);
		}
		Console.WriteLine($"\r[OK]  {list.Count:N0} entries in {stopwatch.Elapsed.TotalSeconds:F1}s.{new string(' ', 30)}");
		List<ulong> ugcIds = (from e in list
			where e.workshopId != 0
			select e.workshopId).Distinct().ToList();
		Dictionary<ulong, string> dictionary = new Dictionary<ulong, string>(ugcIds.Count);
		nint num6 = Marshal.AllocHGlobal(5000);
		nint num7 = Marshal.AllocHGlobal(12288);
		Console.Write($"[..] Fetching metadata for {ugcIds.Count:N0} items ...");
		stopwatch.Restart();
		try
		{
			Queue<(int offset, ulong qh, ulong call)> ugcPending = new Queue<(int, ulong, ulong)>(8);
			int nextUgcOffset = 0;
			for (int num8 = 0; num8 < 4; num8++)
			{
				IssueUgc();
			}
			while (ugcPending.Count > 0)
			{
				Steam.SteamAPI_RunCallbacks();
				(int offset, ulong qh, ulong call)[] array3 = ugcPending.ToArray();
				ugcPending.Clear();
				(int, ulong, ulong)[] array4 = array3;
				for (int k = 0; k < array4.Length; k++)
				{
					var (num9, num10, num11) = array4[k];
					if (!Steam.SteamAPI_ISteamUtils_IsAPICallCompleted(pUtils, num11, out var pbFailed3))
					{
						ugcPending.Enqueue((num9, num10, num11));
						continue;
					}
					if (pbFailed3)
					{
						Console.Error.WriteLine($"\n[WARN] UGC query I/O failure at offset {num9:N0} -- skipping.");
						Steam.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(pUgc, num10);
						IssueUgc();
						continue;
					}
					uint num12 = 0u;
					bool flag2 = false;
					int[] array5 = new int[2] { 152, 280 };
					foreach (int num14 in array5)
					{
						nint num15 = Marshal.AllocHGlobal(num14);
						try
						{
							if (!Steam.SteamAPI_ISteamUtils_GetAPICallResult(pUtils, num11, num15, num14, 3401, out pbFailed2))
							{
								continue;
							}
							if (Marshal.ReadInt32(num15, 8) == 1)
							{
								num12 = (uint)Marshal.ReadInt32(num15, 12);
								flag2 = true;
							}
							break;
						}
						finally
						{
							Marshal.FreeHGlobal(num15);
						}
					}
					if (flag2)
					{
						for (uint num16 = 0u; num16 < num12; num16++)
						{
							if (!Steam.SteamAPI_ISteamUGC_GetQueryUGCResult(pUgc, num10, num16, num7))
							{
								continue;
							}
							ulong num17 = (ulong)Marshal.ReadInt64(num7, 0);
							if (num17 != 0L && Steam.SteamAPI_ISteamUGC_GetQueryUGCMetadata(pUgc, num10, num16, num6, 5000u))
							{
								string text3 = Marshal.PtrToStringAnsi(num6) ?? "";
								if (text3.Length > 10)
								{
									dictionary[num17] = text3;
								}
							}
						}
					}
					Steam.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(pUgc, num10);
					IssueUgc();
				}
				double value3 = (double)dictionary.Count / Math.Max(stopwatch.Elapsed.TotalSeconds, 0.001);
				int value4 = ((ugcIds.Count > 0) ? (Math.Min(nextUgcOffset, ugcIds.Count) * 100 / ugcIds.Count) : 0);
				Console.Write($"\r[..] Fetching metadata ... [{dictionary.Count:N0} hits | {value4}% | {value3:F0}/s]   ");
				Thread.Sleep(10);
			}
			void IssueUgc()
			{
				if (nextUgcOffset < ugcIds.Count)
				{
					ulong[] array6 = ugcIds.Skip(nextUgcOffset).Take(1000).ToArray();
					GCHandle gCHandle = GCHandle.Alloc(array6, GCHandleType.Pinned);
					ulong num19;
					try
					{
						num19 = Steam.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(pUgc, gCHandle.AddrOfPinnedObject(), (uint)array6.Length);
					}
					finally
					{
						gCHandle.Free();
					}
					if (num19 == ulong.MaxValue)
					{
						Console.Error.WriteLine($"\n[WARN] Invalid UGC query handle at offset {nextUgcOffset:N0} -- skipping.");
						nextUgcOffset += 1000;
					}
					else
					{
						Steam.SteamAPI_ISteamUGC_SetReturnMetadata(pUgc, num19, bReturnMetadata: true);
						ulong item3 = Steam.SteamAPI_ISteamUGC_SendQueryUGCRequest(pUgc, num19);
						ugcPending.Enqueue((nextUgcOffset, num19, item3));
						nextUgcOffset += 1000;
					}
				}
			}
		}
		finally
		{
			Marshal.FreeHGlobal(num6);
			Marshal.FreeHGlobal(num7);
		}
		Console.WriteLine($"\r[OK]  {dictionary.Count:N0} metadata hits in {stopwatch.Elapsed.TotalSeconds:F1}s.{new string(' ', 30)}");
		Console.Write("[..] Filtering ...");
		List<LeaderboardEntryT> rankOrderedRaw = list
			.OrderBy(e => e.rank)
			.Select(e => new LeaderboardEntryT { m_steamIDUser = e.steamId, m_nGlobalRank = e.rank, m_nScore = e.score, m_hUGC = e.workshopId })
			.ToList();
		RunFilter.AdmitResult admit = RunFilter.Admit(rankOrderedRaw, dictionary);
		RunFilter.FilterSettings settings = keepDFromFlag || cutBottomFromFlag
			? new RunFilter.FilterSettings(keepD, cutBottom)
			: RunFilter.FilterSettings.Seed;
		RunFilter.FilterResult filtered = RunFilter.Apply(
			admit.Candidates,
			RunFilter.Dedup.None,
			settings,
			perCodeTotals: admit.PerCode);
		Console.WriteLine($" {admit.Candidates.Count:N0} parseable, rating floor {filtered.Floor:R}, cut {filtered.FloorCut:N0} below floor.");
		Console.WriteLine($"[..] {filtered.Kept.Count:N0} valid (pruned {list.Count - filtered.Kept.Count:N0} invalid/filtered entries, last {settings.KeepD} versions, bottom {settings.CutBottom}%).");
		foreach (RunFilter.CodeStat stat in filtered.PerCode)
		{
			Console.WriteLine($"     {stat.Code}  kept {stat.Kept,7:N0}  cut {stat.Total - stat.Kept,7:N0}  total {stat.Total,8:N0}");
		}
		Console.Write("[..] Writing " + text + " ...");
		int n = GhostDb.Write(filtered.Kept, text, (done, total) =>
		{
			if (done % 10000 == 0)
			{
				Console.Write($"\r[..] Writing {text} ... [compressing {done:N0}/{total:N0}]   ");
			}
		});
		long length = new FileInfo(text).Length;
		Console.WriteLine($"\r[OK]  {n:N0} rows -> {text} ({(double)length / 1048576.0:F1} MB).{new string(' ', 20)}");
		Steam.SteamAPI_Shutdown();
		return 0;
		static nint GetAccessor(Func<nint> newer, Func<nint> older)
		{
			try
			{
				return newer();
			}
			catch (EntryPointNotFoundException)
			{
				return older();
			}
		}
		T WaitFor<T>(ulong handle, int callbackId, int timeoutMs = 15000) where T : struct
		{
			int num19 = Marshal.SizeOf<T>();
			for (int m = 0; m < timeoutMs; m += 50)
			{
				Steam.SteamAPI_RunCallbacks();
				if (Steam.SteamAPI_ISteamUtils_IsAPICallCompleted(pUtils, handle, out var pbFailed4))
				{
					if (pbFailed4)
					{
						throw new Exception("Steam I/O failure");
					}
					nint num20 = Marshal.AllocHGlobal(num19);
					try
					{
						if (!Steam.SteamAPI_ISteamUtils_GetAPICallResult(pUtils, handle, num20, num19, callbackId, out var _))
						{
							throw new Exception("GetAPICallResult returned false");
						}
						return Marshal.PtrToStructure<T>(num20);
					}
					finally
					{
						Marshal.FreeHGlobal(num20);
					}
				}
				Thread.Sleep(50);
			}
			throw new TimeoutException($"Steam callback timed out ({timeoutMs}ms)");
		}
	}
}
