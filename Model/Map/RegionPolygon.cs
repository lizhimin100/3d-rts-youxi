using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>势力区域类型。</summary>
    public enum RegionKind
    {
        Player = 0,
        Neutral = 1,
        Enemy = 2,
    }

    /// <summary>区域类型的字符串契约（JSON / 编辑器共用，禁止各处再写一份）。</summary>
    public static class RegionKinds
    {
        public const string Player = "player";
        public const string Neutral = "neutral";
        public const string Enemy = "enemy";

        public static string Name(RegionKind kind) => kind switch
        {
            RegionKind.Player => Player,
            RegionKind.Neutral => Neutral,
            _ => Enemy,
        };

        public static bool TryParse(string text, out RegionKind kind)
        {
            switch ((text ?? string.Empty).Trim().ToLowerInvariant())
            {
                case Player: kind = RegionKind.Player; return true;
                case Neutral: kind = RegionKind.Neutral; return true;
                case Enemy: kind = RegionKind.Enemy; return true;
                default: kind = RegionKind.Neutral; return false;
            }
        }

        public static RegionKind Parse(string text)
        {
            return TryParse(text, out RegionKind k) ? k : RegionKind.Neutral;
        }
    }

    /// <summary>
    /// 多边形势力区域（XZ 平面）。**点是否在多边形内**的唯一实现。
    ///
    /// 坐标口径：
    ///   · 只存 XZ 两个分量（Vec2.X = 世界 x，Vec2.Y = 世界 z），高度不参与判定；
    ///   · 顶点点序任意（顺/逆时针都行），面积取绝对值；
    ///   · 边界上的点算**在内**（编辑器点顶点时不会"点在自己边上却判外"）。
    ///
    /// 规矩：地图底壳编辑器、关卡装配、检查脚本都调这里，不许在 GDScript 里再写一份
    /// Point-in-Polygon（AGENTS 第 2 条：规则只写一份，写在 Model/）。
    /// </summary>
    public sealed class RegionPolygon
    {
        /// <summary>顶点少于 3 个时的固定错误码（反向验错用例认这一条）。</summary>
        public const string ErrorTooFewPoints = "region needs at least 3 vertices";

        /// <summary>面积小于这个值（平方米）视为退化多边形。</summary>
        public const double MinArea = 0.25;

        public RegionKind Kind { get; set; } = RegionKind.Neutral;

        /// <summary>XZ 顶点（Vec2.X = 世界 x；Vec2.Y = 世界 z）。</summary>
        public List<Vec2> Points { get; } = new List<Vec2>();

        public RegionPolygon() { }

        public RegionPolygon(RegionKind kind, IEnumerable<Vec2> points)
        {
            Kind = kind;
            if (points != null) Points.AddRange(points);
        }

        public int Count => Points.Count;

        /// <summary>鞋带公式的有符号面积（逆时针为正）。</summary>
        public double SignedArea
        {
            get
            {
                int n = Points.Count;
                if (n < 3) return 0.0;
                double sum = 0.0;
                for (int i = 0; i < n; i++)
                {
                    Vec2 a = Points[i];
                    Vec2 b = Points[(i + 1) % n];
                    sum += a.X * b.Y - b.X * a.Y;
                }
                return sum * 0.5;
            }
        }

        public double Area => Math.Abs(SignedArea);

        /// <summary>边界上的点也算在内。</summary>
        public bool Contains(double x, double z)
        {
            int n = Points.Count;
            if (n < 3) return false;
            bool inside = false;
            for (int i = 0, j = n - 1; i < n; j = i++)
            {
                Vec2 a = Points[j];
                Vec2 b = Points[i];
                if (OnSegment(a, b, x, z)) return true;
                bool crosses = (b.Y > z) != (a.Y > z);
                if (!crosses) continue;
                double t = (z - b.Y) / (a.Y - b.Y);
                double crossX = b.X + (a.X - b.X) * t;
                if (x < crossX) inside = !inside;
            }
            return inside;
        }

        public bool Contains(Vec2 p) => Contains(p.X, p.Y);

        /// <summary>点是否落在线段 ab 上（含端点，容差 1e-9）。</summary>
        private static bool OnSegment(Vec2 a, Vec2 b, double x, double z)
        {
            double cross = (b.X - a.X) * (z - a.Y) - (b.Y - a.Y) * (x - a.X);
            if (Math.Abs(cross) > 1e-9) return false;
            double dot = (x - a.X) * (b.X - a.X) + (z - a.Y) * (b.Y - a.Y);
            if (dot < -1e-9) return false;
            double len2 = (b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y);
            return dot <= len2 + 1e-9;
        }

        /// <summary>
        /// 校验。返回的错误是**给人看的英文短语**（界面自己翻译），
        /// 空数组 = 合法。顶点不足 3 个是必须覆盖的反向验错分支。
        /// </summary>
        public List<string> Validate()
        {
            var errors = new List<string>();
            if (Points.Count < 3)
            {
                errors.Add($"{ErrorTooFewPoints} (got {Points.Count})");
                return errors;
            }
            for (int i = 0; i < Points.Count; i++)
            {
                Vec2 p = Points[i];
                if (!IsFinite(p.X) || !IsFinite(p.Y))
                {
                    errors.Add($"vertex {i} is not finite");
                    return errors;
                }
                Vec2 next = Points[(i + 1) % Points.Count];
                if (Math.Abs(p.X - next.X) < 1e-6 && Math.Abs(p.Y - next.Y) < 1e-6)
                {
                    errors.Add($"vertex {i} duplicates the next vertex");
                    return errors;
                }
            }
            if (Area < MinArea)
            {
                errors.Add($"polygon is degenerate (area {Area:0.###} < {MinArea})");
                return errors;
            }
            if (SelfIntersects())
                errors.Add("polygon is self-intersecting");
            return errors;
        }

        /// <summary>非相邻边两两求交（O(n²)，区域顶点通常 &lt; 32，够用）。</summary>
        public bool SelfIntersects()
        {
            int n = Points.Count;
            if (n < 4) return false;
            for (int i = 0; i < n; i++)
            {
                Vec2 a1 = Points[i];
                Vec2 a2 = Points[(i + 1) % n];
                for (int j = i + 1; j < n; j++)
                {
                    if (j == i || (j + 1) % n == i) continue;
                    if (i == (j + 1) % n) continue;
                    Vec2 b1 = Points[j];
                    Vec2 b2 = Points[(j + 1) % n];
                    if (SegmentsCross(a1, a2, b1, b2)) return true;
                }
            }
            return false;
        }

        private static bool SegmentsCross(Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2)
        {
            double d1 = Cross(b1, b2, a1);
            double d2 = Cross(b1, b2, a2);
            double d3 = Cross(a1, a2, b1);
            double d4 = Cross(a1, a2, b2);
            if (((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) &&
                ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9)))
                return true;
            return false;
        }

        private static double Cross(Vec2 a, Vec2 b, Vec2 p) =>
            (b.X - a.X) * (p.Y - a.Y) - (b.Y - a.Y) * (p.X - a.X);

        private static bool IsFinite(double v) => !double.IsNaN(v) && !double.IsInfinity(v);

        /// <summary>矩形区域（默认三块用；左下 + 右上两个角点）。</summary>
        public static RegionPolygon Rect(RegionKind kind, double minX, double minZ, double maxX, double maxZ)
        {
            var p = new RegionPolygon { Kind = kind };
            p.Points.Add(new Vec2((float)minX, (float)minZ));
            p.Points.Add(new Vec2((float)maxX, (float)minZ));
            p.Points.Add(new Vec2((float)maxX, (float)maxZ));
            p.Points.Add(new Vec2((float)minX, (float)maxZ));
            return p;
        }

        /// <summary>
        /// 新建底壳的默认区域：沿长轴切成三条（玩家 / 中立 / 敌方）。
        /// 玩家在左（x &lt; 0）、敌方在右；中立带占中间 34%，留出两军推进的缓冲。
        /// </summary>
        public static RegionPolygon DefaultFor(RegionKind kind, double sizeX, double sizeZ)
        {
            double hx = Math.Max(sizeX, 4.0) * 0.5;
            double hz = Math.Max(sizeZ, 4.0) * 0.5;
            double edge = hx * 0.9;
            double mid = hx * 0.33;
            return kind switch
            {
                RegionKind.Player => Rect(kind, -edge, -hz * 0.92, -mid, hz * 0.92),
                RegionKind.Enemy => Rect(kind, mid, -hz * 0.92, edge, hz * 0.92),
                _ => Rect(kind, -mid, -hz * 0.92, mid, hz * 0.92),
            };
        }
    }

    /// <summary>三个势力区域的集合（玩家 / 中立 / 敌方）。</summary>
    public sealed class RegionSet
    {
        public RegionPolygon Player { get; set; }
        public RegionPolygon Neutral { get; set; }
        public RegionPolygon Enemy { get; set; }

        public RegionPolygon Of(RegionKind kind) => kind switch
        {
            RegionKind.Player => Player,
            RegionKind.Enemy => Enemy,
            _ => Neutral,
        };

        public static RegionSet Defaults(double sizeX, double sizeZ)
        {
            return new RegionSet
            {
                Player = RegionPolygon.DefaultFor(RegionKind.Player, sizeX, sizeZ),
                Neutral = RegionPolygon.DefaultFor(RegionKind.Neutral, sizeX, sizeZ),
                Enemy = RegionPolygon.DefaultFor(RegionKind.Enemy, sizeX, sizeZ),
            };
        }

        /// <summary>点落在哪个区域。优先级：玩家区 &gt; 敌方区 &gt; 中立区；都不在返回 null。</summary>
        public RegionKind? KindAt(double x, double z)
        {
            if (Player != null && Player.Contains(x, z)) return RegionKind.Player;
            if (Enemy != null && Enemy.Contains(x, z)) return RegionKind.Enemy;
            if (Neutral != null && Neutral.Contains(x, z)) return RegionKind.Neutral;
            return null;
        }

        public List<string> Validate()
        {
            var errors = new List<string>();
            foreach (RegionKind kind in new[] { RegionKind.Player, RegionKind.Neutral, RegionKind.Enemy })
            {
                RegionPolygon poly = Of(kind);
                string tag = RegionKinds.Name(kind);
                if (poly == null)
                {
                    errors.Add(tag + " region missing");
                    continue;
                }
                if (poly.Kind != kind)
                    errors.Add($"{tag} region kind mismatch ({RegionKinds.Name(poly.Kind)})");
                foreach (string e in poly.Validate())
                    errors.Add(tag + " region: " + e);
            }
            return errors;
        }
    }
}
