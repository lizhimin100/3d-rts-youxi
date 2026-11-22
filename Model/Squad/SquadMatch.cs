using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    public sealed class SquadRoundResult
    {
        public string Kind = "";
        public string Label = "";
        public double Seconds;
        public double PlayerBaseHpStart;
        public double PlayerBaseHp;
        public double EnemyBaseHpStart;
        public double EnemyBaseHp;
        public bool PlayerBaseDestroyed;
        public bool EnemyBaseDestroyed;
        public SquadBattleStats Stats;
    }

    /// <summary>一局（两轮各 60 秒）的小队战斗结果。</summary>
    public sealed class SquadMatchResult
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
        public int PlayerSquadsProduced;
        public int EnemySquadsSpawned;

        public readonly List<SquadRoundResult> Rounds = new List<SquadRoundResult>();
        public PlanningSnapshot AttackPlan;
        public PlanningSnapshot DefendPlan;

        public readonly Dictionary<string, SquadUnitStat> PlayerByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);
        public readonly Dictionary<string, SquadUnitStat> EnemyByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);

        public double PlayerDamage;
        public double EnemyDamage;
        public int PlayerKills;
        public int EnemyKills;
        public int PlayerModelsLost;
        public int EnemyModelsLost;
        public int PlayerSquadsLost;
        public int EnemySquadsLost;
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

        public readonly List<string> Reviews = new List<string>();
        public readonly List<string> ReviewCodes = new List<string>();
        public string TopReason => ReviewCodes.Count > 0 ? ReviewCodes[0] : "";
    }

    /// <summary>
    /// 双 60 秒小队对局：规划（ScriptedPlanner）→ 出兵落格子锚点 → 脊线推进 → 6 步结算 → 轮末清场。
    /// 纯 Model，不读引擎时间；同 seed + 同数据 = 同结果。
    ///
    /// 限时口径（2026-11-21）：单场 60 秒（<see cref="LevelDef.RoundSecondsSpec"/>）。
    /// **60 秒未全歼 = 平局且不加伤**：没有"到点强行破僵 / 按剩余血量补刀"这类机制，
    /// 到点就结算，基地血量只在抽血（zone_dps）真正发生时下降。
    /// </summary>
    public static class SquadMatch
    {
        public static SquadMatchResult Run(
            UnitCatalog units,
            CombatRules combat,
            PlanningConfig planning,
            SquadArena arena,
            int seed,
            IDictionary<string, object> tuning = null)
        {
            var result = new SquadMatchResult
            {
                ArenaId = arena.Id,
                ArenaName = arena.DisplayName,
                Seed = seed,
                PlayerBaseHpStart = arena.PlayerBaseHp,
                EnemyBaseHpStart = arena.EnemyBaseHp,
            };

            double playerHp = arena.PlayerBaseHp;
            double enemyHp = arena.EnemyBaseHp;

            for (int ri = 0; ri < arena.Rounds.Count; ri++)
            {
                if (playerHp <= 0.0 || enemyHp <= 0.0) break;
                LevelRound round = arena.Rounds[ri];
                bool defending = round.Kind == "defend";

                // 攻防时空流转：本轮只出"这一场"的队伍（attack 轮出进攻牌，defend 轮出防守牌）。
                string roundRole = defending ? SquadRoles.Defend : SquadRoles.Attack;
                var session = new SquadSession(
                    units, combat, planning, arena,
                    seed + 7919 * (ri + 1), false, playerHp, enemyHp, tuning);
                session.BeginPlanning();
                ScriptedPlanner.Plan(session.Match, defending, roundRole);
                PlanningSnapshot snap = session.Match.Snapshot();
                if (round.Kind == "attack") result.AttackPlan = snap;
                else if (round.Kind == "defend") result.DefendPlan = snap;

                session.Battle.SetDrainReduction(snap != null ? snap.DrainReduction : 0.0, 0.0);
                session.EndPlanning(true);
                session.Battle.SetActiveRole(roundRole);
                session.BeginExecution(ri);

                // **预设偏好**由 SquadSession.BeginAttack / BeginDefend 内部的 PushForward 下达：
                //   进攻战 → 压向敌方基地（胜利条件就是拆家）；
                //   防守战 → 前出到玩家区前缘迎战（**不能也去拆家**，否则老家没人守，
                //            敌方波次直接把基地抽干 —— 这是 2026-11-22 实测到的一个配平陷阱）。
                // 推演与试玩共用同一份偏好，这里不再另写一条"侧翼绕行"的规则。

                SquadBattleStats stats = session.Battle.Run(arena.RoundSeconds);
                var rr = new SquadRoundResult
                {
                    Kind = round.Kind,
                    Label = round.Label,
                    Seconds = Math.Round(session.Battle.Time * 10.0) / 10.0,
                    PlayerBaseHpStart = playerHp,
                    EnemyBaseHpStart = enemyHp,
                    PlayerBaseHp = session.Battle.PlayerBaseHp,
                    EnemyBaseHp = session.Battle.EnemyBaseHp,
                    PlayerBaseDestroyed = session.Battle.PlayerBaseHp <= 0.0,
                    EnemyBaseDestroyed = session.Battle.EnemyBaseHp <= 0.0,
                    Stats = stats,
                };
                result.Rounds.Add(rr);
                playerHp = rr.PlayerBaseHp;
                enemyHp = rr.EnemyBaseHp;
                Merge(result, stats);
            }

            result.PlayerBaseHp = Math.Max(playerHp, 0.0);
            result.EnemyBaseHp = Math.Max(enemyHp, 0.0);
            double seconds = 0.0;
            foreach (SquadRoundResult rr in result.Rounds) seconds += rr.Seconds;
            result.Seconds = Math.Round(seconds * 10.0) / 10.0;
            result.PlayerSquadsProduced = (result.AttackPlan?.ArmySquads ?? 0) + (result.DefendPlan?.ArmySquads ?? 0);
            result.EnemySquadsSpawned = 0;
            foreach (SquadRoundResult rr in result.Rounds) result.EnemySquadsSpawned += rr.Stats.EnemySquadsSpawned;
            int statRounds = result.Rounds.Count;
            if (statRounds > 0)
            {
                result.AvgSlotErrorMeters = Math.Round(result.AvgSlotErrorMeters / statRounds, 3);
                result.AvgPathLength = Math.Round(result.AvgPathLength / statRounds, 1);
                result.AvgStraightLength = Math.Round(result.AvgStraightLength / statRounds, 1);
            }

            DecideOutcome(result);
            BuildReview(result);
            return result;
        }

        private static void Merge(SquadMatchResult r, SquadBattleStats s)
        {
            if (s == null) return;
            r.PlayerDamage += s.PlayerDamage;
            r.EnemyDamage += s.EnemyDamage;
            r.PlayerKills += s.PlayerKills;
            r.EnemyKills += s.EnemyKills;
            r.PlayerModelsLost += s.PlayerModelsLost;
            r.EnemyModelsLost += s.EnemyModelsLost;
            r.PlayerSquadsLost += s.PlayerSquadsLost;
            r.EnemySquadsLost += s.EnemySquadsLost;
            r.PlayerMaxZone = Math.Max(r.PlayerMaxZone, s.PlayerMaxZone);
            r.EnemyMaxZone = Math.Max(r.EnemyMaxZone, s.EnemyMaxZone);
            r.PlayerZoneSeconds += s.PlayerZoneSeconds;
            r.EnemyZoneSeconds += s.EnemyZoneSeconds;
            r.StuckEvents += s.StuckEvents;
            r.Repaths += s.Repaths;
            r.AvgSlotErrorMeters += s.AvgSlotErrorMeters;
            r.AvgPathLength += s.AvgPathLength;
            r.AvgStraightLength += s.AvgStraightLength;
            if (r.FirstContactSecond < 0.0) r.FirstContactSecond = s.FirstContactSecond;
            MergeUnits(r.PlayerByUnit, s.PlayerByUnit);
            MergeUnits(r.EnemyByUnit, s.EnemyByUnit);
        }

        private static void MergeUnits(Dictionary<string, SquadUnitStat> dst, Dictionary<string, SquadUnitStat> src)
        {
            if (src == null) return;
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

        private static void DecideOutcome(SquadMatchResult r)
        {
            bool playerDead = r.PlayerBaseHp <= 0.0;
            bool enemyDead = r.EnemyBaseHp <= 0.0;
            if (playerDead && enemyDead)
            {
                r.Outcome = "draw";
                r.OutcomeText = "平局 · 同归于尽";
            }
            else if (enemyDead)
            {
                r.Outcome = "win";
                r.OutcomeText = "胜利 · 拆掉敌方基地";
            }
            else if (playerDead)
            {
                r.Outcome = "lose";
                r.OutcomeText = "战败 · 基地被破";
            }
            else
            {
                // 2026-11-21：到点未全歼 = **平局**，不加伤、不破僵。
                r.Outcome = "draw";
                r.OutcomeText = "平局 · 60 秒未全歼（不减血、不加伤）";
            }
        }

        private static void BuildReview(SquadMatchResult r)
        {
            r.Reviews.Clear();
            r.ReviewCodes.Clear();

            if (r.Outcome == "win")
            {
                r.ReviewCodes.Add("win");
                r.Reviews.Add($"胜利：敌方基地 {r.EnemyBaseHpStart:0} → 0；我方基地剩 {Percent(r.PlayerBaseHp, r.PlayerBaseHpStart)}。");
                r.Reviews.Add($"单兵：出兵 {r.PlayerSquadsProduced} 名 / 阵亡 {r.PlayerSquadsLost} 名，人均 DPS {Dps(r.PlayerByUnit):0.0}。");
                if (r.StuckEvents > 0)
                    r.Reviews.Add($"寻路：卡住脱困 {r.StuckEvents} 次，重规划 {r.Repaths} 次（脊线 + 局部避障）。");
                return;
            }

            var reasons = new List<(int Sev, string Code, string Text)>();
            int totalSquads = (r.AttackPlan?.ArmySquads ?? 0) + (r.DefendPlan?.ArmySquads ?? 0);
            int totalBlocked = (r.AttackPlan?.PopBlocked ?? 0) + (r.DefendPlan?.PopBlocked ?? 0);

            if (totalSquads == 0)
                reasons.Add((100, "no_army", "两轮规划一个人都没出：CP 没落到征召牌上。"));
            if (r.EnemyBaseHp > 0.0 && r.EnemyBaseHp < r.EnemyBaseHpStart * 0.1)
                reasons.Add((96, "close_loss", $"差一点：敌方基地只剩 {r.EnemyBaseHp:0}/{r.EnemyBaseHpStart:0}。"));
            if (r.PlayerBaseHp <= 0.0)
                reasons.Add((98, "base_breach", $"基地被破：敌方最多 {r.EnemyMaxZone} 名同时停在我方区域抽血。"));
            if (r.PlayerSquadsLost >= 3 && r.EnemySquadsLost == 0)
                reasons.Add((92, "squad_wiped", $"被打穿：我方阵亡 {r.PlayerSquadsLost} 名，敌方一人未灭。"));
            if (r.PlayerDamage <= 0.0 && totalSquads > 0)
                reasons.Add((94, "no_dps", "一个人都没打中：射程/阵型/克制可能完全没接上。"));
            if (r.StuckEvents >= 6)
                reasons.Add((84, "path_stuck", $"寻路卡住 {r.StuckEvents} 次（重规划 {r.Repaths} 次），单兵在狭道里互相挡路。"));
            if (r.AvgSlotErrorMeters > 0.9)
                reasons.Add((80, "slot_loose", $"站位松散：平均偏离 {r.AvgSlotErrorMeters:0.00} 米（理想 < 0.6）。"));
            if (r.EnemyModelsLost > 0 && r.PlayerModelsLost > r.EnemyModelsLost * 1.3)
                reasons.Add((86, "exchange", $"交换比失衡：我方阵亡 {r.PlayerModelsLost} 人，敌方 {r.EnemyModelsLost} 人。"));
            if (totalBlocked > 0)
                reasons.Add((72, "pop_blocked", $"人口卡死：共 {totalBlocked} 次训练被人口挡住。"));
            if (r.PlayerMaxZone == 0 && r.Rounds.Count > 0 && r.Rounds[0].Kind == "attack")
                reasons.Add((78, "no_zone", "进攻战一次也没摸到敌方基地。"));

            reasons.Sort((a, b) =>
            {
                int c = b.Sev.CompareTo(a.Sev);
                if (c != 0) return c;
                return string.CompareOrdinal(a.Code, b.Code);
            });
            foreach (var reason in reasons)
            {
                if (r.ReviewCodes.Count >= 4) break;
                r.ReviewCodes.Add(reason.Code);
                r.Reviews.Add(reason.Text);
            }
            if (r.Reviews.Count == 0)
            {
                r.ReviewCodes.Add("unexplained_loss");
                r.Reviews.Add($"没有单一短板：敌方基地剩 {r.EnemyBaseHp:0}/{r.EnemyBaseHpStart:0}，我方剩 {r.PlayerBaseHp:0}/{r.PlayerBaseHpStart:0}。");
            }
        }

        private static double Dps(Dictionary<string, SquadUnitStat> map)
        {
            double dmg = 0.0;
            double sec = 0.0;
            foreach (var kv in map)
            {
                dmg += kv.Value.Damage;
                sec += kv.Value.MemberSeconds;
            }
            return sec > 1e-6 ? dmg / sec : 0.0;
        }

        private static string Percent(double v, double max)
        {
            if (max <= 0.0) return "0%";
            return $"{Math.Round(v / max * 100.0):0}%";
        }
    }
}
