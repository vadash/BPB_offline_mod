namespace LeaderboardSeeder;

internal record Entry(ulong SteamId, int OrigRank, ulong WorkshopId, double R, string D, string Metadata);
