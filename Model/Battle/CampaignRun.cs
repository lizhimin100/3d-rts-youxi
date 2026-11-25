using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>整场战役（单轮单场死斗循环）的结果。</summary>
    public sealed class CampaignResult
    {
        public string LevelId = "";
        public string LevelName = "";
        public int Seed;
        public string Outcome = "";      // win / lose / draw
        public string OutcomeText = "";
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        public double PlayerBaseHpStart;
        public double EnemyBaseHpStart;
        public int Rounds;
        public double Seconds;
        public int PlayerUnitsProduced;
        public int EnemyUnitsSpawned;

        public readonly List<RoundResult> RoundResults = new List<RoundResult>();
        public readonly List<string> Notes = new List<string>();

        /// <summary>战败简报（只有战败时非空）：败于第几轮 + 敌方主力击杀 + 致命扣血单位。</summary>
        public string DefeatRecord = "";
        public readonly List<string> DefeatKillers = new List<string>();
        public readonly List<string> DefeatFatalUnits = new List<string>();

        public int BerserkRounds;
        public int TieDiffRounds;
        public double PlayerBaseDamageDealt;
        public double PlayerBaseDamageTaken;
    }

    /// <summary>
    /// 战役循环（唯一规则实现）：
    ///   BoardSession（规划/建造/升星）→ ArmyPlan → BattleSession（单场 60 秒死斗）
    ///   → RoundResolver（幸存 base_damage 扣基地）→ 回到 BoardSession 下一轮，
    ///   直至一方基地血量归零或达到轮次上限（僵持）。
    ///
    /// 不再有进攻轮/防守轮：每一轮的差别只有 levels.json 里 `rounds[i].enemy_waves`。
    /// </summary>
    public static class CampaignRun
    {
        public const int MaxRounds = 12;

        public static CampaignResult Run(
            UnitCatalog units,
            CombatRules rules,
            PlanningConfig planning,
            IDictionary<string, object> shell,
            IDictionary<string, object> layout,
            BattleArena arena,
            LevelDef level,
            int seed,
            IDictionary<string, object> tuningDict = null)
        {
            var result = new CampaignResult
            {
                LevelId = level != null ? level.Id : "",
                LevelName = level != null ? level.DisplayName : "",
                Seed = seed,
                PlayerBaseHpStart = level != null ? level.PlayerBaseHp : 0.0,
                EnemyBaseHpStart = level != null ? level.EnemyBaseHp : 0.0,
            };
            if (units == null || rules == null || planning == null || arena == null || level == null)
            {
                result.Outcome = "draw";
                result.OutcomeText = "缺数据，无法开战";
                return result;
            }

            var tuning = BattleTuning.FromDict(tuningDict);
            var notes = new List<string>();
            BoardSession board = BoardSession.Create(planning, units, shell, layout, seed, notes);
            result.Notes.AddRange(notes);

            double playerHp = Math.Max(level.PlayerBaseHp, 0.0);
            double enemyHp = Math.Max(level.EnemyBaseHp, 0.0);

            for (int ri = 0; ri < MaxRounds && playerHp > 0.0 && enemyHp > 0.0; ri++)
            {
                board.BeginPlanning();
                ScriptedPlanner.Plan(board);
                board.EndPlanning();
                ArmyPlan plan = board.BuildArmyPlan();
                result.PlayerUnitsProduced += plan.UnitCount;

                LevelRound round = level.Rounds.Count > 0
                    ? level.Rounds[Math.Min(ri, level.Rounds.Count - 1)]
                    : new LevelRound { Label = $"第 {ri + 1} 轮" };
                if (string.IsNullOrEmpty(round.Label)) round.Label = $"第 {ri + 1} 轮";

                RoundResult rr = BattleSession.Run(
                    units, rules, planning, arena, level, round, ri, plan,
                    playerHp, enemyHp, seed + 7919 * (ri + 1), tuning);

                result.RoundResults.Add(rr);
                result.PlayerBaseDamageDealt += rr.PlayerBaseDamageApplied;
                result.PlayerBaseDamageTaken += rr.EnemyBaseDamageApplied;
                if (rr.BerserkTriggered) result.BerserkRounds += 1;
                if (rr.TieDiffUsed) result.TieDiffRounds += 1;
                if (rr.Stats != null) result.EnemyUnitsSpawned += rr.Stats.EnemyUnitsSpawned;

                playerHp = rr.PlayerBaseHpAfter;
                enemyHp = rr.EnemyBaseHpAfter;
            }

            result.Rounds = result.RoundResults.Count;
            result.PlayerBaseHp = Math.Max(playerHp, 0.0);
            result.EnemyBaseHp = Math.Max(enemyHp, 0.0);
            double sec = 0.0;
            foreach (RoundResult rr in result.RoundResults) sec += rr.Seconds;
            result.Seconds = Math.Round(sec * 10.0) / 10.0;

            if (result.PlayerBaseHp <= 0.0 && result.EnemyBaseHp <= 0.0)
            {
                result.Outcome = "draw";
                result.OutcomeText = "平局 · 同归于尽";
            }
            else if (result.EnemyBaseHp <= 0.0)
            {
                result.Outcome = "win";
                result.OutcomeText = $"胜利 · 第 {result.Rounds} 轮拆掉敌方基地（我方剩 {result.PlayerBaseHp:0}）";
            }
            else if (result.PlayerBaseHp <= 0.0)
            {
                result.Outcome = "lose";
                result.OutcomeText = $"战败 · 第 {result.Rounds} 轮基地被破";
                BuildDefeatRecord(result);
            }
            else
            {
                result.Outcome = "draw";
                result.OutcomeText = $"僵持 · {MaxRounds} 轮仍未分出胜负（我方 {result.PlayerBaseHp:0} / 敌方 {result.EnemyBaseHp:0}）";
            }
            return result;
        }

        /// <summary>
        /// 战败简报（唯一实现）：不构建全场 DPS/承伤报表，只回答"败于哪一轮、谁打死的、谁打穿基地"。
        /// </summary>
        private static void BuildDefeatRecord(CampaignResult result)
        {
            RoundResult last = result.RoundResults.Count > 0
                ? result.RoundResults[result.RoundResults.Count - 1]
                : null;
            if (last == null) return;

            result.DefeatKillers.Clear();
            if (last.Stats != null)
            {
                var rows = new List<KeyValuePair<string, int>>();
                foreach (var kv in last.Stats.EnemyByUnit)
                {
                    if (kv.Value.Kills > 0) rows.Add(new KeyValuePair<string, int>(kv.Key, kv.Value.Kills));
                }
                rows.Sort((a, b) =>
                {
                    int c = b.Value.CompareTo(a.Value);
                    if (c != 0) return c;
                    return string.CompareOrdinal(a.Key, b.Key);
                });
                for (int i = 0; i < rows.Count && i < 3; i++)
                    result.DefeatKillers.Add($"{rows[i].Key}（{rows[i].Value} 杀）");
            }
            result.DefeatFatalUnits.Clear();
            result.DefeatFatalUnits.AddRange(last.EnemyFatalUnits);

            string killers = result.DefeatKillers.Count > 0 ? string.Join("、", result.DefeatKillers) : "（无击杀记录）";
            string fatal = result.DefeatFatalUnits.Count > 0 ? string.Join("、", result.DefeatFatalUnits) : "（无幸存单位）";
            result.DefeatRecord =
                $"败于第 {last.Index + 1} 轮（{last.Label}）；" +
                $"敌方主力击杀：{killers}；" +
                $"致命扣血：{fatal}，扣 {last.EnemyBaseDamageApplied:0.#} 点，基地 {last.PlayerBaseHpBefore:0} → 0。";
        }
    }
}
