using System;

namespace WarIsland.Model
{
    /// <summary>伤害类型（6 种，顺序 = 克制表行序，不许重排）。</summary>
    public enum AttackType
    {
        Normal = 0,
        Pierce = 1,
        Magic = 2,
        Siege = 3,
        Chaos = 4,
        Divine = 5,
    }

    /// <summary>护甲类型（6 种，顺序 = 克制表列序，不许重排）。</summary>
    public enum ArmorType
    {
        Unarmored = 0,
        Light = 1,
        Medium = 2,
        Heavy = 3,
        Fortified = 4,
        Holy = 5,
    }

    /// <summary>
    /// 攻/防枚举与中文名的唯一对照。
    /// JSON 里写中文（"穿刺" / "中甲"），Model 里只认 int 下标；
    /// 任何越界都夹到合法范围，但 Validate 会先把非法名字抓出来。
    /// </summary>
    public static class CombatTypes
    {
        public const int AttackCount = 6;
        public const int ArmorCount = 6;

        public static readonly string[] AttackNames = { "普通", "穿刺", "魔法", "攻城", "混乱", "神力" };
        public static readonly string[] ArmorNames = { "无甲", "轻甲", "中甲", "重甲", "坚固甲", "神圣甲" };

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
    }
}
