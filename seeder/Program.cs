using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Threading;
using LeaderboardSeeder;

[CompilerGenerated]
internal class Program
{
	private static int Main(string[] args)
	{
		string text = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "ghosts.gdb");
		int keepD = 4;
		bool keepDFromFlag = false;
		int cutBottom = 25;
		bool cutBottomFromFlag = false;
		for (int i = 0; i < args.Length; i++)
		{
			if (args[i] == "--db" && i + 1 < args.Length)
			{
				text = args[++i];
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
		List<Entry> list2 = new List<Entry>();
		List<Entry> candidates = new List<Entry>();
		HashSet<ulong> hashSet = new HashSet<ulong>();
		Dictionary<string, int[]> stats = new Dictionary<string, int[]>();
		foreach (var item4 in list.OrderBy(e => e.rank))
		{
			if (item4.workshopId == 0L || !hashSet.Add(item4.steamId) || !dictionary.TryGetValue(item4.workshopId, out var value5))
			{
				continue;
			}
			double r = 0.0;
			string? text4 = null;
			try
			{
				using JsonDocument jsonDocument = JsonDocument.Parse(value5);
				JsonElement rootElement = jsonDocument.RootElement;
				if (!rootElement.TryGetProperty("r", out var value6) || value6.ValueKind != JsonValueKind.Number)
				{
					continue;
				}
				r = value6.GetDouble();
				if (rootElement.TryGetProperty("d", out var value8) && value8.ValueKind == JsonValueKind.String)
				{
					text4 = value8.GetString();
				}
			}
			catch
			{
				continue;
			}
			string key = (text4 != null && text4.Length >= 2) ? text4.Substring(0, 2) : "?";
			if (!stats.TryGetValue(key, out var stat))
			{
				stat = new int[2];
				stats[key] = stat;
			}
			stat[0]++;
			if (text4 != null && text4.Length >= 2)
			{
				candidates.Add(new Entry(item4.steamId, item4.rank, item4.workshopId, r, text4, value5));
			}
		}
		HashSet<string> window = new HashSet<string>(RunFilter.VersionWindow(candidates.Select(e => e.D.Substring(0, 2)), keepD));
		List<Entry> inWindow = candidates.Where(e => window.Contains(e.D.Substring(0, 2))).ToList();
		double floor = RunFilter.RatingFloor(inWindow.Select(e => e.R), cutBottom);
		int floorCut = 0;
		foreach (var item5 in inWindow)
		{
			if (item5.R >= floor)
			{
				stats[item5.D.Substring(0, 2)][1]++;
				list2.Add(item5);
			}
			else
			{
				floorCut++;
			}
		}
		Console.WriteLine($" {candidates.Count:N0} parseable, rating floor {floor:R}, cut {floorCut:N0} below floor.");
		Console.WriteLine($"[..] {list2.Count:N0} valid (pruned {list.Count - list2.Count:N0} invalid/filtered entries, last {keepD} versions, bottom {cutBottom}%).");
		foreach (var stat in stats.OrderBy(s => s.Key, StringComparer.Ordinal))
		{
			Console.WriteLine($"     {stat.Key}  kept {stat.Value[1],7:N0}  cut {stat.Value[0] - stat.Value[1],7:N0}  total {stat.Value[0],8:N0}");
		}
		Console.Write("[..] Writing " + text + " ...");
		string tmpPath = text + ".tmp";
		int n = list2.Count;
		string[] versionCodes = list2.Select(e => e.D.Substring(0, 2)).Distinct().OrderBy(c => c, StringComparer.Ordinal).ToArray();
		Dictionary<string, byte> versionIndex = new Dictionary<string, byte>(versionCodes.Length);
		for (int i = 0; i < versionCodes.Length; i++)
		{
			versionIndex[versionCodes[i]] = (byte)i;
		}
		byte[] dCodes = new byte[n];
		for (int i = 0; i < n; i++)
		{
			dCodes[i] = versionIndex[list2[i].D.Substring(0, 2)];
		}
		int[] dOrder = Enumerable.Range(0, n).OrderBy(i => dCodes[i]).ThenBy(i => i).ToArray();
		double[] rValues = list2.Select(e => e.R).OrderByDescending(r => r).ToArray();
		long prefixSize = 12L + 1L + 2L * versionCodes.Length + 29L * n;
		byte[][] compBlobs = new byte[n][];
		long[] blobOffsets = new long[n];
		using (MemoryStream blobMs = new MemoryStream())
		{
			for (int i = 0; i < n; i++)
			{
				byte[] rawBytes = Encoding.UTF8.GetBytes(list2[i].Metadata);
				using MemoryStream srcMs = new MemoryStream(rawBytes);
				using MemoryStream dstMs = new MemoryStream(rawBytes.Length / 2 + 64);
				using (GZipStream gzipStream = new GZipStream(dstMs, CompressionLevel.Optimal))
				{
					srcMs.CopyTo(gzipStream);
				}
				compBlobs[i] = dstMs.ToArray();
				blobOffsets[i] = prefixSize + blobMs.Position;
				blobMs.Write(BitConverter.GetBytes((uint)compBlobs[i].Length), 0, 4);
				blobMs.Write(BitConverter.GetBytes((uint)rawBytes.Length), 0, 4);
				blobMs.Write(compBlobs[i], 0, compBlobs[i].Length);
				if ((i + 1) % 10000 == 0)
				{
					Console.Write($"\r[..] Writing {text} ... [compressing {i + 1:N0}/{n:N0}]   ");
				}
			}
			using (FileStream fileStream = new FileStream(tmpPath, FileMode.Create, FileAccess.Write, FileShare.None))
			{
				using BinaryWriter binaryWriter = new BinaryWriter(fileStream);
				binaryWriter.Write("BGDB"u8);
				binaryWriter.Write(1u);
				binaryWriter.Write((uint)n);
				binaryWriter.Write((byte)versionCodes.Length);
				foreach (string versionCode in versionCodes)
				{
					binaryWriter.Write(Encoding.ASCII.GetBytes(versionCode));
				}
				foreach (Entry item5 in list2)
				{
					binaryWriter.Write(item5.SteamId);
				}
				foreach (long blobOffset in blobOffsets)
				{
					binaryWriter.Write((ulong)blobOffset);
				}
				foreach (byte dCode in dCodes)
				{
					binaryWriter.Write(dCode);
				}
				foreach (int runIndex in dOrder)
				{
					binaryWriter.Write((uint)runIndex);
				}
				foreach (double rValue in rValues)
				{
					binaryWriter.Write(rValue);
				}
				binaryWriter.Flush();
				blobMs.WriteTo(fileStream);
			}
		}
		File.Move(tmpPath, text, overwrite: true);
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
