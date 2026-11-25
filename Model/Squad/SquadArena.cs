using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>一格上的一座建筑（玩家来自布局卡，敌人来自遭遇卡）。</summary>
    public sealed class ArenaBuilding
    {
        public int Tile;
        public string Side = RegionKinds.Player;
        public string DefId = "";
        public int Star = 1;
        public double YawDeg;
    }

    /// <summary>
    /// 小队战场（SquadArena）—— 把「底壳 spine/tiles/regions + 玩家布局卡 + 敌人遭遇卡 + 关卡轮次」
    /// 组装成纯 C# 可推演的战场。
    ///
    /// 口径：
    ///   · 元数据（JSON）用米；进 Model 立刻换成**游戏数值**（RtsUnits.ToUnits），内部再不出现米；
    ///   · 出生点唯一来源是 <see cref="TacticalTile.SquadSpawnAnchorWorld"/>（格子正中心）；
    ///   · 脊线来自 `map_shells.json` 的 `spine.points`（Catmull-Rom 采样点），等价于 Path3D 导出的路径点；
    ///   · **建筑不进入寻路**：这里只记录"哪一格有哪座建筑"，从不生成障碍。
    /// </summary>
    public sealed class SquadArena
    {
        public string Id = "";
        public string DisplayName = "";
        public string PlayerFaction = "";
        public string EnemyFaction = "";

        /// <summary>世界原点（米）：lane.x = (worldX - OriginX) / R1。</summary>
        public double OriginX;
        public double OriginZ;

        /// <summary>可走矩形（游戏数值）。</summary>
        public double MinX;
        public double MaxX;
        public double MinY;
        public double MaxY;

        public double SizeX;
        public double SizeZ;

        /// <summary>势力区边界（lane X）：玩家区 ≤ PlayerZoneEnd；敌方区 ≥ EnemyZoneStart。</summary>
        public double PlayerZoneEnd;
        public double EnemyZoneStart;

        public double PlayerBaseX;
        public double EnemyBaseX;
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        public double RoundSeconds = LevelDef.RoundSecondsSpec;
        /// <summary>
        /// 一名**单兵**停在敌区里每秒给敌方基地造成的伤害（2026-11-22 由"每队"改为"每人"）。
        /// 口径：单兵制下基地只有 60~80 血，所以这个值必须是 0.1~0.5 量级；
        /// 写 9 或 48（编制时代的数）会让 8 个人在 1 秒内把基地抽干。
        /// </summary>
        public double ZoneDpsPerUnit = 0.24;
        /// <summary>底壳声明的脊线逻辑长度（游戏数值），用来校验脊线点没有丢段。</summary>
        public double SpineLengthLogic;

        public readonly List<TacticalTile> Tiles = new List<TacticalTile>();
        public readonly List<ArenaBuilding> PlayerBuildings = new List<ArenaBuilding>();
        public readonly List<ArenaBuilding> EnemyBuildings = new List<ArenaBuilding>();
        public readonly List<LevelRound> Rounds = new List<LevelRound>();
        public readonly List<string> Notes = new List<string>();

        /// <summary>关卡定义（单轮波次 + battlefield 几何的唯一来源）。</summary>
        public LevelDef Level;
        /// <summary>原始 JSON（只读）：BoardSession 需要 shell/layout 来建棋盘拓扑。</summary>
        public IDictionary<string, object> ShellDict;
        public IDictionary<string, object> LayoutDict;

        /// <summary>战场几何（部署线/宽度/边距）。</summary>
        public Battlefield Battlefield => Level != null ? Level.Battlefield : new Battlefield();

        public SquadRouteGraph Route;
        public int PlayerBaseTile;
        public int EnemyBaseTile;
        public int PlayerBarracksTile;
        public int EnemyBarracksTile;
        /// <summary>中立据点格（side=neutral、role=build 的第一格）；0 = 这张底壳没有据点。</summary>
        public int NeutralOutpostTile;

        /// <summary>中立区靠我方一侧的世界 X（= 玩家区边界，米）。</summary>
        public double NeutralStartWorldX => OriginX + PlayerZoneEnd * RtsUnits.R1;

        /// <summary>中立区靠敌方一侧的世界 X（米）。</summary>
        public double NeutralEndWorldX => OriginX + EnemyZoneStart * RtsUnits.R1;

        /// <summary>
        /// 已占领据点时进攻小队的出发点（世界米，lane Z=0）：中立区靠敌侧，再退 6 米。
        /// 这条口径的唯一实现，UI/自检都读它，不许各写一份。
        /// </summary>
        public Vec2 OutpostStageWorld()
        {
            double x = NeutralEndWorldX - 6.0;
            return new Vec2((float)x, 0f);
        }

        /// <summary>
        /// 没买据点时的进攻出发点：**玩家区前缘**（边界内侧 8 米）。
        /// 为什么不是"从建造格出发"：单场只有 60 秒，从棋盘后排走到敌方基地要 30 秒以上，
        /// 等于把一整场耗在行军上；"前缘集结"是小队玩法的预设偏好，不是玩家微操。
        /// </summary>
        public Vec2 PlayerFrontStageWorld()
        {
            double x = NeutralStartWorldX - 8.0;
            return new Vec2((float)x, 0f);
        }

        /// <summary>本场进攻小队的出发点：买了据点走据点，否则走玩家区前缘。</summary>
        public Vec2 AttackStageWorld(bool outpostCaptured)
        {
            return outpostCaptured ? OutpostStageWorld() : PlayerFrontStageWorld();
        }

        /// <summary>
        /// 打建造牌时把建筑落到指定战术格子（Screens 只报"玩家点了哪一格"）。
        /// 同一格已有建筑 → 拒绝；格子不存在 → 拒绝。
        /// </summary>
        public bool AddPlayerBuilding(int tileIndex, string defId, int star = 1)
        {
            TacticalTile t = Tile(tileIndex);
            if (t == null || t.Side != RegionKinds.Player) return false;
            if (string.IsNullOrEmpty(defId)) return false;
            for (int i = 0; i < PlayerBuildings.Count; i++)
            {
                if (PlayerBuildings[i].Tile == tileIndex) return false;
            }
            PlayerBuildings.Add(new ArenaBuilding
            {
                Tile = tileIndex,
                Side = RegionKinds.Player,
                DefId = defId,
                Star = Math.Max(star, 1),
            });
            if (defId == "barracks" && PlayerBarracksTile == 0) PlayerBarracksTile = tileIndex;
            return true;
        }

        /// <summary>某一格上是否已经有玩家建筑。</summary>
        public bool PlayerTileOccupied(int tileIndex)
        {
            for (int i = 0; i < PlayerBuildings.Count; i++)
            {
                if (PlayerBuildings[i].Tile == tileIndex) return true;
            }
            return false;
        }

        public Vec2 WorldToLane(double worldX, double worldZ)
        {
            return new Vec2(
                (float)RtsUnits.ToUnits(worldX - OriginX),
                (float)RtsUnits.ToUnits(worldZ - OriginZ));
        }

        public Vec2 LaneToWorld(double x, double z)
        {
            return new Vec2(
                (float)(OriginX + x * RtsUnits.R1),
                (float)(OriginZ + z * RtsUnits.R1));
        }

        public TacticalTile Tile(int index)
        {
            for (int i = 0; i < Tiles.Count; i++)
            {
                if (Tiles[i].Index == index) return Tiles[i];
            }
            return null;
        }

        public Vec2 TileSpawnWorld(int index)
        {
            TacticalTile t = Tile(index);
            if (t != null) return t.SquadSpawnAnchorWorld();
            if (PlayerBaseTile > 0)
            {
                TacticalTile b = Tile(PlayerBaseTile);
                if (b != null) return b.SquadSpawnAnchorWorld();
            }
            return new Vec2(0f, 0f);
        }

        public List<ArenaBuilding> BuildingsOf(string side, string defId)
        {
            var src = side == RegionKinds.Player ? PlayerBuildings : EnemyBuildings;
            var list = new List<ArenaBuilding>();
            for (int i = 0; i < src.Count; i++)
            {
                if (string.IsNullOrEmpty(defId) || src[i].DefId == defId) list.Add(src[i]);
            }
            return list;
        }

        public int FirstTileOfBuilding(string side, string defId)
        {
            var list = BuildingsOf(side, defId);
            return list.Count > 0 ? list[0].Tile : 0;
        }

        // =================================================================
        // 装载
        // =================================================================
        public static SquadArena FromDict(
            IDictionary<string, object> level,
            IDictionary<string, object> shell,
            IDictionary<string, object> layout,
            IDictionary<string, object> encounter,
            UnitCatalog units,
            IDictionary<string, object> tuning = null)
        {
            var arena = new SquadArena();
            arena.ShellDict = shell;
            arena.LayoutDict = layout;

            // ---- 底壳几何 ----
            var size = JVal.Dict(shell, "size");
            arena.SizeX = JVal.Double(size, "x", 0.0);
            arena.SizeZ = JVal.Double(size, "z", 0.0);
            if (arena.SizeX <= 0.0 || arena.SizeZ <= 0.0)
            {
                arena.Notes.Add("底壳 size 缺失或非法");
                arena.SizeX = 120.0;
                arena.SizeZ = 63.0;
            }
            arena.OriginX = -arena.SizeX * 0.5;
            arena.OriginZ = 0.0;
            arena.MinX = 0.0;
            arena.MaxX = RtsUnits.ToUnits(arena.SizeX);
            arena.MinY = -RtsUnits.ToUnits(arena.SizeZ * 0.5);
            arena.MaxY = RtsUnits.ToUnits(arena.SizeZ * 0.5);

            var spine = JVal.Dict(shell, "spine");
            var ridge = new List<Vec2>();
            var pts = JVal.List(spine, "points");
            if (pts != null)
            {
                foreach (object o in pts)
                {
                    var pd = JVal.AsDict(o);
                    if (pd == null) continue;
                    double wx = JVal.Double(pd, "x", 0.0);
                    double wz = JVal.Double(pd, "z", 0.0);
                    ridge.Add(arena.WorldToLane(wx, wz));
                }
            }
            double spineWidth = JVal.Double(spine, "width_logic", 420.0);
            arena.SpineLengthLogic = JVal.Double(spine, "length_logic", 0.0);
            double corridor = Math.Max(spineWidth * 0.20, 60.0);
            arena.Route = new SquadRouteGraph(ridge, arena.MinX, arena.MaxX, arena.MinY, arena.MaxY, corridor);

            // ---- 战术格子 ----
            var tiles = JVal.List(shell, "tiles");
            if (tiles != null)
            {
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
                    arena.Tiles.Add(t);
                }
            }

            // ---- 势力区 → 抽血边界 ----
            var regions = JVal.Dict(shell, "regions");
            double playerMaxX = double.MinValue;
            double enemyMinX = double.MaxValue;
            CollectRegionX(JVal.List(regions, "player"), ref playerMaxX, ref enemyMinX, true);
            CollectRegionX(JVal.List(regions, "enemy"), ref playerMaxX, ref enemyMinX, false);
            if (playerMaxX > double.MinValue)
                arena.PlayerZoneEnd = (float)RtsUnits.ToUnits(playerMaxX - arena.OriginX);
            else
                arena.PlayerZoneEnd = arena.MaxX * 0.33;
            if (enemyMinX < double.MaxValue)
                arena.EnemyZoneStart = (float)RtsUnits.ToUnits(enemyMinX - arena.OriginX);
            else
                arena.EnemyZoneStart = arena.MaxX * 0.67 - 1.0;

            // ---- 关卡：单轮波次 + 战场几何（唯一解析点 = LevelDef） ----
            arena.Level = LevelDef.FromDict(level, units, arena.Notes);
            arena.Id = JVal.Str(level, "id", JVal.Str(shell, "id", "squad_arena"));
            arena.DisplayName = JVal.Str(level, "display_name", arena.Id);
            arena.PlayerFaction = JVal.Str(level, "player_faction", "alliance");
            arena.EnemyFaction = JVal.Str(encounter, "faction", JVal.Str(level, "enemy_faction", "bandit"));
            arena.PlayerBaseHp = arena.Level.PlayerBaseHp;
            // 2026-11-24：关卡是运行时唯一真源；遭遇卡的 base_hp 只留给生成器建议，不再覆盖。
            arena.EnemyBaseHp = arena.Level.EnemyBaseHp;
            arena.RoundSeconds = arena.Level.RoundSeconds;
            arena.ZoneDpsPerUnit = 0.0; // 占区抽血已删除，字段只留给桥契约

            arena.Rounds.Clear();
            arena.Rounds.AddRange(arena.Level.Rounds);

            // ---- 建筑：玩家布局卡 + 敌人遭遇卡 ----
            var slots = JVal.List(layout, "slots");
            if (slots != null)
            {
                foreach (object o in slots)
                {
                    var sd = JVal.AsDict(o);
                    if (sd == null) continue;
                    arena.PlayerBuildings.Add(new ArenaBuilding
                    {
                        Tile = JVal.Int(sd, "tile", 0),
                        Side = RegionKinds.Player,
                        DefId = JVal.Str(sd, "building", ""),
                        Star = Math.Max(JVal.Int(sd, "star", 1), 1),
                    });
                }
            }
            var enemySlots = JVal.List(encounter, "tile_buildings");
            if (enemySlots != null)
            {
                foreach (object o in enemySlots)
                {
                    var sd = JVal.AsDict(o);
                    if (sd == null) continue;
                    arena.EnemyBuildings.Add(new ArenaBuilding
                    {
                        Tile = JVal.Int(sd, "tile", 0),
                        Side = RegionKinds.Enemy,
                        DefId = JVal.Str(sd, "building", ""),
                        Star = Math.Max(JVal.Int(sd, "star", 1), 1),
                        YawDeg = JVal.Double(sd, "yaw", 0.0),
                    });
                }
            }

            arena.PlayerBaseTile = FindRoleTile(arena, RegionKinds.Player, "keep");
            arena.EnemyBaseTile = FindRoleTile(arena, RegionKinds.Enemy, "keep");
            arena.NeutralOutpostTile = FindSideTile(arena, RegionKinds.Neutral);
            arena.PlayerBarracksTile = arena.FirstTileOfBuilding(RegionKinds.Player, "barracks");
            if (arena.PlayerBarracksTile == 0) arena.PlayerBarracksTile = arena.PlayerBaseTile;
            arena.EnemyBarracksTile = arena.FirstTileOfBuilding(RegionKinds.Enemy, "barracks");
            if (arena.EnemyBarracksTile == 0) arena.EnemyBarracksTile = arena.EnemyBaseTile;

            TacticalTile pb = arena.Tile(arena.PlayerBaseTile);
            TacticalTile eb = arena.Tile(arena.EnemyBaseTile);
            arena.PlayerBaseX = pb != null ? arena.WorldToLane(pb.X, pb.Z).X : arena.MinX + 200.0;
            arena.EnemyBaseX = eb != null ? arena.WorldToLane(eb.X, eb.Z).X : arena.MaxX - 200.0;

            _ = units;
            return arena;
        }

        private static void CollectRegionX(List<object> poly, ref double playerMaxX, ref double enemyMinX, bool isPlayer)
        {
            if (poly == null) return;
            foreach (object o in poly)
            {
                var pair = JVal.AsList(o);
                if (pair == null || pair.Count < 2) continue;
                double x = JVal.ToDouble(pair[0], 0.0);
                if (isPlayer)
                {
                    if (x > playerMaxX) playerMaxX = x;
                }
                else
                {
                    if (x < enemyMinX) enemyMinX = x;
                }
            }
        }

        private static int FindRoleTile(SquadArena arena, string side, string role)
        {
            for (int i = 0; i < arena.Tiles.Count; i++)
            {
                TacticalTile t = arena.Tiles[i];
                if (t.Side == side && t.Role == role) return t.Index;
            }
            for (int i = 0; i < arena.Tiles.Count; i++)
            {
                if (arena.Tiles[i].Side == side) return arena.Tiles[i].Index;
            }
            return 0;
        }

        /// <summary>某一侧的第一个格子（中立据点用；找不到 = 0）。</summary>
        private static int FindSideTile(SquadArena arena, string side)
        {
            for (int i = 0; i < arena.Tiles.Count; i++)
            {
                if (arena.Tiles[i].Side == side) return arena.Tiles[i].Index;
            }
            return 0;
        }

        // =================================================================
        // 校验
        // =================================================================
        public List<string> Validate(UnitCatalog units, string expectedEnemyFaction = "")
        {
            var errors = new List<string>();
            errors.AddRange(Notes);

            if (SizeX <= 0.0 || SizeZ <= 0.0) errors.Add($"arena：底壳 size 非法（{SizeX}×{SizeZ} 米）");
            if (Route == null || !Route.Valid)
                errors.Add("arena：脊线至少要有 2 个路径点（shell.spine.points）");

            if (Route != null && Route.Valid)
            {
                var ridge = Route.Ridge;
                double prevX = double.MinValue;
                for (int i = 0; i < ridge.Count; i++)
                {
                    Vec2 p = ridge[i];
                    if (p.X < prevX - 1e-6)
                        errors.Add($"arena：脊线第 {i} 点 X 回折（{p.X:0} < {prevX:0}）");
                    prevX = p.X;
                    if (!Route.Contains(p))
                        errors.Add($"arena：脊线第 {i} 点 ({p.X:0},{p.Y:0}) 跑出可走区");
                }
                double len = Route.PathLength(ridge);
                if (SpineLengthLogic > 0.0)
                {
                    if (len < SpineLengthLogic * 0.85 || len > SpineLengthLogic * 1.15)
                        errors.Add($"arena：脊线长度 {len:0} 与底壳声明 {SpineLengthLogic:0} 差超过 15%");
                }
                else
                {
                    double expect = RtsUnits.ToUnits(SizeX);
                    if (len < expect * 0.55)
                        errors.Add($"arena：脊线长度 {len:0} 不到地图宽度 {expect:0} 的 55%");
                }
            }

            if (Tiles.Count == 0)
            {
                errors.Add("arena：没有战术格子（shell.tiles）");
            }
            else
            {
                errors.AddRange(TacticalTileSet.Validate(Tiles, SizeX, SizeZ));
                foreach (TacticalTile t in Tiles)
                {
                    Vec2 spawn = WorldToLane(t.SquadSpawnAnchorWorld().X, t.SquadSpawnAnchorWorld().Y);
                    if (!Route.Contains(spawn))
                        errors.Add($"arena：格子 {t.Index} 的出兵锚点跑出可走区");
                }
            }

            if (PlayerZoneEnd <= MinX || PlayerZoneEnd >= MaxX)
                errors.Add($"arena：玩家区边界 {PlayerZoneEnd:0} 越界");
            if (EnemyZoneStart <= MinX || EnemyZoneStart >= MaxX)
                errors.Add($"arena：敌方区边界 {EnemyZoneStart:0} 越界");
            if (PlayerZoneEnd >= EnemyZoneStart)
                errors.Add($"arena：玩家区边界 {PlayerZoneEnd:0} 必须小于敌方区边界 {EnemyZoneStart:0}");
            if (PlayerBaseTile == 0) errors.Add("arena：玩家侧没有主堡格（role=keep）");
            if (EnemyBaseTile == 0) errors.Add("arena：敌方侧没有主堡格（role=keep）");
            if (PlayerBaseHp <= 0.0) errors.Add($"arena：player_base_hp={PlayerBaseHp} 必须 > 0");
            if (EnemyBaseHp <= 0.0) errors.Add($"arena：enemy_base_hp={EnemyBaseHp} 必须 > 0");
            if (RoundSeconds <= 0.0 || RoundSeconds > 120.0)
                errors.Add($"arena：round_seconds={RoundSeconds} 非法");
            // 占区抽血已删除：ZoneDpsPerUnit 不再参与校验。

            var seenTiles = new HashSet<int>();
            foreach (TacticalTile t in Tiles) seenTiles.Add(t.Index);
            ValidateBuildings(PlayerBuildings, RegionKinds.Player, seenTiles, errors);
            ValidateBuildings(EnemyBuildings, RegionKinds.Enemy, seenTiles, errors);

            bool playerBarracks = false;
            foreach (ArenaBuilding b in PlayerBuildings)
            {
                if (b.DefId == "barracks") playerBarracks = true;
            }
            if (!playerBarracks)
                errors.Add("arena：玩家侧至少要有 1 座兵营（否则训练牌没有出兵锚点）");

            if (string.IsNullOrEmpty(PlayerFaction)) errors.Add("arena：缺 player_faction");
            if (string.IsNullOrEmpty(EnemyFaction)) errors.Add("arena：缺 enemy_faction");
            if (units != null)
            {
                if (units.GetFaction(PlayerFaction) == null)
                    errors.Add($"arena：player_faction={PlayerFaction} 未定义");
                if (units.GetFaction(EnemyFaction) == null)
                    errors.Add($"arena：enemy_faction={EnemyFaction} 未定义");
            }
            if (!string.IsNullOrEmpty(expectedEnemyFaction) && expectedEnemyFaction != EnemyFaction)
                errors.Add($"arena：关卡敌方阵营 {expectedEnemyFaction} 与遭遇卡 {EnemyFaction} 不一致");

            // 单轮单场死斗：轮次只按回合序，不再要求 attack/defend。校验统一交给 LevelDef。
            if (Level != null) errors.AddRange(Level.Validate(units));
            else errors.Add("arena：缺关卡定义（LevelDef）");

            foreach (LevelRound round in Rounds)
            {
                if (round.Waves.Count == 0)
                    errors.Add($"arena：{round.Label} 没有波次");
                foreach (Wave wave in round.Waves)
                {
                    if (wave.T < 0.0 || wave.T > RoundSeconds + 1e-6)
                        errors.Add($"arena：{round.Label} 波次时间 {wave.T} 越界（0..{RoundSeconds}）");
                    if (wave.Squads.Count == 0)
                        errors.Add($"arena：{round.Label} t={wave.T} 是空波次");
                    foreach (WaveSquad sq in wave.Squads)
                    {
                        UnitDef def = units != null ? units.Get(sq.Unit) : null;
                        if (def == null)
                        {
                            errors.Add($"arena：波次引用未定义单位 {sq.Unit}");
                            continue;
                        }
                        if (!def.Enabled) errors.Add($"arena：波次引用已禁用单位 {sq.Unit}");
                        if (!string.IsNullOrEmpty(EnemyFaction) && def.Faction != EnemyFaction)
                            errors.Add($"arena：波次单位 {sq.Unit} 不属于敌方阵营 {EnemyFaction}");
                        if (sq.Count < 1 || sq.Count > 24)
                            errors.Add($"arena：波次 {sq.Unit} count={sq.Count} 越界（1..24 名单兵）");
                        if (sq.Star < 1 || sq.Star > 3)
                            errors.Add($"arena：波次 {sq.Unit} star={sq.Star} 越界（1..3）");
                    }
                }
            }

            return errors;
        }

        private static void ValidateBuildings(List<ArenaBuilding> list, string side, HashSet<int> tiles, List<string> errors)
        {
            var seen = new HashSet<int>();
            foreach (ArenaBuilding b in list)
            {
                if (!tiles.Contains(b.Tile))
                    errors.Add($"arena：{side} 建筑 {b.DefId} 指向不存在的格子 {b.Tile}");
                if (b.Side != side)
                    errors.Add($"arena：{side} 建筑 {b.DefId} 的 side={b.Side} 不一致");
                if (string.IsNullOrEmpty(b.DefId))
                    errors.Add($"arena：{side} 格子 {b.Tile} 的建筑缺 id");
                if (!seen.Add(b.Tile))
                    errors.Add($"arena：{side} 格子 {b.Tile} 放了不止一座建筑");
                if (b.Star < 1 || b.Star > 3)
                    errors.Add($"arena：{side} 建筑 {b.DefId} star={b.Star} 越界（1..3）");
            }
        }
    }
}
