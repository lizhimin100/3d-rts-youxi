using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>阵型模板（units.json 的 formation 字段）。</summary>
    public enum SquadFormationKind
    {
        Square = 0,
        Scatter = 1,
        Wedge = 2,
    }

    /// <summary>
    /// 小队阵型槽位 —— **全项目唯一实现**。
    ///
    /// 口径：
    ///   · 槽位是**小队本地坐标**（+X 朝前、+Z 朝右），单位是游戏数值（×R1 = 米）；
    ///   · 槽位由兵种卡面决定：formation（方阵/散阵/楔形）+ body_radius（身位）+ squad_radius（小队半径）；
    ///   · `squad_radius` 是硬预算：任何模板生成的槽位都会被等比缩放到半径的 92% 以内，
    ///     所以"队列铺得比小队还大"这种事在数据层就不可能发生；
    ///   · 成员永远只是**跟槽位**，不各自寻路 —— 这是"小队原子性"的几何基础。
    ///
    /// 槽位数 = `units.json` 的 squad_size，一个不多一个不少（--check 会逐兵种断言）。
    /// </summary>
    public static class SquadFormations
    {
        public const string Square = "square";
        public const string Scatter = "scatter";
        public const string Wedge = "wedge";

        /// <summary>三位数标准值：100..400 游戏数值 = 1.5..6.0 米。</summary>
        public const double MinRadius = 100.0;
        public const double MaxRadius = 400.0;

        /// <summary>槽位最多铺到小队半径的这个比例（留出转向余量）。</summary>
        public const double FitRatio = 0.92;

        public static bool TryParse(string name, out SquadFormationKind kind)
        {
            switch ((name ?? "").Trim().ToLowerInvariant())
            {
                case Square:
                    kind = SquadFormationKind.Square;
                    return true;
                case Scatter:
                    kind = SquadFormationKind.Scatter;
                    return true;
                case Wedge:
                    kind = SquadFormationKind.Wedge;
                    return true;
                default:
                    kind = SquadFormationKind.Square;
                    return false;
            }
        }

        public static string Name(SquadFormationKind kind)
        {
            switch (kind)
            {
                case SquadFormationKind.Scatter: return Scatter;
                case SquadFormationKind.Wedge: return Wedge;
                default: return Square;
            }
        }

        /// <summary>本地槽位（游戏数值）。顺序稳定：0 号永远在最前排中间。</summary>
        public static List<Vec2> Slots(UnitDef def)
        {
            var raw = RawSlots(def);
            if (raw.Count == 0) return raw;

            double radius = def != null && def.SquadRadius > 0.0 ? def.SquadRadius : MaxRadius;
            double limit = radius * FitRatio;
            double maxR = 0.0;
            for (int i = 0; i < raw.Count; i++)
            {
                double d = Math.Sqrt(raw[i].X * raw[i].X + raw[i].Y * raw[i].Y);
                if (d > maxR) maxR = d;
            }
            if (maxR <= limit || maxR <= 1e-9) return raw;

            double k = limit / maxR;
            var scaled = new List<Vec2>(raw.Count);
            for (int i = 0; i < raw.Count; i++)
                scaled.Add(new Vec2((float)(raw[i].X * k), (float)(raw[i].Y * k)));
            return scaled;
        }

        /// <summary>槽位到小队中心的最大距离（游戏数值）。</summary>
        public static double MaxSlotRadius(UnitDef def)
        {
            var slots = Slots(def);
            double maxR = 0.0;
            for (int i = 0; i < slots.Count; i++)
            {
                double d = Math.Sqrt(slots[i].X * slots[i].X + slots[i].Y * slots[i].Y);
                if (d > maxR) maxR = d;
            }
            return maxR;
        }

        /// <summary>单模型身位（游戏数值）。</summary>
        public static double BodyUnits(UnitDef def)
        {
            double meters = def != null && def.BodyRadius > 0.0 ? def.BodyRadius : 0.45;
            return RtsUnits.ToUnits(meters);
        }

        private static List<Vec2> RawSlots(UnitDef def)
        {
            var list = new List<Vec2>();
            if (def == null) return list;
            int n = def.SquadSize > 0 ? def.SquadSize : 1;
            double spacing = Math.Max(BodyUnits(def) * 2.05, 30.0);

            SquadFormationKind kind;
            if (!TryParse(def.Formation, out kind)) kind = SquadFormationKind.Square;

            switch (kind)
            {
                case SquadFormationKind.Scatter:
                {
                    double radius = (def.SquadRadius > 0.0 ? def.SquadRadius : MaxRadius) * 0.74;
                    for (int i = 0; i < n; i++)
                    {
                        double r = radius * Math.Sqrt((i + 0.55) / n);
                        double ang = i * 2.399963229728653 + 0.7;
                        double x = Math.Cos(ang) * r + radius * 0.10;
                        double z = Math.Sin(ang) * r;
                        list.Add(new Vec2((float)x, (float)z));
                    }
                    break;
                }

                case SquadFormationKind.Wedge:
                {
                    double front = spacing * 0.35;
                    for (int i = 0; i < n; i++)
                    {
                        if (i == 0)
                        {
                            list.Add(new Vec2((float)front, 0f));
                            continue;
                        }
                        int rank = (i + 1) / 2;
                        int side = (i % 2 == 1) ? -1 : 1;
                        double x = front - rank * spacing * 0.82;
                        double z = side * rank * spacing * 0.74;
                        list.Add(new Vec2((float)x, (float)z));
                    }
                    break;
                }

                default:
                {
                    int cols = (int)Math.Ceiling(Math.Sqrt(n));
                    if (cols < 1) cols = 1;
                    int rows = (int)Math.Ceiling(n / (double)cols);
                    for (int i = 0; i < n; i++)
                    {
                        int row = i / cols;
                        int col = i % cols;
                        int inRow = Math.Min(cols, n - row * cols);
                        double x = ((rows - 1) * 0.5 - row) * spacing;
                        double z = (col - (inRow - 1) * 0.5) * spacing;
                        list.Add(new Vec2((float)x, (float)z));
                    }
                    break;
                }
            }
            return list;
        }

        /// <summary>校验一个兵种的编制字段（给 UnitCatalog.Validate 用）。</summary>
        public static List<string> Validate(UnitDef def)
        {
            var errors = new List<string>();
            string tag = def == null || string.IsNullOrEmpty(def.Id) ? "(空 id)" : def.Id;
            if (def == null) return errors;

            SquadFormationKind kind;
            if (string.IsNullOrWhiteSpace(def.Formation))
            {
                errors.Add($"{tag}：缺 formation（square/scatter/wedge）");
            }
            else if (!TryParse(def.Formation, out kind))
            {
                errors.Add($"{tag}：formation={def.Formation} 非法（只允许 square/scatter/wedge）");
            }

            if (def.SquadRadius < MinRadius || def.SquadRadius > MaxRadius)
                errors.Add($"{tag}：squad_radius={def.SquadRadius} 越界（三位数 {MinRadius}..{MaxRadius} 游戏数值）");

            double body = BodyUnits(def) * 2.0;
            if (def.SquadRadius > 0.0 && def.SquadRadius < body - 1e-6)
                errors.Add($"{tag}：squad_radius={def.SquadRadius} 比两个身位还小（至少 {body:0}）");

            var slots = Slots(def);
            if (slots.Count != Math.Max(def.SquadSize, 1))
                errors.Add($"{tag}：阵型槽位 {slots.Count} 个，和 squad_size={def.SquadSize} 不一致");

            var seen = new HashSet<long>();
            for (int i = 0; i < slots.Count; i++)
            {
                long key = ((long)Math.Round(slots[i].X * 10.0) << 32) ^ (long)Math.Round(slots[i].Y * 10.0);
                if (!seen.Add(key))
                    errors.Add($"{tag}：阵型槽位 {i} 与前面的槽位重合");
            }

            double maxSlot = MaxSlotRadius(def);
            if (def.SquadRadius > 0.0 && maxSlot > def.SquadRadius * FitRatio + 1e-6)
                errors.Add($"{tag}：槽位最远 {maxSlot:0.#} 超出小队半径 {def.SquadRadius:0} 的 {FitRatio:P0}");

            return errors;
        }
    }
}
