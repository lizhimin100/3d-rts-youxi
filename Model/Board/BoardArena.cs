using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>棋盘上的一座建筑（tile 为唯一位置；star 由 3 合 1 提升）。</summary>
    public sealed class BoardBuilding
    {
        public int Tile;
        public string DefId = "";
        public int Star = 1;
        /// <summary>layout（开局预设）/ build（规划期打牌）/ test（自检）。</summary>
        public string Source = "build";

        public BoardBuilding Clone()
        {
            return new BoardBuilding { Tile = Tile, DefId = DefId, Star = Star, Source = Source };
        }
    }

    /// <summary>
    /// 棋盘拓扑（BoardArena）—— **只管空间，不管规则**。
    ///
    /// 口径（2026-11-24 冻结）：
    ///   · 玩家棋盘按**竖列**组织，每列 3 格；列序 = X 从小到大，行序 = Z 从小到大（上→下）；
    ///   · 新建筑必须按「当前列从上到下填满 → 下一列」的顺序落位（唯一实现在 BoardSession）；
    ///   · 这里提供标准网格查询：上下左右邻居、跨格偏移、曼哈顿距离、列/行号；
    ///   · 光环/经济建筑靠这些查询算空间关系，不许在战斗代码里再写一套坐标判断。
    ///
    /// 只读 `map_shells.json` 的 tiles 与 `player_layouts.json` 的 active_tiles；
    /// 不读 Godot，不写世界坐标（tiles 本身是米，落位由 Screens 处理）。
    /// </summary>
    public sealed class BoardArena
    {
        /// <summary>玩家可建造格（不含主堡格），按列/行升序。</summary>
        public readonly List<TacticalTile> Tiles = new List<TacticalTile>();
        public readonly List<int> Columns = new List<int>();
        public readonly List<int> Rows = new List<int>();
        public readonly List<string> Notes = new List<string>();

        private readonly Dictionary<int, int> _tileToCol = new Dictionary<int, int>();
        private readonly Dictionary<int, int> _tileToRow = new Dictionary<int, int>();
        private readonly Dictionary<long, int> _cellToTile = new Dictionary<long, int>();
        private readonly Dictionary<int, TacticalTile> _tileByIndex = new Dictionary<int, TacticalTile>();
        private readonly HashSet<int> _active = new HashSet<int>();

        public int KeepTile;
        /// <summary>规则钩子：允许自由选格（遗物/策略牌将来打破列顺序）。</summary>
        public bool AllowFreePlacement;
        /// <summary>规则钩子：允许两格互换。</summary>
        public bool AllowSwap;

        public int ColumnCount => Columns.Count;
        public int RowCount => Rows.Count;
        public int TileCount => Tiles.Count;

        public static BoardArena FromShell(
            IDictionary<string, object> shell,
            IDictionary<string, object> layout,
            List<string> notes)
        {
            var arena = new BoardArena();
            if (notes != null) arena.Notes.AddRange(notes);
            if (shell == null)
            {
                arena.Notes.Add("棋盘缺底壳（shell）");
                return arena;
            }

            var active = new HashSet<int>();
            if (layout != null)
            {
                var raw = JVal.List(layout, "active_tiles");
                if (raw != null)
                {
                    foreach (object o in raw)
                    {
                        int t = JVal.ToInt(o, 0);
                        if (t > 0) active.Add(t);
                    }
                }
            }

            var tiles = JVal.List(shell, "tiles");
            if (tiles == null)
            {
                arena.Notes.Add("底壳没有 tiles");
                return arena;
            }

            var player = new List<TacticalTile>();
            foreach (object o in tiles)
            {
                var td = JVal.AsDict(o);
                if (td == null) continue;
                var t = new TacticalTile
                {
                    Index = JVal.Int(td, "index", 0),
                    Side = JVal.Str(td, "side", RegionKinds.Player),
                    Role = JVal.Str(td, "role", "build"),
                    X = JVal.Double(td, "x", 0.0),
                    Z = JVal.Double(td, "z", 0.0),
                    Width = JVal.Double(td, "w", 6.0),
                    Depth = JVal.Double(td, "d", 6.0),
                    YawDeg = JVal.Double(td, "yaw", 0.0),
                    TerrainY = JVal.Double(td, "terrain_y", 0.0),
                };
                if (t.Side != RegionKinds.Player) continue;
                if (t.Role == "keep")
                {
                    if (arena.KeepTile == 0) arena.KeepTile = t.Index;
                    continue;
                }
                if (active.Count > 0 && !active.Contains(t.Index)) continue;
                player.Add(t);
            }

            // 列 / 行：按坐标聚类（毫米取整，避免浮点误差把同一列拆成两列）
            var colKeys = new List<int>();
            var rowKeys = new List<int>();
            foreach (TacticalTile t in player)
            {
                int cx = (int)Math.Round(t.X * 1000.0);
                int cz = (int)Math.Round(t.Z * 1000.0);
                if (!colKeys.Contains(cx)) colKeys.Add(cx);
                if (!rowKeys.Contains(cz)) rowKeys.Add(cz);
            }
            colKeys.Sort();
            rowKeys.Sort();
            arena.Columns.AddRange(colKeys);
            arena.Rows.AddRange(rowKeys);

            player.Sort((a, b) =>
            {
                int ca = arena.Columns.IndexOf((int)Math.Round(a.X * 1000.0));
                int cb = arena.Columns.IndexOf((int)Math.Round(b.X * 1000.0));
                if (ca != cb) return ca.CompareTo(cb);
                int ra = arena.Rows.IndexOf((int)Math.Round(a.Z * 1000.0));
                int rb = arena.Rows.IndexOf((int)Math.Round(b.Z * 1000.0));
                return ra.CompareTo(rb);
            });

            foreach (TacticalTile t in player)
            {
                int col = arena.Columns.IndexOf((int)Math.Round(t.X * 1000.0));
                int row = arena.Rows.IndexOf((int)Math.Round(t.Z * 1000.0));
                if (col < 0 || row < 0) continue;
                arena.Tiles.Add(t);
                arena._active.Add(t.Index);
                arena._tileByIndex[t.Index] = t;
                arena._tileToCol[t.Index] = col;
                arena._tileToRow[t.Index] = row;
                arena._cellToTile[Key(col, row)] = t.Index;
            }

            if (arena.Tiles.Count == 0) arena.Notes.Add("棋盘没有玩家可建造格（active_tiles 是否把格子全关了？）");
            if (arena.KeepTile == 0) arena.Notes.Add("棋盘没有主堡格（role=keep）");
            return arena;
        }

        private static long Key(int col, int row) => ((long)col << 32) ^ (uint)row;

        public bool IsActive(int tile) => _active.Contains(tile);

        public TacticalTile Tile(int index)
        {
            return _tileByIndex.TryGetValue(index, out TacticalTile t) ? t : null;
        }

        public int ColumnOf(int tile) => _tileToCol.TryGetValue(tile, out int c) ? c : -1;
        public int RowOf(int tile) => _tileToRow.TryGetValue(tile, out int r) ? r : -1;

        /// <summary>格子在网格里的稳定排序键（列优先，再行）。</summary>
        public int OrderOf(int tile)
        {
            int c = ColumnOf(tile);
            int r = RowOf(tile);
            if (c < 0 || r < 0) return int.MaxValue;
            int rows = Math.Max(RowCount, 1);
            return c * rows + r;
        }

        /// <summary>标准四邻：0=上(-行) 1=下(+行) 2=左(-列) 3=右(+列)；没有格子返回 0。</summary>
        public int Neighbor(int tile, int dir)
        {
            switch (dir)
            {
                case 0: return Offset(tile, 0, -1);
                case 1: return Offset(tile, 0, 1);
                case 2: return Offset(tile, -1, 0);
                case 3: return Offset(tile, 1, 0);
                default: return 0;
            }
        }

        /// <summary>跨格偏移（列 +dc、行 +dr）；目标不存在 / 未激活返回 0。</summary>
        public int Offset(int tile, int dCol, int dRow)
        {
            int c = ColumnOf(tile);
            int r = RowOf(tile);
            if (c < 0 || r < 0) return 0;
            int nc = c + dCol;
            int nr = r + dRow;
            if (nc < 0 || nc >= ColumnCount || nr < 0 || nr >= RowCount) return 0;
            return _cellToTile.TryGetValue(Key(nc, nr), out int found) ? found : 0;
        }

        /// <summary>两格的曼哈顿格距；任一格不在网格上返回 int.MaxValue。</summary>
        public int Manhattan(int a, int b)
        {
            int ca = ColumnOf(a);
            int ra = RowOf(a);
            int cb = ColumnOf(b);
            int rb = RowOf(b);
            if (ca < 0 || ra < 0 || cb < 0 || rb < 0) return int.MaxValue;
            return Math.Abs(ca - cb) + Math.Abs(ra - rb);
        }

        /// <summary>当前第一个应该填的格子（列优先、行优先，跳过已占/未激活）。0 = 满了。</summary>
        public int NextFillTile(ICollection<int> occupied)
        {
            for (int c = 0; c < ColumnCount; c++)
            {
                for (int r = 0; r < RowCount; r++)
                {
                    if (!_cellToTile.TryGetValue(Key(c, r), out int tile)) continue;
                    if (occupied != null && occupied.Contains(tile)) continue;
                    return tile;
                }
            }
            return 0;
        }

        public List<int> EmptyTiles(ICollection<int> occupied)
        {
            var list = new List<int>();
            for (int i = 0; i < Tiles.Count; i++)
            {
                int t = Tiles[i].Index;
                if (occupied != null && occupied.Contains(t)) continue;
                list.Add(t);
            }
            return list;
        }

        public List<string> Validate()
        {
            var errors = new List<string>();
            errors.AddRange(Notes);
            if (Tiles.Count == 0) return errors;

            if (RowCount < 1 || ColumnCount < 1)
                errors.Add("棋盘列/行数为 0");
            if (RowCount > 3)
                errors.Add($"棋盘每列 {RowCount} 行，冻结规格是 3 格/列（检查底壳 tiles）");

            var seen = new HashSet<int>();
            foreach (TacticalTile t in Tiles)
            {
                if (!seen.Add(t.Index))
                    errors.Add($"棋盘格子 {t.Index} 重复");
                if (t.Side != RegionKinds.Player)
                    errors.Add($"棋盘格子 {t.Index} 不是玩家侧");
                if (t.Index == KeepTile)
                    errors.Add($"主堡格 {t.Index} 不该出现在可建造列表里");
            }

            for (int c = 0; c < ColumnCount; c++)
            {
                int count = 0;
                for (int r = 0; r < RowCount; r++)
                {
                    if (_cellToTile.ContainsKey(Key(c, r))) count++;
                }
                if (count == 0)
                    errors.Add($"棋盘第 {c} 列没有任何格子");
            }
            return errors;
        }
    }
}
