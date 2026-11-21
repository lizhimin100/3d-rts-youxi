using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>100 局报告里的一行。</summary>
    public sealed class SimRow
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
        public int PlayerLosses;
        public int EnemyLosses;
        public double BaseDamage;
        public int ZoneMax;
        public int PikeBehind;
        public int PikeAttacks;
        public double PikeFormationRate;
        public int CpLeft;
        public int PopBlocked;
        public string TopReason = "";
    }

    /// <summary>一批推演的汇总（--simulate 的返回）。</summary>
    public sealed class SimSummary
    {
        public bool Ok;
        public string LevelId = "";
        public string LevelName = "";
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
        public double AvgPikeBehindRate;
        public double AvgPikeGapCm;
        public readonly Dictionary<string, int> ReviewCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        public readonly List<SimRow> Rows = new List<SimRow>();
        public readonly List<LevelResult> Samples = new List<LevelResult>();
        public readonly List<string> Errors = new List<string>();
    }

    /// <summary>
    /// 第 1 关批量推演：每局独立种子，跑完整的两轮 90 秒 + 规划 + 复盘。
    /// 纯 Model 逻辑，不读引擎时间/帧率；同 seed + 同配置 = 同结果。
    /// </summary>
    public static class LevelSimulator
    {
        public static SimSummary Run(
            UnitCatalog units,
            CombatRules combat,
            PlanningConfig planning,
            LevelSet levels,
            string levelId,
            int games,
            int seedBase)
        {
            var summary = new SimSummary
            {
                LevelId = levelId,
                SeedBase = seedBase,
                Games = Math.Max(1, Math.Min(games, 500)),
            };

            var level = levels != null ? levels.Get(levelId) : null;
            if (level == null)
            {
                summary.Ok = false;
                summary.Errors.Add("找不到关卡：" + levelId);
                return summary;
            }
            summary.LevelId = level.Id;
            summary.LevelName = level.DisplayName;

            int pikeGames = 0;
            double gapWeighted = 0.0;
            int gapSamples = 0;
            var winSamples = new List<LevelResult>();
            for (int i = 0; i < summary.Games; i++)
            {
                int seed = seedBase + i;
                LevelResult r;
                try
                {
                    r = LevelRunner.Run(units, combat, planning, level, seed);
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
                summary.AvgSeconds += r.Seconds;
                summary.AvgPlayerHpPct += r.PlayerBaseHpStart > 0.0 ? r.PlayerBaseHp / r.PlayerBaseHpStart : 0.0;
                summary.AvgPlayerSquads += r.PlayerSquadsProduced;
                summary.AvgEnemySquads += r.EnemySquadsSpawned;
                if (r.PikeAttacks > 0)
                {
                    pikeGames += 1;
                    summary.AvgPikeBehindRate += r.PikeBehindRate;
                }
                if (r.PikeGapSamples > 0)
                {
                    gapWeighted += r.AvgPikeGapMeters * r.PikeGapSamples;
                    gapSamples += r.PikeGapSamples;
                }

                foreach (var code in r.ReviewCodes)
                {
                    summary.ReviewCounts.TryGetValue(code, out int n);
                    summary.ReviewCounts[code] = n + 1;
                }

                var atk = r.AttackPlan;
                var def = r.DefendPlan;
                var row = new SimRow
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
                    PlayerLosses = r.PlayerModelsLost,
                    EnemyLosses = r.EnemyModelsLost,
                    BaseDamage = Math.Round(r.PlayerBaseDamage),
                    ZoneMax = r.PlayerMaxZone,
                    PikeBehind = r.PikeBehindAttacks,
                    PikeAttacks = r.PikeAttacks,
                    PikeFormationRate = Math.Round(r.PikeBehindRate * 100.0),
                    CpLeft = (atk?.CpLeft ?? 0) + (def?.CpLeft ?? 0),
                    PopBlocked = (atk?.PopBlocked ?? 0) + (def?.PopBlocked ?? 0),
                    TopReason = r.TopReason,
                };
                summary.Rows.Add(row);

                // 样本：优先留战败局，方便原样贴出“定性战败复盘”
                if (summary.Samples.Count < 3 && r.Outcome != "win")
                    summary.Samples.Add(r);
                else if (winSamples.Count < 3 && r.Outcome == "win")
                    winSamples.Add(r);
            }

            int nGames = summary.Games;
            summary.Ok = summary.Errors.Count == 0;
            summary.WinRate = Math.Round((double)summary.Wins / nGames * 1000.0) / 1000.0;
            summary.AvgPlayerHp = Math.Round(summary.AvgPlayerHp / nGames * 10.0) / 10.0;
            summary.AvgEnemyHp = Math.Round(summary.AvgEnemyHp / nGames * 10.0) / 10.0;
            summary.AvgSeconds = Math.Round(summary.AvgSeconds / nGames * 10.0) / 10.0;
            summary.AvgPlayerHpPct = Math.Round(summary.AvgPlayerHpPct / nGames * 1000.0) / 10.0;
            summary.AvgPlayerSquads = Math.Round(summary.AvgPlayerSquads / nGames * 10.0) / 10.0;
            summary.AvgEnemySquads = Math.Round(summary.AvgEnemySquads / nGames * 10.0) / 10.0;
            if (pikeGames > 0)
            {
                summary.AvgPikeBehindRate = Math.Round(summary.AvgPikeBehindRate / pikeGames * 1000.0) / 1000.0;
            }
            if (gapSamples > 0)
            {
                summary.AvgPikeGapCm = Math.Round(gapWeighted / gapSamples * 1000.0) / 10.0;
            }

            if (summary.Samples.Count < 3)
            {
                foreach (var r in winSamples)
                {
                    if (summary.Samples.Count >= 3) break;
                    summary.Samples.Add(r);
                }
            }
            return summary;
        }
    }
}
