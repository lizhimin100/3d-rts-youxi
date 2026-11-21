using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>
    /// 战术格子（TacticalTile）—— 自走棋式的「地形格子」，取代旧版候选独立石台。
    ///
    /// 数据口径：
    ///   · 格子是 XZ 平面上的一个矩形（宽 Width、深 Depth、朝向 YawDeg）＋ 贴地高度 TerrainY；
    ///   · **两个标准本地锚点**（全项目唯一实现，编辑器与局内都从这里取）：
    ///       - <see cref="BuildingAnchorLocal"/> = 左上角（本地 -X / -Z 角）→ 建筑位；
    ///       - <see cref="SquadSpawnAnchorLocal"/> = 正中心 → 出兵位；
    ///   · 本地坐标：+X 向右、+Z 向后（屏幕上方 = -Z），与 Godot 的 Y 轴旋转一致。
    ///
    /// 为什么锚点写在 Model：编辑器要把标记画在世界里，局内要把建筑/小队放到同一处；
    /// 两边各算一次迟早会错开半格。这里算一次，两边都调。
    /// </summary>
    public sealed class TacticalTile
    {
        public const double MinSize = 2.0;
        public const double MaxSize = 24.0;
        /// <summary>格子之间必须留出的自然地形间隙（米，边到边）。</summary>
        public const double MinGapM = 1.0;

        public int Index { get; set; }
        /// <summary>player / enemy / neutral（与 RegionKinds 同一套字符串）。</summary>
        public string Side { get; set; } = RegionKinds.Player;
        /// <summary>keep（主堡位） / build（普通建造位）。</summary>
        public string Role { get; set; } = "build";
        public double X { get; set; }
        public double Z { get; set; }
        public double Width { get; set; } = 6.0;
        public double Depth { get; set; } = 6.0;
        /// <summary>绕 Y 轴朝向（度）。0 = 本地 +X 指向世界 +X。</summary>
        public double YawDeg { get; set; }
        public double TerrainY { get; set; }

        /// <summary>建筑位：统一在格子左上角（本地 -X / -Z 角）。</summary>
        public Vec2 BuildingAnchorLocal => new Vec2((float)(-Width * 0.5), (float)(-Depth * 0.5));

        /// <summary>出兵位：统一在格子正中心。</summary>
        public Vec2 SquadSpawnAnchorLocal => Vec2.Zero;

        /// <summary>本地 → 世界（Godot Node3D.rotation.y 同一套旋转）。</summary>
        public Vec2 ToWorld(Vec2 local)
        {
            double yaw = YawDeg * Math.PI / 180.0;
            double c = Math.Cos(yaw);
            double s = Math.Sin(yaw);
            double wx = X + local.X * c + local.Y * s;
            double wz = Z - local.X * s + local.Y * c;
            return new Vec2((float)wx, (float)wz);
        }

        public Vec2 BuildingAnchorWorld() => ToWorld(BuildingAnchorLocal);

        public Vec2 SquadSpawnAnchorWorld() => ToWorld(SquadSpawnAnchorLocal);

        /// <summary>四个世界角点（顺序：左上 / 右上 / 右下 / 左下）。</summary>
        public Vec2[] Corners()
        {
            double hw = Width * 0.5;
            double hd = Depth * 0.5;
            return new[]
            {
                ToWorld(new Vec2((float)-hw, (float)-hd)),
                ToWorld(new Vec2((float)hw, (float)-hd)),
                ToWorld(new Vec2((float)hw, (float)hd)),
                ToWorld(new Vec2((float)-hw, (float)hd)),
            };
        }

        /// <summary>世界 AABB：minX / minZ / maxX / maxZ。</summary>
        public (double minX, double minZ, double maxX, double maxZ) Bounds()
        {
            Vec2[] c = Corners();
            double minX = c[0].X, maxX = c[0].X, minZ = c[0].Y, maxZ = c[0].Y;
            for (int i = 1; i < c.Length; i++)
            {
                minX = Math.Min(minX, c[i].X);
                maxX = Math.Max(maxX, c[i].X);
                minZ = Math.Min(minZ, c[i].Y);
                maxZ = Math.Max(maxZ, c[i].Y);
            }
            return (minX, minZ, maxX, maxZ);
        }

        /// <summary>两个格子之间**边到边**的间隙（米）。负值 = 重叠。</summary>
        public static double EdgeGap(TacticalTile a, TacticalTile b)
        {
            var ba = a.Bounds();
            var bb = b.Bounds();
            double dx = Math.Max(ba.minX - bb.maxX, bb.minX - ba.maxX);
            double dz = Math.Max(ba.minZ - bb.maxZ, bb.minZ - ba.maxZ);
            if (dx < 0 && dz < 0) return Math.Max(dx, dz); // 重叠：返回"最深的那个负值"
            return Math.Sqrt(Math.Max(dx, 0) * Math.Max(dx, 0) + Math.Max(dz, 0) * Math.Max(dz, 0));
        }

        public List<string> Validate(double sizeX, double sizeZ)
        {
            var errors = new List<string>();
            if (Index < 1) errors.Add($"tile index must be >= 1 (got {Index})");
            if (Side != RegionKinds.Player && Side != RegionKinds.Enemy && Side != RegionKinds.Neutral)
                errors.Add($"tile {Index}: side '{Side}' is not player/enemy/neutral");
            if (Role != "keep" && Role != "build")
                errors.Add($"tile {Index}: role '{Role}' is not keep/build");
            if (!Finite(X) || !Finite(Z))
                errors.Add($"tile {Index}: position is not finite");
            if (Width < MinSize || Width > MaxSize)
                errors.Add($"tile {Index}: width {Width:0.##} outside {MinSize}..{MaxSize}");
            if (Depth < MinSize || Depth > MaxSize)
                errors.Add($"tile {Index}: depth {Depth:0.##} outside {MinSize}..{MaxSize}");
            if (!Finite(TerrainY)) errors.Add($"tile {Index}: terrain_y is not finite");

            var b = Bounds();
            double hx = Math.Max(sizeX, 4.0) * 0.5;
            double hz = Math.Max(sizeZ, 4.0) * 0.5;
            if (b.minX < -hx - 0.5 || b.maxX > hx + 0.5 || b.minZ < -hz - 0.5 || b.maxZ > hz + 0.5)
                errors.Add($"tile {Index}: footprint leaves the map");
            return errors;
        }

        private static bool Finite(double v) => !double.IsNaN(v) && !double.IsInfinity(v);
    }

    /// <summary>
    /// 一组战术格子（= 一张底壳的 tiles）。校验唯一索引、每边最多一个主堡、格间必须留缝。
    /// </summary>
    public static class TacticalTileSet
    {
        public static List<string> Validate(IList<TacticalTile> tiles, double sizeX, double sizeZ, double minGapM = TacticalTile.MinGapM)
        {
            var errors = new List<string>();
            if (tiles == null) return errors;
            var seen = new HashSet<int>();
            var keeps = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (TacticalTile t in tiles)
            {
                if (t == null) continue;
                if (!seen.Add(t.Index))
                    errors.Add($"tile index {t.Index} is duplicated");
                foreach (string e in t.Validate(sizeX, sizeZ)) errors.Add(e);
                if (t.Role == "keep")
                {
                    keeps.TryGetValue(t.Side, out int n);
                    keeps[t.Side] = n + 1;
                }
            }
            foreach (var kv in keeps)
            {
                if (kv.Value > 1)
                    errors.Add($"{kv.Key} side has {kv.Value} keep tiles (need <= 1)");
            }
            for (int i = 0; i < tiles.Count; i++)
            {
                for (int j = i + 1; j < tiles.Count; j++)
                {
                    if (tiles[i] == null || tiles[j] == null) continue;
                    double gap = TacticalTile.EdgeGap(tiles[i], tiles[j]);
                    if (gap < minGapM - 1e-6)
                        errors.Add($"tile {tiles[i].Index} and {tiles[j].Index} gap {gap:0.##} m < {minGapM:0.##} m");
                }
            }
            return errors;
        }

        /// <summary>新建底壳的默认格子：两边各 1 个主堡位 + 2 个建造位，留出中间通道。</summary>
        public static List<TacticalTile> Defaults(double sizeX, double sizeZ)
        {
            double hx = Math.Max(sizeX, 40.0) * 0.5;
            double hz = Math.Max(sizeZ, 24.0) * 0.5;
            double px = -Math.Min(hx * 0.62, hx - 12.0);
            double ex = Math.Min(hx * 0.62, hx - 12.0);
            double bz = Math.Min(hz * 0.42, 12.0);

            var list = new List<TacticalTile>
            {
                New(1, RegionKinds.Player, "keep", px, 0.0, 10.0),
                New(2, RegionKinds.Player, "build", px + 10.0, -bz, 6.0),
                New(3, RegionKinds.Player, "build", px + 10.0, bz, 6.0),
                New(4, RegionKinds.Enemy, "keep", ex, 0.0, 10.0),
                New(5, RegionKinds.Enemy, "build", ex - 10.0, -bz, 6.0),
                New(6, RegionKinds.Enemy, "build", ex - 10.0, bz, 6.0),
            };
            return list;
        }

        private static TacticalTile New(int index, string side, string role, double x, double z, double size)
        {
            return new TacticalTile
            {
                Index = index,
                Side = side,
                Role = role,
                X = Math.Round(x, 2),
                Z = Math.Round(z, 2),
                Width = size,
                Depth = size,
                TerrainY = 0.0,
            };
        }
    }
}
