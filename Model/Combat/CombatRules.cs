using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 战斗规则（从 Content/data/combat.json 装入）。
    ///
    /// 公式常数是**规格**，写在这里并由 --check 钉死：
    ///   · R1 = 0.015 米 / 游戏数值；
    ///   · 护甲系数 0.06；
    ///   · 负甲承伤上限 3 倍；
    ///   · 暴击默认 2 倍；
    ///   · 命中基准 100。
    /// 6×6 克制表是**内容**，只有 JSON 一份；C# 不写第二份表。
    /// </summary>
    public sealed class CombatRules
    {
        public const int Stride = 6;
        public const double SpecR1 = 0.015;
        public const double SpecArmorScale = 0.06;
        public const double SpecNegativeArmorCap = 3.0;
        public const double SpecCritMultiplier = 2.0;
        public const double SpecHitBase = 100.0;

        public double R1 = SpecR1;
        public double HitBase = SpecHitBase;
        public double ArmorScale = SpecArmorScale;
        public double NegativeArmorCap = SpecNegativeArmorCap;
        public double CritMultiplier = SpecCritMultiplier;

        /// <summary>6 个伤害类型名（顺序即行序）。</summary>
        public string[] AttackNames = (string[])CombatTypes.AttackNames.Clone();

        /// <summary>6 个护甲类型名（顺序即列序）。</summary>
        public string[] ArmorNames = (string[])CombatTypes.ArmorNames.Clone();

        /// <summary>扁平 6×6 表：row = 伤害类型，col = 护甲类型。</summary>
        public double[] CounterTable;

        private readonly List<string> _parseNotes = new List<string>();

        public bool HasTable => CounterTable != null && CounterTable.Length == Stride * Stride;

        public static CombatRules FromDict(IDictionary<string, object> d)
        {
            var r = new CombatRules();
            if (d == null)
            {
                r._parseNotes.Add("combat 配置为空");
                return r;
            }

            r.R1 = JVal.Double(d, "r1", SpecR1);
            r.HitBase = JVal.Double(d, "hit_base", SpecHitBase);
            r.ArmorScale = JVal.Double(d, "armor_scale", SpecArmorScale);
            r.NegativeArmorCap = JVal.Double(d, "negative_armor_cap", SpecNegativeArmorCap);
            r.CritMultiplier = JVal.Double(d, "crit_multiplier", SpecCritMultiplier);

            var at = JVal.StringArray(d, "attack_types");
            if (at != null) r.AttackNames = at;
            else r._parseNotes.Add("缺少 attack_types（6 个伤害类型名）");

            var ar = JVal.StringArray(d, "armor_types");
            if (ar != null) r.ArmorNames = ar;
            else r._parseNotes.Add("缺少 armor_types（6 个护甲类型名）");

            var rows = JVal.List(d, "counter_table");
            if (rows == null)
            {
                r._parseNotes.Add("缺少 counter_table");
            }
            else if (rows.Count != Stride)
            {
                r._parseNotes.Add($"counter_table 行数 {rows.Count} != {Stride}");
            }
            else
            {
                var table = new double[Stride * Stride];
                bool ok = true;
                for (int i = 0; i < Stride && ok; i++)
                {
                    var cols = JVal.AsList(rows[i]);
                    if (cols == null || cols.Count != Stride)
                    {
                        r._parseNotes.Add($"counter_table 第 {i} 行不是 {Stride} 列");
                        ok = false;
                        break;
                    }
                    for (int j = 0; j < Stride; j++)
                    {
                        double v = JVal.ToDouble(cols[j], double.NaN);
                        if (double.IsNaN(v))
                        {
                            r._parseNotes.Add($"counter_table[{i}][{j}] 不是数字");
                            ok = false;
                            break;
                        }
                        table[i * Stride + j] = v;
                    }
                }
                if (ok) r.CounterTable = table;
            }
            return r;
        }

        /// <summary>结构性校验 + 规格常数校验。返回空数组 = 合法。</summary>
        public List<string> Validate()
        {
            var errors = new List<string>(_parseNotes);

            if (Math.Abs(R1 - SpecR1) > 1e-12)
                errors.Add($"r1={R1}，规格要求 {SpecR1}（距离铁律不许改）");
            if (Math.Abs(HitBase - SpecHitBase) > 1e-9)
                errors.Add($"hit_base={HitBase}，规格要求 {SpecHitBase}");
            if (Math.Abs(ArmorScale - SpecArmorScale) > 1e-12)
                errors.Add($"armor_scale={ArmorScale}，规格要求 {SpecArmorScale}");
            if (Math.Abs(NegativeArmorCap - SpecNegativeArmorCap) > 1e-12)
                errors.Add($"negative_armor_cap={NegativeArmorCap}，规格要求 {SpecNegativeArmorCap}");
            if (Math.Abs(CritMultiplier - SpecCritMultiplier) > 1e-9)
                errors.Add($"crit_multiplier={CritMultiplier}，规格默认 {SpecCritMultiplier}");

            if (AttackNames == null || AttackNames.Length != CombatTypes.AttackCount)
            {
                errors.Add($"attack_types 必须是 {CombatTypes.AttackCount} 个");
            }
            else
            {
                for (int i = 0; i < AttackNames.Length; i++)
                {
                    if (AttackNames[i] != CombatTypes.AttackNames[i])
                        errors.Add($"attack_types[{i}]={AttackNames[i]}，规定顺序是 {CombatTypes.AttackNames[i]}（表行序不许重排）");
                }
            }

            if (ArmorNames == null || ArmorNames.Length != CombatTypes.ArmorCount)
            {
                errors.Add($"armor_types 必须是 {CombatTypes.ArmorCount} 个");
            }
            else
            {
                for (int i = 0; i < ArmorNames.Length; i++)
                {
                    if (ArmorNames[i] != CombatTypes.ArmorNames[i])
                        errors.Add($"armor_types[{i}]={ArmorNames[i]}，规定顺序是 {CombatTypes.ArmorNames[i]}（表列序不许重排）");
                }
            }

            if (!HasTable)
            {
                if (CounterTable != null && CounterTable.Length != Stride * Stride)
                    errors.Add($"counter_table 长度 {CounterTable.Length} != {Stride * Stride}");
            }
            else
            {
                for (int i = 0; i < CounterTable.Length; i++)
                {
                    double v = CounterTable[i];
                    if (double.IsNaN(v) || double.IsInfinity(v) || v <= 0.0 || v > 5.0)
                    {
                        errors.Add($"counter_table[{i / Stride}][{i % Stride}]={v} 越界（应在 0~5）");
                        break;
                    }
                }
            }
            return errors;
        }

        /// <summary>克制倍率：越界夹紧；表无效时返回 1.0（不让错误数据把伤害变成 0）。</summary>
        public double Counter(int attackType, int armorType)
        {
            if (!HasTable) return 1.0;
            int row = CombatTypes.ClampAttack(attackType);
            int col = CombatTypes.ClampArmor(armorType);
            return CounterTable[row * Stride + col];
        }

        public string AttackName(int index) =>
            AttackNames != null && index >= 0 && index < AttackNames.Length ? AttackNames[index] : CombatTypes.AttackName(index);

        public string ArmorName(int index) =>
            ArmorNames != null && index >= 0 && index < ArmorNames.Length ? ArmorNames[index] : CombatTypes.ArmorName(index);
    }
}
