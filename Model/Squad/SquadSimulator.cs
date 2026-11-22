using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>100 局报告里的一行。</summary>
    public sealed class SquadSimRow
    {
        public int Index;
        public int Seed;
        public string Outcome = "";
        public string OutcomeText = "";
        public double PlayerHp;
        public double EnemyHp;
        public double PlayerHpPct;
        public int PlayerSquads;
        public int EnemySquads;
        public int PlayerSquadsLost;
        public int EnemySquadsLost;
        public int PlayerModelsLost;
        public int EnemyModelsLost;
        public double PlayerDamage;
        public double EnemyDamage;
        public double DpsPerMember;
        public double Seconds;
        public int ZoneMax;
        public int EnemyZoneMax;
        public double PlayerZoneSeconds;
        public double EnemyZoneSeconds;
        public int StuckEvents;
        public double SlotError;
        public int CpLeft;
        public int PopBlocked;
        public string TopReason = "";
    }

    /// <summary>一批小队推演的汇总（--simulate 的返回）。</summary>
    public sealed class SquadSimSummary
    {
        public bool Ok;
        public string ArenaId = "";
        public string ArenaName = "";
        public int Games;
        public int SeedBase;
        public int Wins;
        public int Losses;
        public int Draws;
        public double WinRate;
        public double AvgPlayerHp;
        public double AvgEnemyHp;
        public double AvgPlayerHpPct;
        public double AvgSeconds;
        public double AvgPlayerSquads;
        public double AvgEnemySquads;
        public double AvgPlayerSquadsLost;
        public double AvgPlayerModelsLost;
        public double AvgEnemyModelsLost;
        public double AvgPlayerDps;
        public double AvgPlayerDpsPerMember;
        public double AvgPlayerDamage;
        public double AvgPathLength;
        public double AvgPathStraightRatio;
        public double AvgStuckEvents;
        public double AvgSlotError;
        public int TotalPlayerKills;
        public int TotalEnemyKills;
        public int AvgEnemyMaxZone;
        public double AvgPlayerZoneSeconds;
        public double AvgEnemyZoneSeconds;
        public readonly Dictionary<string, int> ReviewCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        public readonly Dictionary<string, SquadUnitStat> PlayerByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);
        public readonly Dictionary<string, SquadUnitStat> EnemyByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);
        public readonly List<SquadSimRow> Rows = new List<SquadSimRow>();
        public readonly List<SquadMatchResult> Samples = new List<SquadMatchResult>();
        public readonly List<string> Errors = new List<string>();
    }

    /// <summary>
    /// 小队对局批量推演：每局独立种子，跑完整两轮 60 秒（规划 + 出兵 + 脊线推进 + 6 步结算）。
    /// 纯 Model，不读引擎时间/帧率；同 seed + 同配置 = 同结果。
    /// </summary>
    public static class SquadSimulator
    {
        public static SquadSimSummary Run(
            UnitCatalog units,
            CombatRules combat,
            PlanningConfig planning,
            SquadArena arena,
            int games,
            int seedBase,
            IDictionary<string, object> tuning = null)
        {
            var summary = new SquadSimSummary
            {
                ArenaId = arena != null ? arena.Id : "",
                ArenaName = arena != null ? arena.DisplayName : "",
                Games = Math.Max(1, Math.Min(games, 500)),
                SeedBase = seedBase,
            };
            if (arena == null)
            {
                summary.Ok = false;
                summary.Errors.Add("缺少小队战场数据");
                return summary;
            }

            var winSamples = new List<SquadMatchResult>();
            double totalSeconds = 0.0;
            double totalMemberSeconds = 0.0;
            double totalSquadSeconds = 0.0;
            double totalPath = 0.0;
            double totalStraight = 0.0;
            int pathGames = 0;

            for (int i = 0; i < summary.Games; i++)
            {
                int seed = seedBase + i;
                SquadMatchResult r;
                try
                {
                    r = SquadMatch.Run(units, combat, planning, arena, seed, tuning);
                }
                catch (Exception e)
                {
                    summary.Ok = false;
                    summary.Errors.Add($"第 {i + 1} 局异常：{e.GetType().Name}: {e.Message}");
                    return summary;
                }

                summary.Wins += r.Outcome == "win" ? 1 : 0;
                summary.Losses += r.Outcome == "lose" ? 1 : 0;
                summary.Draws += r.Outcome == "draw" ? 1 : 0;
                summary.AvgPlayerHp += r.PlayerBaseHp;
                summary.AvgEnemyHp += r.EnemyBaseHp;
                summary.AvgPlayerHpPct += r.PlayerBaseHpStart > 0.0 ? r.PlayerBaseHp / r.PlayerBaseHpStart : 0.0;
                summary.AvgSeconds += r.Seconds;
                summary.AvgPlayerSquads += r.PlayerSquadsProduced;
                summary.AvgEnemySquads += r.EnemySquadsSpawned;
                summary.AvgPlayerSquadsLost += r.PlayerSquadsLost;
                summary.AvgPlayerModelsLost += r.PlayerModelsLost;
                summary.AvgEnemyModelsLost += r.EnemyModelsLost;
                summary.AvgPlayerDamage += r.PlayerDamage;
                summary.AvgStuckEvents += r.StuckEvents;
                summary.AvgSlotError += r.AvgSlotErrorMeters;
                summary.AvgEnemyMaxZone += r.EnemyMaxZone;
                summary.AvgPlayerZoneSeconds += r.PlayerZoneSeconds;
                summary.AvgEnemyZoneSeconds += r.EnemyZoneSeconds;
                summary.TotalPlayerKills += r.PlayerKills;
                summary.TotalEnemyKills += r.EnemyKills;
                totalSeconds += r.Seconds;
                foreach (var kv in r.PlayerByUnit)
                {
                    totalMemberSeconds += kv.Value.MemberSeconds;
                    totalSquadSeconds += kv.Value.SquadSeconds;
                }
                if (r.AvgPathLength > 0.0)
                {
                    totalPath += r.AvgPathLength;
                    totalStraight += r.AvgStraightLength;
                    pathGames += 1;
                }
                MergeUnits(summary.PlayerByUnit, r.PlayerByUnit);
                MergeUnits(summary.EnemyByUnit, r.EnemyByUnit);

                foreach (string code in r.ReviewCodes)
                {
                    summary.ReviewCounts.TryGetValue(code, out int n);
                    summary.ReviewCounts[code] = n + 1;
                }

                var row = new SquadSimRow
                {
                    Index = i + 1,
                    Seed = seed,
                    Outcome = r.Outcome,
                    OutcomeText = r.OutcomeText,
                    PlayerHp = Math.Round(r.PlayerBaseHp),
                    EnemyHp = Math.Round(r.EnemyBaseHp),
                    PlayerHpPct = Math.Round((r.PlayerBaseHpStart > 0.0 ? r.PlayerBaseHp / r.PlayerBaseHpStart : 0.0) * 100.0),
                    PlayerSquads = r.PlayerSquadsProduced,
                    EnemySquads = r.EnemySquadsSpawned,
                    PlayerSquadsLost = r.PlayerSquadsLost,
                    EnemySquadsLost = r.EnemySquadsLost,
                    PlayerModelsLost = r.PlayerModelsLost,
                    EnemyModelsLost = r.EnemyModelsLost,
                    PlayerDamage = Math.Round(r.PlayerDamage),
                    EnemyDamage = Math.Round(r.EnemyDamage),
                    DpsPerMember = Math.Round(DpsOf(r.PlayerByUnit), 2),
                    Seconds = r.Seconds,
                    ZoneMax = r.PlayerMaxZone,
                    EnemyZoneMax = r.EnemyMaxZone,
                    PlayerZoneSeconds = Math.Round(r.PlayerZoneSeconds, 1),
                    EnemyZoneSeconds = Math.Round(r.EnemyZoneSeconds, 1),
                    StuckEvents = r.StuckEvents,
                    SlotError = Math.Round(r.AvgSlotErrorMeters, 2),
                    CpLeft = (r.AttackPlan?.CpLeft ?? 0) + (r.DefendPlan?.CpLeft ?? 0),
                    PopBlocked = (r.AttackPlan?.PopBlocked ?? 0) + (r.DefendPlan?.PopBlocked ?? 0),
                    TopReason = r.TopReason,
                };
                summary.Rows.Add(row);

                if (summary.Samples.Count < 3 && r.Outcome != "win") summary.Samples.Add(r);
                else if (winSamples.Count < 3 && r.Outcome == "win") winSamples.Add(r);
            }

            int nGames = summary.Games;
            summary.Ok = summary.Errors.Count == 0;
            summary.WinRate = Math.Round((double)summary.Wins / nGames * 1000.0) / 1000.0;
            summary.AvgPlayerHp = Math.Round(summary.AvgPlayerHp / nGames * 10.0) / 10.0;
            summary.AvgEnemyHp = Math.Round(summary.AvgEnemyHp / nGames * 10.0) / 10.0;
            summary.AvgPlayerHpPct = Math.Round(summary.AvgPlayerHpPct / nGames * 1000.0) / 10.0;
            summary.AvgSeconds = Math.Round(summary.AvgSeconds / nGames * 10.0) / 10.0;
            summary.AvgPlayerSquads = Math.Round(summary.AvgPlayerSquads / nGames * 10.0) / 10.0;
            summary.AvgEnemySquads = Math.Round(summary.AvgEnemySquads / nGames * 10.0) / 10.0;
            summary.AvgPlayerSquadsLost = Math.Round(summary.AvgPlayerSquadsLost / nGames * 10.0) / 10.0;
            summary.AvgPlayerModelsLost = Math.Round(summary.AvgPlayerModelsLost / nGames * 10.0) / 10.0;
            summary.AvgEnemyModelsLost = Math.Round(summary.AvgEnemyModelsLost / nGames * 10.0) / 10.0;
            summary.AvgPlayerDamage = Math.Round(summary.AvgPlayerDamage / nGames * 10.0) / 10.0;
            summary.AvgStuckEvents = Math.Round(summary.AvgStuckEvents / nGames * 10.0) / 10.0;
            summary.AvgEnemyMaxZone = (int)Math.Round((double)summary.AvgEnemyMaxZone / nGames);
            summary.AvgPlayerZoneSeconds = Math.Round(summary.AvgPlayerZoneSeconds / nGames * 10.0) / 10.0;
            summary.AvgEnemyZoneSeconds = Math.Round(summary.AvgEnemyZoneSeconds / nGames * 10.0) / 10.0;
            summary.AvgSlotError = Math.Round(summary.AvgSlotError / nGames * 1000.0) / 1000.0;
            summary.AvgPlayerDps = totalSeconds > 1e-6 ? Math.Round(summary.AvgPlayerDamage * nGames / totalSeconds * 10.0) / 10.0 : 0.0;
            summary.AvgPlayerDpsPerMember = totalMemberSeconds > 1e-6
                ? Math.Round(SumDamage(summary.PlayerByUnit) / totalMemberSeconds * 100.0) / 100.0
                : 0.0;
            summary.AvgPathLength = pathGames > 0 ? Math.Round(totalPath / pathGames * 10.0) / 10.0 : 0.0;
            if (pathGames > 0 && totalStraight > 1e-6)
                summary.AvgPathStraightRatio = Math.Round(totalPath / totalStraight * 1000.0) / 1000.0;

            if (summary.Samples.Count < 3)
            {
                foreach (SquadMatchResult r in winSamples)
                {
                    if (summary.Samples.Count >= 3) break;
                    summary.Samples.Add(r);
                }
            }
            _ = totalSquadSeconds;
            return summary;
        }

        private static void MergeUnits(Dictionary<string, SquadUnitStat> dst, Dictionary<string, SquadUnitStat> src)
        {
            foreach (var kv in src)
            {
                if (!dst.TryGetValue(kv.Key, out SquadUnitStat a))
                {
                    a = new SquadUnitStat { UnitId = kv.Key };
                    dst[kv.Key] = a;
                }
                SquadUnitStat b = kv.Value;
                a.Squads += b.Squads;
                a.Models += b.Models;
                a.Kills += b.Kills;
                a.Losses += b.Losses;
                a.Damage += b.Damage;
                a.MemberSeconds += b.MemberSeconds;
                a.SquadSeconds += b.SquadSeconds;
            }
        }

        private static double SumDamage(Dictionary<string, SquadUnitStat> map)
        {
            double d = 0.0;
            foreach (var kv in map) d += kv.Value.Damage;
            return d;
        }

        private static double DpsOf(Dictionary<string, SquadUnitStat> map)
        {
            double dmg = SumDamage(map);
            double sec = 0.0;
            foreach (var kv in map) sec += kv.Value.MemberSeconds;
            return sec > 1e-6 ? dmg / sec : 0.0;
        }
    }
}
