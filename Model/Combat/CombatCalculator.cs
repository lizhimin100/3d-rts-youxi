using System;

namespace WarIsland.Model
{
    /// <summary>攻方一次出手的输入（纯数据）。</summary>
    public struct CombatAttacker
    {
        /// <summary>单次基础伤害（未乘暴击/护甲/克制）。</summary>
        public double Damage;

        /// <summary>攻击间隔（秒），只给期望 DPS 用。</summary>
        public double Cooldown;

        /// <summary>伤害类型下标（0..5）。</summary>
        public int AttackType;

        /// <summary>命中（百分数，基准 100）。</summary>
        public double Hit;

        /// <summary>暴击率（0..1，不是百分数）。</summary>
        public double CritChance;

        /// <summary>暴击倍率；&lt;=0 时用规则默认（2 倍）。</summary>
        public double CritMultiplier;

        /// <summary>固定护甲穿透（先乘百分比，再减固定值）。</summary>
        public double ArmorPenFlat;

        /// <summary>百分比护甲穿透（0..1）。</summary>
        public double ArmorPenPct;

        /// <summary>攻击倍率（星级/策略）；&lt;=0 视为 1（默认结构体不写也不该变成 0 伤）。</summary>
        public double AttackMult;
    }

    /// <summary>防方一次承伤的输入（纯数据）。</summary>
    public struct CombatDefender
    {
        /// <summary>基础护甲（可以是负数：负甲增伤）。</summary>
        public double Armor;

        /// <summary>护甲类型下标（0..5）。</summary>
        public int ArmorType;

        /// <summary>闪避（百分数，基准 0）。</summary>
        public double Dodge;

        /// <summary>护甲倍率（策略“坚壁”）；&lt;=0 视为 1。</summary>
        public double ArmorMult;

        /// <summary>最终承伤倍率（易伤/减伤）；&lt;=0 视为 1。</summary>
        public double DamageTakenMult;
    }

    /// <summary>一次结算的完整拆解（给 UI / 检查 / 复盘看，不用再反推）。</summary>
    public struct DamageBreakdown
    {
        public bool Hit;
        public double HitChance;
        public bool Crit;
        public double EffectiveArmor;
        public double ArmorTaken;
        public double Counter;
        public double Damage;
    }

    /// <summary>
    /// 6 步伤害结算 —— **全游戏唯一实现**（2026-11-21 规格）。
    ///
    /// 严格按顺序：
    ///   1) 实际命中率 = MAX(攻方命中 - 防方闪避, 0) / 100；
    ///   2) 暴击判定（默认 2 倍）；
    ///   3) 有效护甲 = 基础护甲 × (1 - 百分比穿透) - 固定穿透；
    ///   4) 护甲承伤：有效护甲 >= 0 时 1/(1 + 有效护甲×0.06)；
    ///                 有效护甲 &lt; 0 时 MIN(1 - 有效护甲×0.06, 3)（负甲最多 3 倍）；
    ///   5) 查 6×6 攻击/护甲克制表；
    ///   6) 最终伤害 = 基础 × 暴击 × 承伤 × 克制 × 攻击倍率 × 承伤倍率。
    ///
    /// 纯函数：随机数由调用方传入 [0,1)，同输入必然同输出。
    /// 期望 DPS 走 <see cref="ExpectedDps"/>：**乘实际命中率**，并且复用
    /// <see cref="ArmorDamageTaken"/>，所以负甲 3 倍上限不会在期望公式里丢掉。
    /// </summary>
    public static class CombatCalculator
    {
        /// <summary>命中率：MAX(命中 - 闪避, 0) / 100，夹到 [0,1]。</summary>
        public static double HitChance(double hit, double dodge)
        {
            double raw = (hit - dodge) / 100.0;
            if (double.IsNaN(raw) || raw <= 0.0) return 0.0;
            return raw >= 1.0 ? 1.0 : raw;
        }

        /// <summary>有效护甲 = 基础护甲 × (1 - 百分比穿透) - 固定穿透。</summary>
        public static double EffectiveArmor(double baseArmor, double penPct, double penFlat)
        {
            double pct = Clamp01(penPct);
            double flat = penFlat > 0.0 ? penFlat : 0.0;
            return baseArmor * (1.0 - pct) - flat;
        }

        /// <summary>
        /// 护甲承伤比例：
        ///   &gt;=0：1/(1 + 有效护甲×0.06)（永远小于等于 1，不会变成 0）；
        ///   &lt;0 ：MIN(1 - 有效护甲×0.06, 3)（负甲最多 3 倍）。
        /// </summary>
        public static double ArmorDamageTaken(double effectiveArmor, CombatRules rules)
        {
            double scale = rules != null && rules.ArmorScale > 0.0 ? rules.ArmorScale : CombatRules.SpecArmorScale;
            if (effectiveArmor >= 0.0)
                return 1.0 / (1.0 + effectiveArmor * scale);

            double cap = rules != null && rules.NegativeArmorCap > 0.0
                ? rules.NegativeArmorCap
                : CombatRules.SpecNegativeArmorCap;
            double taken = 1.0 - effectiveArmor * scale;
            return taken < cap ? taken : cap;
        }

