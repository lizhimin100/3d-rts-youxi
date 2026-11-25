using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 一轮战斗的结果（双场景之间**唯一**的战果交换物）。
    /// 不含坐标、不含实体引用：只有幸存数、基地伤害、狂暴/差值结算标记与死因。
    /// </summary>
    public sealed class RoundResult
    {
        public int Index;
        public string Label = "";
        public double Seconds;
        public int PlayerSurvivors;
        public int EnemySurvivors;
        /// <summary>按幸存单位 base_damage 算出的"应扣伤害"（已封顶）。</summary>
        public double PlayerBaseDamage;
        public double EnemyBaseDamage;
        /// <summary>实际落到基地血上的伤害（差值结算后可能小于应扣）。</summary>
        public double PlayerBaseDamageApplied;
        public double EnemyBaseDamageApplied;
        public double PlayerBaseHpBefore;
        public double EnemyBaseHpBefore;
        public double PlayerBaseHpAfter;
        public double EnemyBaseHpAfter;
        public bool BerserkTriggered;
        public double BerserkSecond = -1.0;
        /// <summary>60 秒到点时双方都还有幸存者 → 走差值结算。</summary>
        public bool TieDiffUsed;
        public bool PlayerWiped;
        public bool EnemyWiped;
        public SquadBattleStats Stats;

        /// <summary>敌方幸存单位中，真正把基地血打穿的那几个（战败简报用）。</summary>
        public readonly List<string> EnemyFatalUnits = new List<string>();
        public readonly List<string> Notes = new List<string>();

        public string Winner
        {
            get
            {
                if (PlayerBaseDamageApplied > EnemyBaseDamageApplied) return "player";
                if (EnemyBaseDamageApplied > PlayerBaseDamageApplied) return "enemy";
                return "draw";
            }
        }
    }

    /// <summary>
    /// 单轮结算（唯一实现）：60 秒到点或一方全灭后，按幸存单位的 base_damage 扣基地血。
    ///
    /// 规则（2026-11-24 冻结）：
    ///   · 只有一方有幸存 → 该方按幸存单位 base_damage 之和扣对方；
    ///   · 双方都有幸存（极端 60 秒）→ 按两边总和**差值**扣少的一方（相等不扣）；
    ///   · 双方都没有 → 0 / 0；
    ///   · 单方单轮封顶 `settle.base_damage_cap`（36 名 3 星 = 108，必须封顶）。
    /// </summary>
    public static class RoundResolver
    {
        public readonly struct AppliedDamage
        {
            public readonly double PlayerApplied;
            public readonly double EnemyApplied;
            public readonly bool TieDiff;

            public AppliedDamage(double player, double enemy, bool tieDiff)
            {
                PlayerApplied = player;
                EnemyApplied = enemy;
                TieDiff = tieDiff;
            }
        }

        /// <summary>
        /// 纯函数结算（唯一口径，检查/推演共用）：
        ///   · 只有一方有幸存 → 该方全额扣对方；
        ///   · 双方都有幸存 → 只扣差值（相等不扣）；
        ///   · 单方封顶 cap（&lt;=0 不封顶）。
        /// </summary>
        public static AppliedDamage Resolve(double playerRaw, double enemyRaw, int cap, bool bothSurvived)
        {
            double p = Math.Max(playerRaw, 0.0);
            double e = Math.Max(enemyRaw, 0.0);
            if (cap > 0)
            {
                if (p > cap) p = cap;
                if (e > cap) e = cap;
            }
            if (bothSurvived && p > 0.0 && e > 0.0)
            {
                double diff = Math.Abs(p - e);
                return p > e
                    ? new AppliedDamage(diff, 0.0, true)
                    : (e > p ? new AppliedDamage(0.0, diff, true) : new AppliedDamage(0.0, 0.0, true));
            }
            return new AppliedDamage(p, e, false);
        }

        public static RoundResult Settle(
            int index,
            string label,
            SquadBattle battle,
            SquadTuning tuning,
            double playerBaseHpBefore,
            double enemyBaseHpBefore,
            bool timeUp)
        {
            var r = new RoundResult
            {
                Index = index,
                Label = label ?? "",
                Seconds = battle != null ? Math.Round(battle.Time * 10.0) / 10.0 : 0.0,
                PlayerBaseHpBefore = playerBaseHpBefore,
                EnemyBaseHpBefore = enemyBaseHpBefore,
                PlayerBaseHpAfter = playerBaseHpBefore,
                EnemyBaseHpAfter = enemyBaseHpBefore,
                Stats = battle != null ? battle.Stats : null,
            };
            if (battle == null) return r;

            int cap = tuning != null ? tuning.BaseDamageCap : 0;
            r.PlayerSurvivors = battle.Survivors(0).Count;
            r.EnemySurvivors = battle.Survivors(1).Count;
            r.PlayerWiped = r.PlayerSurvivors == 0;
            r.EnemyWiped = r.EnemySurvivors == 0;
            r.BerserkTriggered = battle.Berserk;
            r.BerserkSecond = battle.BerserkAt;

            double pRaw = battle.SurvivorBaseDamage(0, cap);
            double eRaw = battle.SurvivorBaseDamage(1, cap);
            r.PlayerBaseDamage = pRaw;
            r.EnemyBaseDamage = eRaw;

            bool bothSurvived = pRaw > 0.0 && eRaw > 0.0;
            var applied = Resolve(pRaw, eRaw, 0, bothSurvived);
            r.PlayerBaseDamageApplied = applied.PlayerApplied;
            r.EnemyBaseDamageApplied = applied.EnemyApplied;
            r.TieDiffUsed = applied.TieDiff;

            if (bothSurvived)
            {
                if (pRaw > eRaw)
                    r.Notes.Add($"60 秒双方均有幸存：{pRaw:0.#} vs {eRaw:0.#}，差值 {applied.PlayerApplied:0.#} 扣敌方基地");
                else if (eRaw > pRaw)
                {
                    r.Notes.Add($"60 秒双方均有幸存：{pRaw:0.#} vs {eRaw:0.#}，差值 {applied.EnemyApplied:0.#} 扣我方基地");
                    CollectEnemyFatalUnits(battle, r);
                }
                else
                {
                    r.Notes.Add($"60 秒双方幸存 base_damage 相等（{pRaw:0.#}），本轮不扣血");
                }
            }
            else if (pRaw > 0.0)
            {
                r.Notes.Add($"敌方全灭：{r.PlayerSurvivors} 名幸存，扣敌方基地 {pRaw:0.#}");
            }
            else if (eRaw > 0.0)
            {
                r.Notes.Add($"我方全灭：{r.EnemySurvivors} 名幸存，扣我方基地 {eRaw:0.#}");
                CollectEnemyFatalUnits(battle, r);
            }
            else
            {
                r.Notes.Add("双方都没有幸存：本轮不扣血");
            }

            r.EnemyBaseHpAfter = Math.Max(enemyBaseHpBefore - r.PlayerBaseDamageApplied, 0.0);
            r.PlayerBaseHpAfter = Math.Max(playerBaseHpBefore - r.EnemyBaseDamageApplied, 0.0);
            if (timeUp && !r.TieDiffUsed) r.Notes.Add("60 秒到点，按幸存者结算");
            return r;
        }

        private static void CollectEnemyFatalUnits(SquadBattle battle, RoundResult r)
        {
            r.EnemyFatalUnits.Clear();
            List<BattleSquad> list = battle.Survivors(1);
            list.Sort((a, b) => b.Def.BaseDamageOf(b.Star).CompareTo(a.Def.BaseDamageOf(a.Star)));
            foreach (BattleSquad s in list)
            {
                double dmg = s.Def.BaseDamageOf(s.Star);
                if (dmg <= 0.0) continue;
                r.EnemyFatalUnits.Add($"{s.Def.DisplayName}★{s.Star}({dmg:0.#})");
                if (r.EnemyFatalUnits.Count >= 6) break;
            }
        }
    }
}
