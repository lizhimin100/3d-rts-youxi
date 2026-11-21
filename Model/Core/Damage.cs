using System;

namespace WarIsland.Model
{
    /// <summary>一次伤害结算的结果（纯数据，不含引擎对象）。</summary>
    public readonly struct DamageResult
    {
        public readonly bool Ok;
        public readonly double Damage;
        public readonly double Mitigation;
        public readonly double Multiplier;
        public readonly bool IsCrit;

        public DamageResult(bool ok, double damage, double mitigation, double multiplier, bool isCrit)
        {
            Ok = ok;
            Damage = damage;
            Mitigation = mitigation;
            Multiplier = multiplier;
            IsCrit = isCrit;
        }

        public static DamageResult Fail => new DamageResult(false, 0.0, 0.0, 1.0, false);
    }

    /// <summary>伤害规则（从 Content/data/game.json 读出来后由宿主喂进来）。</summary>
    public sealed class DamageRules
    {
        public double[] DamageTable = Array.Empty<double>();
        public int Stride = 5;
        public double ArmorReduction;
        public double ArmorReductionCap;
        public double CritChance;
        public double CritMultiplier = 1.0;
    }

    /// <summary>
    /// 伤害公式 —— **全游戏唯一实现**。
    ///
    ///   伤害 = (基础 ± spread 随机) × 克制 × (1 - 护甲减免) × 暴击 × 攻击倍率
    ///   护甲减免 = min(max(护甲,0) × 每点系数, 上限)
    ///
    /// 纯函数：随机数由调用方传入 [0,1)，这里不取随机 —— 同输入必然同输出。
    /// </summary>
    public static class Damage
    {
        public static double ArmorMitigation(double armor, double reduction, double cap)
        {
            double a = armor > 0.0 ? armor : 0.0;
            double r = reduction > 0.0 ? reduction : 0.0;
            double c = cap > 0.0 ? cap : 0.0;
            double v = a * r;
            return v < c ? v : c;
        }

        /// <summary>克制表：行 = 伤害类型，列 = 护甲类型，扁平存储。</summary>
        public static double CounterMultiplier(double[] table, int attackType, int armorType, int stride = 5)
        {
            if (table == null || table.Length == 0 || stride <= 0) return 1.0;
            int rows = table.Length / stride;
            int row = Clamp(attackType, 0, rows > 0 ? rows - 1 : 0);
            int col = Clamp(armorType, 0, stride - 1);
            int idx = row * stride + col;
            if (idx < 0 || idx >= table.Length) return 1.0;
            return table[idx];
        }

        public static DamageResult Compute(
            double baseDamage, double spread, int attackType,
            double targetArmor, int targetArmorType, DamageRules rules,
            double rollSpread, double rollCrit, double attackMult = 1.0)
        {
            if (rules == null || rules.DamageTable == null || rules.DamageTable.Length == 0)
                return DamageResult.Fail;

            double rSpread = Clamp(rollSpread, 0.0, 0.999999);
            double rCrit = Clamp(rollCrit, 0.0, 0.999999);
            double baseDmg = baseDamage + spread * (rSpread * 2.0 - 1.0);
            double mult = CounterMultiplier(rules.DamageTable, attackType, targetArmorType, rules.Stride);
            double mit = ArmorMitigation(targetArmor, rules.ArmorReduction, rules.ArmorReductionCap);
            bool isCrit = rCrit < rules.CritChance;
            double crit = isCrit ? rules.CritMultiplier : 1.0;
            double dmg = baseDmg * mult * (1.0 - mit) * crit * Math.Max(attackMult, 0.0);
            if (dmg < 0.0) dmg = 0.0;
            return new DamageResult(true, dmg, mit, mult, isCrit);
        }

        private static int Clamp(int v, int lo, int hi)
        {
            if (v < lo) return lo;
            if (v > hi) return hi;
            return v;
        }

        private static double Clamp(double v, double lo, double hi)
        {
            if (v < lo) return lo;
            if (v > hi) return hi;
            return v;
        }
    }
}
