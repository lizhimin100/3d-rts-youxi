using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 地图底板（MapBoard）—— 底壳的"立体厚度 + 画布冗余 + 格子统一倍率"这套规则的唯一实现。
    ///
    /// 为什么要有这一层：
    ///   · 底壳从"一层薄皮"改成**带厚度的 3D 块体**以后，厚度/倒角/冗余空间都成了会影响
    ///     局内坐标的量（相机夹取范围、格子能不能放、安置装饰的边界），必须有一处说了算；
    ///   · 制作人会直接改「地图整体尺寸」与「格子统一缩放」——扩容时格子与布局要按规则联动，
    ///     不能让编辑器各写一份四舍五入。
    ///
    /// 坐标口径（与 <see cref="TacticalTile"/> / RegionPolygon 完全一致）：
    ///   · 平面尺寸 SizeX / SizeZ 是**旧地图口径的米**（底壳 size.x / size.z）；
    ///   · 画布（可编辑世界空间）= 地图尺寸 × (1 + 2 × Margin)，即四周各留 Margin 的冗余；
    ///   · 格子倍率只乘宽/深（Width/Depth），位置与锚点算法不变 —— 锚点仍然由
    ///     TacticalTile 的 BuildingAnchorLocal / SquadSpawnAnchorLocal 派生；
    ///   · 厚度只影响**表现**（侧面有多深），不参与任何战斗判定，也不改 R1。
    ///
    /// 规矩：编辑器、检查脚本、局内装配都调这里，不许在 GDScript 里再写第二份。
    /// </summary>
    public static class MapBoard
    {
        // ---- 取值范围（面板滑块与反向验错共用同一组常数）------------------
        public const double MinDepth = 1.0;
        public const double MaxDepth = 24.0;
        public const double DefaultDepth = 6.0;

        public const double MinBevel = 0.0;
        public const double MaxBevel = 1.2;
        public const double DefaultBevel = 0.35;

        /// <summary>四周冗余：玩家口径是"至少 40%~50%"，所以下限钉在 0.40。</summary>
        public const double MinMargin = 0.40;
        public const double MaxMargin = 0.50;
        public const double DefaultMargin = 0.45;

        public const double MinTileScale = 0.6;
        public const double MaxTileScale = 2.0;
        public const double DefaultTileScale = 1.0;

        /// <summary>对齐网格的可选步长（米）；0 = 自由拖拽。</summary>
        public static readonly double[] SnapSteps = { 0.0, 0.5, 1.0, 2.0, 4.0 };

        /// <summary>地图尺寸的合法范围（米）。比这个再大，底壳的 1.5m 高度场会开始掉精度。</summary>
        public const double MinMapSize = 40.0;
        public const double MaxMapSize = 400.0;

        public static double ClampDepth(double v) => Clamp(v, MinDepth, MaxDepth);
        public static double ClampBevel(double v) => Clamp(v, MinBevel, MaxBevel);
        public static double ClampMargin(double v) => Clamp(v, MinMargin, MaxMargin);
        public static double ClampTileScale(double v) => Clamp(v, MinTileScale, MaxTileScale);

        private static double Clamp(double v, double lo, double hi)
        {
            if (double.IsNaN(v) || double.IsInfinity(v)) return lo;
            return v < lo ? lo : (v > hi ? hi : v);
        }

        /// <summary>画布尺寸（可编辑世界空间）= 地图尺寸 × (1 + 2 × Margin)。</summary>
        public static double CanvasSizeX(double sizeX, double margin) =>
            Math.Max(sizeX, 1.0) * (1.0 + 2.0 * ClampMargin(margin));

        public static double CanvasSizeZ(double sizeZ, double margin) =>
            Math.Max(sizeZ, 1.0) * (1.0 + 2.0 * ClampMargin(margin));

        /// <summary>
        /// 校验一整套底板参数。返回空 = 合法；否则是给人看的中文错误。
        /// **反向验错认这几条**：冗余 &lt; 0.40、厚度 = 0、倍率 &gt; 2.0、尺寸越界。
        /// </summary>
        public static List<string> Validate(double sizeX, double sizeZ, double depth, double bevel,
            double margin, double tileScale)
        {
            var errors = new List<string>();
            if (!Finite(sizeX) || !Finite(sizeZ))
            {
                errors.Add("board: map size is not finite");
                return errors;
            }
            if (sizeX < MinMapSize || sizeX > MaxMapSize)
                errors.Add($"board: size.x {sizeX:0.##} outside {MinMapSize}..{MaxMapSize}");
            if (sizeZ < MinMapSize || sizeZ > MaxMapSize)
                errors.Add($"board: size.z {sizeZ:0.##} outside {MinMapSize}..{MaxMapSize}");
            if (!Finite(depth) || depth < MinDepth || depth > MaxDepth)
                errors.Add($"board: depth {depth:0.##} outside {MinDepth}..{MaxDepth}");
            if (!Finite(bevel) || bevel < MinBevel || bevel > MaxBevel)
                errors.Add($"board: bevel {bevel:0.##} outside {MinBevel}..{MaxBevel}");
            if (!Finite(margin) || margin < MinMargin - 1e-9 || margin > MaxMargin + 1e-9)
                errors.Add($"board: margin {margin:0.##} outside {MinMargin}..{MaxMargin}");
            if (!Finite(tileScale) || tileScale < MinTileScale || tileScale > MaxTileScale)
                errors.Add($"board: tile_scale {tileScale:0.##} outside {MinTileScale}..{MaxTileScale}");
            // 倒角不能吃掉半张地图（极小图的保护）
            if (bevel * 2.0 >= Math.Min(sizeX, sizeZ) * 0.25)
                errors.Add($"board: bevel {bevel:0.##} too large for map");
            return errors;
        }

        /// <summary>
        /// 格子统一倍率下的宽/深。**上限仍受 TacticalTile.MaxSize 约束**：
        /// 倍率调到 2.0 时 12m 的格子会想变成 24m，正好卡在边界；再大的原格子直接拒绝。
        /// 返回 false = 这个倍率放不下，调用方要把整个人话错误显示出来。
        /// </summary>
        public static bool TryScaleTileSize(double width, double depth, double scale,
            out double newWidth, out double newDepth, out string error)
        {
            newWidth = width;
            newDepth = depth;
            error = "";
            if (!Finite(scale) || scale <= 0.0)
            {
                error = $"tile scale {scale:0.##} must be > 0";
                return false;
            }
            double w = Math.Round(width * scale, 2);
            double d = Math.Round(depth * scale, 2);
            if (w < TacticalTile.MinSize || w > TacticalTile.MaxSize ||
                d < TacticalTile.MinSize || d > TacticalTile.MaxSize)
            {
                error = $"tile {width:0.##}x{depth:0.##} x{scale:0.##} -> {w:0.##}x{d:0.##} outside " +
                        $"{TacticalTile.MinSize}..{TacticalTile.MaxSize}";
                return false;
            }
            newWidth = w;
            newDepth = d;
            return true;
        }

        /// <summary>允许的最大统一倍率（面板滑块的实际上限；不是写死的 2.0）。</summary>
        public static double MaxScaleFor(double width, double depth)
        {
            double byW = TacticalTile.MaxSize / Math.Max(width, 0.001);
            double byD = TacticalTile.MaxSize / Math.Max(depth, 0.001);
            return Math.Min(MaxTileScale, Math.Min(byW, byD));
        }

        /// <summary>
        /// 地图扩容/改形时，一个已有的格子怎么跟着走：
        ///   · 位置按 X / Z 各自的**比例**缩放（布局范围联动放大，相对关系不丢）；
        ///   · 宽/深可选跟着等比放大（tileScale 由调用方决定传什么）；
        ///   · 朝向不变（旋转和米制尺寸无关）。
        /// 返回值用裸字段，桥把它翻译成 Godot Dictionary。
        /// </summary>
        public static bool TryResizeTile(double x, double z, double width, double depth,
            double oldSizeX, double oldSizeZ, double newSizeX, double newSizeZ, double tileScale,
            out double outX, out double outZ, out double outWidth, out double outDepth, out string error)
        {
            outX = x;
            outZ = z;
            outWidth = width;
            outDepth = depth;
            error = "";
            if (oldSizeX <= 0.0 || oldSizeZ <= 0.0 || newSizeX <= 0.0 || newSizeZ <= 0.0)
            {
                error = "map resize: size must be > 0";
                return false;
            }
            if (!Finite(x) || !Finite(z) || !Finite(width) || !Finite(depth))
            {
                error = "map resize: tile has non-finite fields";
                return false;
            }
            outX = Math.Round(x * (newSizeX / oldSizeX), 3);
            outZ = Math.Round(z * (newSizeZ / oldSizeZ), 3);
            return TryScaleTileSize(width, depth, tileScale, out outWidth, out outDepth, out error);
        }

        /// <summary>格子 footprint 是否仍在（扩容后的）地图内 —— 与 TacticalTile.Validate 同口径。</summary>
        public static bool FitsInside(double minX, double minZ, double maxX, double maxZ,
            double sizeX, double sizeZ)
        {
            double hx = Math.Max(sizeX, 4.0) * 0.5;
            double hz = Math.Max(sizeZ, 4.0) * 0.5;
            return minX >= -hx - 0.5 && maxX <= hx + 0.5 && minZ >= -hz - 0.5 && maxZ <= hz + 0.5;
        }

        /// <summary>地面基准色 vs 侧面：编辑器用这个判断"这个点在不在画布里"。</summary>
        public static bool InsideCanvas(double x, double z, double sizeX, double sizeZ, double margin)
        {
            double hx = CanvasSizeX(sizeX, margin) * 0.5;
            double hz = CanvasSizeZ(sizeZ, margin) * 0.5;
            return x >= -hx && x <= hx && z >= -hz && z <= hz;
        }

        private static bool Finite(double v) => !double.IsNaN(v) && !double.IsInfinity(v);
    }
}
