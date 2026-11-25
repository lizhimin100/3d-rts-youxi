using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    public sealed class MatchRound
    {
        /// <summary>轮次标签（"第 1 轮"…）。2026-11-24 起不再有 attack/defend。</summary>
        public string Kind = "";
        public string Label = "";
        public double Seconds;
        public double PlayerBaseHpStart;
        public double PlayerBaseHp;
        public double EnemyBaseHpStart;
        public double EnemyBaseHp;
        public bool PlayerBaseDestroyed;
        public bool EnemyBaseDestroyed;
        /// <summary>本轮按幸存 base_damage 打出的伤害（唯一扣血口径）。</summary>
        public double PlayerBaseDamage;
        public double EnemyBaseDamage;
        public bool TieDiffUsed;
        public bool BerserkTriggered;
        public BattleStats Stats;
    }

    /// <summary>一局（单轮单场死斗循环）的战斗结果。</summary>
    public sealed class MatchResult
    {
        public string ArenaId = "";
        public string ArenaName = "";
        public int Seed;
        public string Outcome = "";
        public string OutcomeText = "";
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        public double PlayerBaseHpStart;
        public double EnemyBaseHpStart;
        public double Seconds;
        public int PlayerUnitsProduced;
        public int EnemyUnitsProduced;

        public readonly List<MatchRound> Rounds = new List<MatchRound>();
        /// <summary>本局最后一份规划快照（单轮制只保留一份，字段名沿用旧契约）。</summary>
        public PlanningSnapshot AttackPlan;
        public PlanningSnapshot DefendPlan;

        public readonly Dictionary<string, UnitStat> PlayerByUnit = new Dictionary<string, UnitStat>(StringComparer.Ordinal);
        public readonly Dictionary<string, UnitStat> EnemyByUnit = new Dictionary<string, UnitStat>(StringComparer.Ordinal);

        public double PlayerDamage;
        public double EnemyDamage;
        public int PlayerKills;
        public int EnemyKills;
        public int PlayerUnitsLost;
        public int EnemyUnitsLost;
        public int PlayerMaxZone;
        public int EnemyMaxZone;
        public double PlayerZoneSeconds;
        public double EnemyZoneSeconds;
        public int StuckEvents;
        public int Repaths;
        public double AvgSlotErrorMeters;
        public double AvgPathLength;
        public double AvgStraightLength;
        public double FirstContactSecond = -1.0;

        /// <summary>本局峰值：同一 tick 的深度重叠对数（见 BattleStats）。</summary>
        public int OverlapPairsMax;
        /// <summary>本局峰值：最大重叠深度（游戏数值）。</summary>
        public double OverlapDepthMax;
        /// <summary>最大重叠发生的时刻 / 两个单位 id（诊断用）。</summary>
        public double OverlapWorstTime = -1.0;
        public int OverlapWorstA = -1;
        public int OverlapWorstB = -1;
        /// <summary>本局峰值：分离之后仍残留的深度重叠（玩家可见）。</summary>
        public int OverlapPairsAfterMax;
        public double OverlapDepthAfterMax;
        /// <summary>本局：分离之后仍有深度重叠的 tick 数。</summary>
        public int OverlapAfterTicks;
        /// <summary>本局累计：已进攻击态却打不出去的"人·秒"。</summary>
        public double UnfiredEngagedSeconds;
        /// <summary>本局朝向反转次数 / 战斗秒数。</summary>
        public int HeadingFlips;
        public double HeadingFlipsPerSec;

        // ---- 2026-11-24：单轮死斗读数 ----
        public int RoundsPlayed;
        public double PlayerBaseDamageDealt;
        public double EnemyBaseDamageTaken;
        public int BerserkRounds;
        public int TieDiffRounds;
        /// <summary>战败简报（只有战败非空）。</summary>
        public string DefeatRecord = "";

        public readonly List<string> Reviews = new List<string>();
        public readonly List<string> ReviewCodes = new List<string>();
        public string TopReason => ReviewCodes.Count > 0 ? ReviewCodes[0] : "";

        public bool BerserkTriggered => BerserkRounds > 0;
        public bool TieDiffUsed => TieDiffRounds > 0;
    }

    /// <summary>
    /// 一局战役（单轮单场死斗循环）的唯一入口。
    /// 规划 → 战斗 → 结算 → 下一轮，直到一方基地归零；规则全部在
    /// <see cref="CampaignRun"/> / <see cref="BoardSession"/> / <see cref="BattleSession"/> / <see cref="RoundResolver"/>。
    ///
    /// 这里的 `Squad*` 名字是跨语言契约（Phase 3 才改名），不是"小队编制"。
    /// </summary>
    public static class MatchRun
    {
        public static MatchResult Run(
            UnitCatalog units,
            CombatRules combat,
            PlanningConfig planning,
            BattleArena arena,
            int seed,
            IDictionary<string, object> tuning = null)
        {
            var result = new MatchResult
            {
                ArenaId = arena != null ? arena.Id : "",
                ArenaName = arena != null ? arena.DisplayName : "",
                Seed = seed,
            };
            if (arena == null || arena.Level == null)
            {
                result.Outcome = "draw";
                result.OutcomeText = "缺关卡";
                return result;
            }

            CampaignResult campaign = CampaignRun.Run(
                units, combat, planning, arena.ShellDict, arena.LayoutDict, arena, arena.Level, seed, tuning);

            result.PlayerBaseHpStart = campaign.PlayerBaseHpStart;
            result.EnemyBaseHpStart = campaign.EnemyBaseHpStart;
            result.PlayerBaseHp = campaign.PlayerBaseHp;
            result.EnemyBaseHp = campaign.EnemyBaseHp;
            result.Outcome = campaign.Outcome;
            result.OutcomeText = campaign.OutcomeText;
            result.Seconds = campaign.Seconds;
            result.PlayerUnitsProduced = campaign.PlayerUnitsProduced;
            result.EnemyUnitsProduced = campaign.EnemyUnitsSpawned;
            result.RoundsPlayed = campaign.Rounds;
            result.PlayerBaseDamageDealt = campaign.PlayerBaseDamageDealt;
            result.EnemyBaseDamageTaken = campaign.PlayerBaseDamageTaken;
            result.BerserkRounds = campaign.BerserkRounds;
            result.TieDiffRounds = campaign.TieDiffRounds;
            result.DefeatRecord = campaign.DefeatRecord;

            for (int i = 0; i < campaign.RoundResults.Count; i++)
            {
                RoundResult rr = campaign.RoundResults[i];
                result.Rounds.Add(new MatchRound
                {
                    Kind = rr.Label,
                    Label = rr.Label,
                    Seconds = rr.Seconds,
                    PlayerBaseHpStart = rr.PlayerBaseHpBefore,
                    PlayerBaseHp = rr.PlayerBaseHpAfter,
                    EnemyBaseHpStart = rr.EnemyBaseHpBefore,
                    EnemyBaseHp = rr.EnemyBaseHpAfter,
                    PlayerBaseDestroyed = rr.PlayerBaseHpAfter <= 0.0,
                    EnemyBaseDestroyed = rr.EnemyBaseHpAfter <= 0.0,
                    PlayerBaseDamage = rr.PlayerBaseDamageApplied,
                    EnemyBaseDamage = rr.EnemyBaseDamageApplied,
                    TieDiffUsed = rr.TieDiffUsed,
                    BerserkTriggered = rr.BerserkTriggered,
                    Stats = rr.Stats,
                });
                Merge(result, rr.Stats);
            }

            result.HeadingFlipsPerSec = result.Seconds > 1e-6
                ? Math.Round(result.HeadingFlips / result.Seconds, 2)
                : 0.0;
            int rounds = Math.Max(result.Rounds.Count, 1);
            result.AvgSlotErrorMeters = Math.Round(result.AvgSlotErrorMeters / rounds, 3);
            result.AvgPathLength = Math.Round(result.AvgPathLength / rounds, 1);
            result.AvgStraightLength = Math.Round(result.AvgStraightLength / rounds, 1);

            BuildReview(result, campaign);
            return result;
        }

        private static void Merge(MatchResult r, BattleStats s)
        {
            if (s == null) return;
            r.PlayerDamage += s.PlayerDamage;
            r.EnemyDamage += s.EnemyDamage;
            r.PlayerKills += s.PlayerKills;
            r.EnemyKills += s.EnemyKills;
            
            
            r.PlayerUnitsLost += s.PlayerUnitsLost;
            r.EnemyUnitsLost += s.EnemyUnitsLost;
            r.StuckEvents += s.StuckEvents;
            r.Repaths += s.Repaths;
            
            r.AvgPathLength += s.AvgPathLength;
            r.AvgStraightLength += s.AvgStraightLength;
            if (r.FirstContactSecond < 0.0) r.FirstContactSecond = s.FirstContactSecond;
            if (s.OverlapPairsMax > r.OverlapPairsMax) r.OverlapPairsMax = s.OverlapPairsMax;
            if (s.OverlapPairsAfterMax > r.OverlapPairsAfterMax) r.OverlapPairsAfterMax = s.OverlapPairsAfterMax;
            if (s.OverlapDepthAfterMax > r.OverlapDepthAfterMax) r.OverlapDepthAfterMax = s.OverlapDepthAfterMax;
            r.OverlapAfterTicks += s.OverlapAfterTicks;
            if (s.OverlapDepthMax > r.OverlapDepthMax)
            {
                r.OverlapDepthMax = s.OverlapDepthMax;
                r.OverlapWorstTime = s.OverlapWorstTime;
                r.OverlapWorstA = s.OverlapWorstA;
                r.OverlapWorstB = s.OverlapWorstB;
            }
            r.UnfiredEngagedSeconds += s.UnfiredEngagedSeconds;
            r.HeadingFlips += s.HeadingFlips;
            MergeUnits(r.PlayerByUnit, s.PlayerByUnit);
            MergeUnits(r.EnemyByUnit, s.EnemyByUnit);
        }

        private static void MergeUnits(Dictionary<string, UnitStat> dst, Dictionary<string, UnitStat> src)
        {
            if (src == null) return;
            foreach (var kv in src)
            {
                if (!dst.TryGetValue(kv.Key, out UnitStat a))
                {
                    a = new UnitStat { UnitId = kv.Key };
                    dst[kv.Key] = a;
                }
                UnitStat b = kv.Value;
                a.Units += b.Units;
                
                a.Kills += b.Kills;
                a.Losses += b.Losses;
                a.Damage += b.Damage;
                a.AliveSeconds += b.AliveSeconds;
                
            }
        }

        /// <summary>
        /// 定性复盘：胜利只留一句总结；战败只留简要死因（不再构建全场统计报表）。
        /// </summary>
        private static void BuildReview(MatchResult r, CampaignResult c)
        {
            r.Reviews.Clear();
            r.ReviewCodes.Clear();

            if (r.Outcome == "win")
            {
                r.ReviewCodes.Add("win");
                r.Reviews.Add($"胜利：{r.RoundsPlayed} 轮打完，敌方基地 {r.EnemyBaseHpStart:0} → 0；我方剩 {r.PlayerBaseHp:0}。");
                return;
            }
            if (r.Outcome == "draw")
            {
                r.ReviewCodes.Add("stalemate");
                r.Reviews.Add(r.OutcomeText);
                return;
            }

            r.ReviewCodes.Add("defeat");
            r.Reviews.Add(string.IsNullOrEmpty(r.DefeatRecord) ? r.OutcomeText : r.DefeatRecord);
            if (c != null && c.DefeatKillers.Count > 0)
                r.Reviews.Add("敌方主力：" + string.Join("、", c.DefeatKillers));
        }
    }
}
