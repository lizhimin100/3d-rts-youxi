using System;

namespace WarIsland.Model
{
    /// <summary>伤害类型（4 种，顺序 = 克制表行序，不许重排）。</summary>
    public enum AttackType
    {
        Normal = 0,
        Pierce = 1,
        Magic = 2,
        Siege = 3,
    }

    /// <summary>护甲类型（4 种，顺序 = 克制表列序，不许重排）。</summary>
    public enum ArmorType
    {
        Unarmored = 0,
        Light = 1,
        Medium = 2,
        Heavy = 3,
    }

    /// <summary>
    /// 伤害反馈等级（给表现层做全伤害跳字）。
    ///
    /// 口径（2026-11-24 冻结）：
    ///   · <see cref="CritOrCounter"/>：暴击，或克制倍率 &gt; 1（红字）；
    ///   · <see cref="Resisted"/>：克制倍率 &lt; 1（白字）；
    ///   · <see cref="Normal"/>：普通伤害（常规色）；
    ///   · <see cref="Miss"/>：未命中（不跳伤害数字）。
    ///
    /// 反馈只由 <see cref="CombatCalculator"/> 产出，表现层不许自己再算一遍克制表。
    /// </summary>
    public enum DamageFeedback
    {
        Normal = 0,
        CritOrCounter = 1,
        Resisted = 2,
        Miss = 3,
    }

    /// <summary>
    /// 攻/防枚举与中文名的唯一对照。
    /// JSON 里写中文（"穿刺" / "中甲"），Model 里只认 int 下标；
    /// 任何越界都夹到合法范围，但 Validate 会先把非法名字抓出来。
    /// </summary>
    public static class CombatTypes
    {
        public const int AttackCount = 4;
        public const int ArmorCount = 4;

        public static readonly string[] AttackNames = { "普通", "穿刺", "魔法", "攻城" };
        public static readonly string[] ArmorNames = { "无甲", "轻甲", "中甲", "重甲" };

        /// <summary>已废弃的类型名（只用于把旧数据抓红，不许再出现在任何 JSON 里）。</summary>
        public static readonly string[] LegacyAttackNames = { "混乱", "神力" };
        public static readonly string[] LegacyArmorNames = { "坚固甲", "神圣甲" };

        public static bool IsValidAttack(int v) => v >= 0 && v < AttackCount;
        public static bool IsValidArmor(int v) => v >= 0 && v < ArmorCount;

        public static bool TryParseAttack(string name, out int index)
        {
            index = -1;
            if (string.IsNullOrEmpty(name)) return false;
            for (int i = 0; i < AttackNames.Length; i++)
            {
                if (AttackNames[i] == name)
                {
                    index = i;
                    return true;
                }
            }
            return false;
        }

        public static bool TryParseArmor(string name, out int index)
        {
            index = -1;
            if (string.IsNullOrEmpty(name)) return false;
            for (int i = 0; i < ArmorNames.Length; i++)
            {
                if (ArmorNames[i] == name)
                {
                    index = i;
                    return true;
                }
            }
            return false;
        }

        public static string AttackName(int index) =>
            IsValidAttack(index) ? AttackNames[index] : "非法(" + index + ")";

        public static string ArmorName(int index) =>
            IsValidArmor(index) ? ArmorNames[index] : "非法(" + index + ")";

        public static int ClampAttack(int v) => v < 0 ? 0 : (v >= AttackCount ? AttackCount - 1 : v);
        public static int ClampArmor(int v) => v < 0 ? 0 : (v >= ArmorCount ? ArmorCount - 1 : v);

        /// <summary>反馈等级 → 跨语言 key（Screens 只按 key 选颜色，不判中文）。</summary>
        public static string FeedbackKey(DamageFeedback feedback)
        {
            switch (feedback)
            {
                case DamageFeedback.CritOrCounter: return "crit_or_counter";
                case DamageFeedback.Resisted: return "resisted";
                case DamageFeedback.Miss: return "miss";
                default: return "normal";
            }
        }
    }
}