        /// <summary>克制倍率（表无效时返回 1.0，不把坏数据变成 0 伤）。</summary>
        public static double CounterMultiplier(CombatRules rules, int attackType, int armorType)
        {
            return rules != null ? rules.Counter(attackType, armorType) : 1.0;
        }

        /// <summary>暴击倍率：攻方没写就用规则默认（2 倍）。</summary>
        public static double CritMultiplierOf(in CombatAttacker attacker, CombatRules rules)
        {
            if (attacker.CritMultiplier > 0.0) return attacker.CritMultiplier;
            return rules != null && rules.CritMultiplier > 0.0
                ? rules.CritMultiplier
                : CombatRules.SpecCritMultiplier;
        }

        /// <summary>一次结算（按 6 步顺序）。rollHit / rollCrit ∈ [0,1)。</summary>
        public static DamageBreakdown Compute(
            in CombatAttacker attacker,
            in CombatDefender defender,
            CombatRules rules,
            double rollHit,
            double rollCrit)
        {
            var br = new DamageBreakdown();

            // 1) 命中
            br.HitChance = HitChance(attacker.Hit, defender.Dodge);
            double rHit = ClampRoll(rollHit);
            br.Hit = br.HitChance >= 1.0 || rHit < br.HitChance;

            // 2) 暴击（没命中就不判暴击）
            double critChance = Clamp01(attacker.CritChance);
            double rCrit = ClampRoll(rollCrit);
            br.Crit = br.Hit && rCrit < critChance;
            double critMult = br.Crit ? CritMultiplierOf(attacker, rules) : 1.0;

            // 3) 有效护甲
            double armorMult = defender.ArmorMult > 0.0 ? defender.ArmorMult : 1.0;
            br.EffectiveArmor = EffectiveArmor(defender.Armor * armorMult, attacker.ArmorPenPct, attacker.ArmorPenFlat);

            // 4) 护甲承伤
            br.ArmorTaken = ArmorDamageTaken(br.EffectiveArmor, rules);

            // 5) 克制
            br.Counter = CounterMultiplier(rules, attacker.AttackType, defender.ArmorType);

            // 6) 最终伤害
            if (!br.Hit)
            {
                br.Damage = 0.0;
                return br;
            }
            double attackMult = attacker.AttackMult > 0.0 ? attacker.AttackMult : 1.0;
            double takenMult = defender.DamageTakenMult > 0.0 ? defender.DamageTakenMult : 1.0;
            double baseDamage = attacker.Damage > 0.0 ? attacker.Damage : 0.0;
            double dmg = baseDamage * critMult * br.ArmorTaken * br.Counter * attackMult * takenMult;
            if (double.IsNaN(dmg) || dmg < 0.0) dmg = 0.0;
            br.Damage = dmg;
            return br;
        }

        /// <summary>期望单次伤害（纯数学）：基础 × 命中率 × 暴击期望 × 承伤 × 克制 × 攻击倍率。</summary>
        public static double ExpectedDamage(
            in CombatAttacker attacker,
            in CombatDefender defender,
            CombatRules rules)
        {
            double hitChance = HitChance(attacker.Hit, defender.Dodge);
            if (hitChance <= 0.0) return 0.0;

            double critChance = Clamp01(attacker.CritChance);
            double critMult = CritMultiplierOf(attacker, rules);
            double critFactor = 1.0 + critChance * (critMult - 1.0);

            double armorMult = defender.ArmorMult > 0.0 ? defender.ArmorMult : 1.0;
            double effectiveArmor = EffectiveArmor(defender.Armor * armorMult, attacker.ArmorPenPct, attacker.ArmorPenFlat);
            double armorTaken = ArmorDamageTaken(effectiveArmor, rules);
            double counter = CounterMultiplier(rules, attacker.AttackType, defender.ArmorType);
            double attackMult = attacker.AttackMult > 0.0 ? attacker.AttackMult : 1.0;
            double takenMult = defender.DamageTakenMult > 0.0 ? defender.DamageTakenMult : 1.0;
            double baseDamage = attacker.Damage > 0.0 ? attacker.Damage : 0.0;

            double dmg = baseDamage * hitChance * critFactor * armorTaken * counter * attackMult * takenMult;
            if (double.IsNaN(dmg) || dmg < 0.0) return 0.0;
            return dmg;
        }

        /// <summary>期望 DPS = 期望单次伤害 / 攻击间隔（间隔下限 0.05 秒）。</summary>
        public static double ExpectedDps(
            in CombatAttacker attacker,
            in CombatDefender defender,
            CombatRules rules)
        {
            double cd = attacker.Cooldown > 0.05 ? attacker.Cooldown : 0.05;
            return ExpectedDamage(attacker, defender, rules) / cd;
        }

        /// <summary>一次结算里“护甲实际减伤百分比”（负数 = 增伤），给 UI 显示用。</summary>
        public static double MitigationPercent(double effectiveArmor, CombatRules rules)
        {
            return (1.0 - ArmorDamageTaken(effectiveArmor, rules)) * 100.0;
        }

        private static double Clamp01(double v)
        {
            if (double.IsNaN(v) || v <= 0.0) return 0.0;
            return v >= 1.0 ? 1.0 : v;
        }

        private static double ClampRoll(double v)
        {
            if (double.IsNaN(v) || v <= 0.0) return 0.0;
            return v >= 0.999999999 ? 0.999999999 : v;
        }
    }
}
