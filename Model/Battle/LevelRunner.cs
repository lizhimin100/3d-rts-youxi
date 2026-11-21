using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>一场（两轮 90 秒）的完整结果。</summary>
    public sealed class LevelResult
    {
        public string LevelId = "";
        public string LevelName = "";
        public int Seed;
        public string Outcome = ""; // win / lose / draw
        public string OutcomeText = "";
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        public double PlayerBaseHpStart;
        public double EnemyBaseHpStart;
        public double Seconds;

        public readonly List<RoundResult> Rounds = new List<RoundResult>();
        public PlanningSnapshot AttackPlan;
        public PlanningSnapshot DefendPlan;

        public int PlayerSquadsProduced;
        public int EnemySquadsSpawned;
        public int PlayerModelsLost;
        public int EnemyModelsLost;
        public int MaxPlayerModels;
        public int MaxEnemyModels;
        public double PlayerBaseDamage;
        public double EnemyBaseDamage;
        public int PlayerMaxZone;
        public int EnemyMaxZone;
        public int PikeAttacks;
        public int PikeBehindAttacks;
        public int PikeFormationSamples;
        public int PikeFormationBehind;
        public int PikeGapSamples;
        public double PikeBehindRate;
        public double AvgPikeGapMeters;

        public readonly List<string> Reviews = new List<string>();
        public readonly List<string> ReviewCodes = new List<string>();

        public string TopReason => ReviewCodes.Count > 0 ? ReviewCodes[0] : "";
    }

    /// <summary>
    /// 第 1 关的跑团：规划 → 90 秒进攻 → 再规划 → 90 秒防守 → 定性复盘。
    ///
    /// 基地血量跨轮保留；任一方基地归零立即结束；两轮结束都没拆掉敌方基地 = 未攻克。
    /// 轮末由这里负责“清空全部部队”（每轮 new 一个 LaneBattle，天然清场）。
    /// </summary>
    public static class LevelRunner
    {
        public static LevelResult Run(
            UnitCatalog units,
            CombatRules combat,
            PlanningConfig planning,
            LevelDef level,
            int seed)
        {
            var result = new LevelResult
            {
                LevelId = level.Id,
                LevelName = level.DisplayName,
                Seed = seed,
                PlayerBaseHpStart = level.PlayerBaseHp,
                EnemyBaseHpStart = level.EnemyBaseHp,
            };

            double playerHp = level.PlayerBaseHp;
            double enemyHp = level.EnemyBaseHp;
            var match = new PlanningMatch(planning, units, seed);

            for (int ri = 0; ri < level.Rounds.Count; ri++)
            {
                var round = level.Rounds[ri];
                if (playerHp <= 0.0 || enemyHp <= 0.0) break;

                match.BeginPlanning();
                ScriptedPlanner.Plan(match, round.Kind == "defend");
                var snapshot = match.Snapshot();
                if (round.Kind == "attack") result.AttackPlan = snapshot;
                else if (round.Kind == "defend") result.DefendPlan = snapshot;
                match.EndPlanning();

                var battle = new LaneBattle(units, combat, level.Lane, planning, seed + 7919 * (ri + 1));
                battle.AddArmy(match.Army, match.Mods);
                foreach (var wave in round.Waves) battle.ScheduleWave(wave, 1);

                double reduction = snapshot != null ? snapshot.DrainReduction : 0.0;
                var rr = battle.Run(level.RoundSeconds, playerHp, enemyHp, reduction, 0.0, round.Kind, round.Label);
                result.Rounds.Add(rr);

                playerHp = rr.PlayerBaseHp;
                enemyHp = rr.EnemyBaseHp;
                result.PlayerBaseDamage += rr.PlayerBaseDamage;
                result.EnemyBaseDamage += rr.EnemyBaseDamage;
                result.PikeAttacks += rr.PikeAttacks;
                result.PikeBehindAttacks += rr.PikeBehindAttacks;
                result.PikeFormationSamples += rr.PikeFormationSamples;
                result.PikeFormationBehind += rr.PikeFormationBehind;
                result.PikeGapSamples += rr.PikeGapSamples;
                if (rr.PikeGapSamples > 0)
                    result.AvgPikeGapMeters += rr.AvgPikeGapMeters * rr.PikeGapSamples;
            }

            result.PlayerBaseHp = Math.Max(playerHp, 0.0);
            result.EnemyBaseHp = Math.Max(enemyHp, 0.0);
            result.PlayerSquadsProduced = (result.AttackPlan?.ArmySquads ?? 0) + (result.DefendPlan?.ArmySquads ?? 0);
            result.PlayerModelsLost = 0;
            result.EnemyModelsLost = 0;
            result.MaxPlayerModels = 0;
            result.MaxEnemyModels = 0;
            result.EnemySquadsSpawned = 0;
            result.PlayerMaxZone = 0;
            result.EnemyMaxZone = 0;
            double seconds = 0.0;
            foreach (var rr in result.Rounds)
            {
                result.PlayerModelsLost += rr.PlayerModelsLost;
                result.EnemyModelsLost += rr.EnemyModelsLost;
                if (rr.PlayerMaxModelsAlive > result.MaxPlayerModels) result.MaxPlayerModels = rr.PlayerMaxModelsAlive;
                if (rr.EnemyMaxModelsAlive > result.MaxEnemyModels) result.MaxEnemyModels = rr.EnemyMaxModelsAlive;
                result.EnemySquadsSpawned += rr.EnemySquadsSpawned;
                if (rr.PlayerMaxSquadsInZone > result.PlayerMaxZone) result.PlayerMaxZone = rr.PlayerMaxSquadsInZone;
                if (rr.EnemyMaxSquadsInZone > result.EnemyMaxZone) result.EnemyMaxZone = rr.EnemyMaxSquadsInZone;
                seconds += rr.Seconds;
            }
            result.Seconds = Math.Round(seconds * 10.0) / 10.0;
            if (result.PikeGapSamples > 0)
                result.AvgPikeGapMeters = Math.Round(result.AvgPikeGapMeters / result.PikeGapSamples * 1000.0) / 1000.0;
            else
                result.AvgPikeGapMeters = 0.0;
            result.PikeBehindRate = result.PikeFormationSamples > 0
                ? Math.Round((double)result.PikeFormationBehind / result.PikeFormationSamples * 1000.0) / 1000.0
                : 0.0;

            DecideOutcome(result);
            ReviewBuilder.Build(result);
            return result;
        }

        private static void DecideOutcome(LevelResult r)
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
                r.OutcomeText = "胜利 · 拆掉灰牙前哨";
            }
            else if (playerDead)
            {
                r.Outcome = "lose";
                r.OutcomeText = "战败 · 基地被破";
            }
            else
            {
                r.Outcome = "lose";
                r.OutcomeText = "战败 · 两轮 90 秒内未攻克";
            }
        }
    }

    /// <summary>
    /// 定性复盘：把数字翻译成“为什么输/赢”，并给每个原因一个稳定的 code 供 100 局聚合。
    /// 只从 LevelResult 的真实指标推导，不写死剧本。
    /// </summary>
    public static class ReviewBuilder
    {
        private sealed class Reason
        {
            public int Severity;
            public string Code = "";
            public string Text = "";
        }

        public static void Build(LevelResult r)
        {
            r.Reviews.Clear();
            r.ReviewCodes.Clear();

            if (r.Outcome == "win")
            {
                r.ReviewCodes.Add("win");
                r.Reviews.Add($"胜利：敌方基地 {r.EnemyBaseHpStart:0} → 0，我方基地剩 {Percent(r.PlayerBaseHp, r.PlayerBaseHpStart)}。");
                if (r.PikeAttacks > 0)
                {
                    r.Reviews.Add($"长枪隔排：{r.PikeFormationBehind}/{r.PikeFormationSamples} 次采样在步兵身后（{r.PikeBehindRate:P0}），隔排刺击 {r.PikeBehindAttacks}/{r.PikeAttacks} 次，平均间距 {Cm(r.AvgPikeGapMeters)}（理想 90 cm）。");
                }
                var plan = r.DefendPlan ?? r.AttackPlan;
                if (plan != null)
                {
                    r.Reviews.Add($"规划：{plan.ArmySquads} 队 / {plan.PopUsed} 人口（上限 {plan.PopCap}），最后一轮剩 {plan.CpLeft} CP。");
                }
                return;
            }

            var reasons = new List<Reason>();
            var atk = r.AttackPlan;
            var def = r.DefendPlan;
            int totalSquads = (atk?.ArmySquads ?? 0) + (def?.ArmySquads ?? 0);
            int totalPopBlocked = (atk?.PopBlocked ?? 0) + (def?.PopBlocked ?? 0);
            int totalCpLeft = (atk?.CpLeft ?? 0) + (def?.CpLeft ?? 0);

            if (totalSquads == 0)
                reasons.Add(new Reason { Severity = 100, Code = "no_army", Text = "两轮规划一队兵都没出：CP 没落到训练牌上。" });

            if (r.EnemyBaseHp > 0.0 && r.EnemyBaseHp < r.EnemyBaseHpStart * 0.1)
                reasons.Add(new Reason { Severity = 96, Code = "close_loss", Text = $"差一点：敌方基地只剩 {r.EnemyBaseHp:0}/{r.EnemyBaseHpStart:0}（{r.EnemyBaseHp / r.EnemyBaseHpStart:P0}），再推一波就拆了。" });

            if (r.PlayerBaseHp <= 0.0)
                reasons.Add(new Reason { Severity = 98, Code = "base_breach", Text = $"基地被破：敌方最多 {r.EnemyMaxZone} 队同时停在我方区域抽血。" });
            else if (r.EnemyBaseDamage > 300.0 || r.PlayerBaseHp < r.PlayerBaseHpStart * 0.8)
                reasons.Add(new Reason { Severity = 74, Code = "counter_push", Text = $"被反推：敌方小队抽掉我方基地 {r.EnemyBaseDamage:0} 血，我方只剩 {r.PlayerBaseHp:0}。" });

            if (r.MaxEnemyModels > r.MaxPlayerModels * 1.4 && r.MaxPlayerModels > 0)
                reasons.Add(new Reason { Severity = 90, Code = "outnumbered", Text = $"同屏兵力劣势：敌方最多 {r.MaxEnemyModels} 人 vs 我方 {r.MaxPlayerModels} 人。" });

            if (r.EnemyModelsLost > 0 && r.PlayerModelsLost > r.EnemyModelsLost * 1.3)
                reasons.Add(new Reason { Severity = 85, Code = "exchange", Text = $"交换比失衡：我方阵亡 {r.PlayerModelsLost} 人，敌方 {r.EnemyModelsLost} 人。" });

            double firstLost = FirstSquadLost(r);
            if (firstLost > 0.0 && firstLost < 25.0)
                reasons.Add(new Reason { Severity = 82, Code = "front_collapse", Text = $"前排 {firstLost:0.0} 秒内崩溃（第一队全灭）。" });

            if (r.PlayerMaxZone == 0 && r.Rounds.Count > 0 && r.Rounds[0].Kind == "attack")
                reasons.Add(new Reason { Severity = 78, Code = "no_zone", Text = "进攻战一次也没摸到敌方基地：全歼前就被打光了。" });

            if (totalPopBlocked > 0)
                reasons.Add(new Reason { Severity = 72, Code = "pop_blocked", Text = $"人口卡死：共 {totalPopBlocked} 队训练被人口挡住（上限 {def?.PopCap ?? atk?.PopCap ?? 0}）。" });

            if (r.PikeFormationSamples > 20 && r.PikeBehindRate < 0.6)
                reasons.Add(new Reason { Severity = 66, Code = "pike_gap", Text = $"长枪脱节：只有 {r.PikeBehindRate:P0} 的时间站在步兵身后（采样 {r.PikeFormationSamples} 次），平均间距 {Cm(r.AvgPikeGapMeters)}（理想 90 cm）。" });

            if (totalCpLeft >= 6)
                reasons.Add(new Reason { Severity = 60, Code = "cp_waste", Text = $"CP 浪费：两轮规划结束共剩 {totalCpLeft} 点（没牌可打或没人口）。" });

            if (totalSquads > 0 && r.EnemyModelsLost == 0)
                reasons.Add(new Reason { Severity = 58, Code = "no_kill", Text = "一个人都没打死：伤害类型/护甲克制可能完全打错。" });

            reasons.Sort((a, b) =>
            {
                int c = b.Severity.CompareTo(a.Severity);
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
                r.Reviews.Add($"没有单一短板：敌方基地剩 {r.EnemyBaseHp:0}/{r.EnemyBaseHpStart:0}，我方基地剩 {r.PlayerBaseHp:0}/{r.PlayerBaseHpStart:0}。");
            }
        }

        private static double FirstSquadLost(LevelResult r)
        {
            foreach (var rr in r.Rounds)
            {
                if (rr.FirstPlayerSquadLostSecond > 0.0) return rr.FirstPlayerSquadLostSecond;
            }
            return -1.0;
        }

        private static string Percent(double v, double max)
        {
            if (max <= 0.0) return "0%";
            return $"{Math.Round(v / max * 100.0):0}%";
        }

        private static string Cm(double meters) => $"{Math.Round(meters * 100.0):0} cm";
    }
}
