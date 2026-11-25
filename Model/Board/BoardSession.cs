using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>布局卡上的一个开局槽位（tile = 战术格，star = 开局星级）。</summary>
    public sealed class BoardLayoutSlot
    {
        public int Tile;
        public string DefId = "";
        public int Star = 1;
    }

    /// <summary>
    /// 棋盘上发生的一件事（2026-11-25 Phase 3 的表现层契约）。
    ///
    /// 口径：**只有两个 kind** ——
    ///   · `placed`   —— 建造牌落位成功（`DefId` = 建筑 id，`Star` = 1）；
    ///   · `upgraded` —— 3 合 1 升星（`Star` = 新星级，最高 3）。
    /// 周末接"天降落子 / 升星金光"直接用这两个事件，不要自己比较前后快照。
    /// 格子坐标一次给全：`Col/Row` 是 6 列 × 3 行的逻辑坐标，`Tile` 是数据里的格子号。
    /// </summary>
    public sealed class BoardEvent
    {
        public string Kind = "";
        public int Tile;
        public int Col;
        public int Row;
        public string DefId = "";
        public int Star;
        /// <summary>事件发生时的规划编号（第几次规划），用于表现层排序/去重。</summary>
        public int PlanningIndex;
    }

    /// <summary>
    /// 棋盘会话（BoardSession）—— 规划期的唯一规则实现。
    ///
    /// 负责：
    ///   · CP / 人口 / 手牌 / 建筑 / 升星（委托 <see cref="PlanningMatch"/>，不写第二份）；
    ///   · **竖列顺序落子**（每列 3 格，填满才开下一列）；AllowFreePlacement/AllowSwap 是预留钩子；
    ///   · 3 合 1（同名、未满星、目标格保留）与拆除（空出的格子成为下一个优先填充位）；
    ///   · 经济/光环按 MechanicBus 求值，打包成 <see cref="ArmyPlan.Modifiers"/>；
    ///   · 产出一份 <see cref="ArmyPlan"/>，不碰任何战斗实体/坐标。
    ///
    /// 不负责：战斗（BattleSession）、表现（Screens）。
    /// </summary>
    public sealed class BoardSession
    {
        public readonly PlanningConfig Cfg;
        public readonly UnitCatalog Units;
        public readonly BoardArena Arena;
        public readonly PlanningMatch Match;

        private readonly Dictionary<int, int> _plotTile = new Dictionary<int, int>();
        private readonly Dictionary<int, PlanBuilding> _plotBuilding = new Dictionary<int, PlanBuilding>();
        private readonly Dictionary<int, BoardBuilding> _byTile = new Dictionary<int, BoardBuilding>();
        private readonly List<string> _log = new List<string>();

        /// <summary>本局累计的规划编号（Match.PlanningIndex 同步）。</summary>
        public int PlanningIndex => Match.PlanningIndex;
        public int LastEconomyCp { get; private set; }
        public IReadOnlyList<string> Log => _log;

        // ---- 2026-11-25 Phase 3：建筑事件队列（表现层"天降落子 / 升星金光"的唯一来源）----
        private readonly List<BoardEvent> _events = new List<BoardEvent>();

        /// <summary>排空建筑事件队列（UI 每帧调一次）。</summary>
        public List<BoardEvent> DrainEvents()
        {
            var list = new List<BoardEvent>(_events.Count);
            list.AddRange(_events);
            _events.Clear();
            return list;
        }

        /// <summary>下一个必须填的格子坐标；0 / -1 = 棋盘满了。</summary>
        public int NextFillCol => NextFillTile() > 0 ? Arena.ColumnOf(NextFillTile()) : -1;
        public int NextFillRow => NextFillTile() > 0 ? Arena.RowOf(NextFillTile()) : -1;

        private void Emit(string kind, int tile, string defId, int star)
        {
            _events.Add(new BoardEvent
            {
                Kind = kind,
                Tile = tile,
                Col = Arena.ColumnOf(tile),
                Row = Arena.RowOf(tile),
                DefId = defId ?? "",
                Star = star,
                PlanningIndex = Match.PlanningIndex,
            });
        }

        public bool AllowFreePlacement
        {
            get => Arena.AllowFreePlacement;
            set => Arena.AllowFreePlacement = value;
        }

        public bool AllowSwap
        {
            get => Arena.AllowSwap;
            set => Arena.AllowSwap = value;
        }

        private BoardSession(PlanningConfig cfg, UnitCatalog units, BoardArena arena, int seed)
        {
            Cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
            Units = units ?? throw new ArgumentNullException(nameof(units));
            Arena = arena ?? throw new ArgumentNullException(nameof(arena));
            Match = new PlanningMatch(cfg, units, seed);
        }

        /// <summary>
        /// 从底壳 + 布局卡建棋盘会话。布局卡的 slots 是**开局建筑**的唯一来源；
        /// planning.json 的 board.start 只用于数据自检（两边必须一致）。
        /// </summary>
        public static BoardSession Create(
            PlanningConfig cfg,
            UnitCatalog units,
            IDictionary<string, object> shell,
            IDictionary<string, object> layout,
            int seed,
            List<string> notes)
        {
            var arena = BoardArena.FromShell(shell, layout, notes);
            var session = new BoardSession(cfg, units, arena, seed);
            session.LoadLayout(layout);
            return session;
        }

        private void LoadLayout(IDictionary<string, object> layout)
        {
            var slots = new List<BoardLayoutSlot>();
            var raw = layout != null ? JVal.List(layout, "slots") : null;
            if (raw != null)
            {
                foreach (object o in raw)
                {
                    var sd = JVal.AsDict(o);
                    if (sd == null) continue;
                    int tile = JVal.Int(sd, "tile", 0);
                    string defId = JVal.Str(sd, "building", "");
                    if (tile <= 0 || string.IsNullOrEmpty(defId)) continue;
                    slots.Add(new BoardLayoutSlot
                    {
                        Tile = tile,
                        DefId = defId,
                        Star = Math.Max(JVal.Int(sd, "star", 1), 1),
                    });
                }
            }
            slots.Sort((a, b) => Arena.OrderOf(a.Tile).CompareTo(Arena.OrderOf(b.Tile)));

            // 布局卡是开局建筑的真源：清掉 PlanningMatch 按 plot 生成的预设，按实际格子重建。
            Match.Buildings.Clear();
            _plotTile.Clear();
            _plotBuilding.Clear();
            _byTile.Clear();

            int plot = 0;
            foreach (BoardLayoutSlot slot in slots)
            {
                if (Arena.Tile(slot.Tile) == null && slot.Tile != Arena.KeepTile) continue;
                if (_byTile.ContainsKey(slot.Tile)) continue;
                var pb = new PlanBuilding
                {
                    Plot = plot,
                    DefId = slot.DefId,
                    MergedBuildings = Math.Min(Math.Max(slot.Star, 1), Cfg.MaxStar),
                };
                Match.Buildings.Add(pb);
                var bb = new BoardBuilding
                {
                    Tile = slot.Tile,
                    DefId = slot.DefId,
                    Star = pb.Star,
                    Source = "layout",
                };
                _plotTile[plot] = slot.Tile;
                _plotBuilding[plot] = pb;
                _byTile[slot.Tile] = bb;
                _log.Add($"layout:{slot.DefId}@{slot.Tile}★{bb.Star}");
                plot += 1;
            }
        }

        // =================================================================
        // 查询
        // =================================================================
        public IReadOnlyCollection<BoardBuilding> Buildings => _byTile.Values;

        public BoardBuilding BuildingAt(int tile)
        {
            return _byTile.TryGetValue(tile, out BoardBuilding b) ? b : null;
        }

        public HashSet<int> OccupiedTiles()
        {
            return new HashSet<int>(_byTile.Keys);
        }

        /// <summary>下一个必须填的格子（列优先、行优先）；0 = 棋盘满了。</summary>
        public int NextFillTile() => Arena.NextFillTile(_byTile.Keys);

        /// <summary>
        /// 规则钩子：默认 false = 只能按列顺序落子；
        /// 遗物/策略牌把 <see cref="AllowFreePlacement"/> 置真即可自由选格。
        /// </summary>
        public bool CanPlaceAt(int tile)
        {
            if (!Arena.IsActive(tile)) return false;
            if (_byTile.ContainsKey(tile)) return false;
            if (AllowFreePlacement) return true;
            return tile == NextFillTile();
        }

        /// <summary>UI 高亮：严格模式下只有"下一个填充位"可点。</summary>
        public List<int> PlaceableTiles()
        {
            var list = new List<int>();
            if (AllowFreePlacement)
            {
                list.AddRange(Arena.EmptyTiles(_byTile.Keys));
                list.Sort((a, b) => Arena.OrderOf(a).CompareTo(Arena.OrderOf(b)));
                return list;
            }
            int next = NextFillTile();
            if (next > 0) list.Add(next);
            return list;
        }

        public List<int> EmptyTiles() => Arena.EmptyTiles(_byTile.Keys);

        // =================================================================
        // 规划操作
        // =================================================================
        public void BeginPlanning()
        {
            Match.BeginPlanning();
            LastEconomyCp = MechanicBus.CollectCp(Cfg, new List<BoardBuilding>(_byTile.Values));
            if (LastEconomyCp > 0) Match.AddCp(LastEconomyCp);
            _log.Add($"planning:{Match.PlanningIndex}:eco+{LastEconomyCp}");
        }

        /// <summary>
        /// 打建造牌。tile=0 表示自动挑下一个顺次填充位。
        /// 返回实际落位的格子（0 = 失败，原因写日志）。
        /// </summary>
        public int PlaceBuild(string cardId, int tile = 0)
        {
            if (!Cfg.Cards.TryGetValue(cardId, out CardDef card) || card.Kind != CardKind.Build)
            {
                _log.Add($"build:{cardId}=not_build");
                return 0;
            }
            int target = tile > 0 ? tile : NextFillTile();
            if (target <= 0) { _log.Add($"build:{cardId}=full"); return 0; }
            if (!CanPlaceAt(target))
            {
                _log.Add($"build:{cardId}@{target}=blocked(need={NextFillTile()})");
                return 0;
            }
            if (Match.Cp < card.CostCp) { _log.Add($"build:{cardId}=no_cp"); return 0; }

            int plot = Match.FirstFreePlot();
            if (plot < 0) { _log.Add($"build:{cardId}=no_plot"); return 0; }
            if (!Match.PlayBuild(cardId, plot)) { _log.Add($"build:{cardId}=match_reject"); return 0; }

            var bb = new BoardBuilding
            {
                Tile = target,
                DefId = card.Building,
                Star = 1,
                Source = "build",
            };
            _byTile[target] = bb;
            _plotTile[plot] = target;
            _plotBuilding[plot] = Match.BuildingAt(plot);
            _log.Add($"build:{card.Building}@{target}(plot{plot})");
            Emit("placed", target, card.Building, 1);
            return target;
        }

        /// <summary>
        /// 3 合 1：把 sourceTile 上的同名建筑拖到 targetTile。
        /// 目标格保留，来源格空出（成为下一个优先填充位）；返回新星级（0 = 失败）。
        /// </summary>
        public int Merge(int targetTile, int sourceTile)
        {
            if (targetTile == sourceTile) return 0;
            BoardBuilding target = BuildingAt(targetTile);
            BoardBuilding source = BuildingAt(sourceTile);
            if (target == null || source == null) return 0;
            if (target.DefId != source.DefId) return 0;
            if (string.Equals(target.DefId, "keep", StringComparison.Ordinal)) return 0;

            int targetPlot = PlotOfTile(targetTile);
            int sourcePlot = PlotOfTile(sourceTile);
            if (targetPlot < 0 || sourcePlot < 0) return 0;
            if (!Match.Merge(targetPlot, sourcePlot)) return 0;

            PlanBuilding merged = _plotBuilding[targetPlot];
            target.Star = merged.Star;
            _byTile.Remove(sourceTile);
            _plotTile.Remove(sourcePlot);
            _plotBuilding.Remove(sourcePlot);
            _log.Add($"merge:{target.DefId}@{targetTile}={target.Star}★(-{sourceTile})");
            Emit("upgraded", targetTile, target.DefId, target.Star);
            return target.Star;
        }

        /// <summary>
        /// 拆除/铲除：把格子清空（默认不返还 CP）。
        /// 空出来的格子会自然成为 <see cref="NextFillTile"/> 的首选（列优先），防止满格死锁。
        /// </summary>
        public bool Demolish(int tile)
        {
            BoardBuilding b = BuildingAt(tile);
            if (b == null) return false;
            if (string.Equals(b.DefId, "keep", StringComparison.Ordinal)) return false;
            int plot = PlotOfTile(tile);
            if (plot >= 0)
            {
                Match.RemoveBuilding(plot);
                _plotTile.Remove(plot);
                _plotBuilding.Remove(plot);
            }
            _byTile.Remove(tile);
            _log.Add($"demolish:{b.DefId}@{tile}");
            return true;
        }

        /// <summary>两格互换（需要 AllowSwap 钩子；默认禁止）。</summary>
        public bool Swap(int tileA, int tileB)
        {
            if (!AllowSwap || tileA == tileB) return false;
            BoardBuilding a = BuildingAt(tileA);
            BoardBuilding b = BuildingAt(tileB);
            if (a == null || b == null) return false;

            int pa = PlotOfTile(tileA);
            int pb = PlotOfTile(tileB);
            _byTile[tileA] = b;
            _byTile[tileB] = a;
            if (pa >= 0 && pb >= 0)
            {
                _plotTile[pa] = tileB;
                _plotTile[pb] = tileA;
            }
            _log.Add($"swap:{a.DefId}@{tileA}<->{b.DefId}@{tileB}");
            return true;
        }

        public bool PlayStrategy(string cardId) => Match.PlayStrategy(cardId);

        public int PlayTrain(string cardId, List<PlannedSquad> produced = null)
        {
            var list = produced ?? new List<PlannedSquad>();
            int n = Match.PlayTrainOut(cardId, list, true);
            for (int i = 0; i < list.Count; i++)
            {
                int plot = list[i].SourcePlot;
                list[i].SourceTile = _plotTile.TryGetValue(plot, out int tile) ? tile : 0;
            }
            if (n > 0) _log.Add($"train:{cardId}->{n}");
            return n;
        }

        public void EndPlanning()
        {
            Match.EndPlanning();
            _log.Add("planning:end");
        }

        private int PlotOfTile(int tile)
        {
            foreach (var kv in _plotTile)
            {
                if (kv.Value == tile) return kv.Key;
            }
            return -1;
        }

        // =================================================================
        // 产出 ArmyPlan
        // =================================================================
        public ArmyPlan BuildArmyPlan()
        {
            var plan = new ArmyPlan { Label = $"plan{Match.PlanningIndex}" };
            for (int i = 0; i < Match.Army.Count; i++)
            {
                PlannedSquad sq = Match.Army[i];
                int tile = sq.SourceTile;
                if (tile <= 0) tile = _plotTile.TryGetValue(sq.SourcePlot, out int t) ? t : 0;
                plan.Units.Add(new ArmyUnit
                {
                    UnitId = sq.UnitId,
                    Star = Math.Max(sq.Star, 1),
                    Count = Math.Max(sq.Units, 1),
                    SourceBuilding = sq.SourceBuilding,
                    SourceTile = tile,
                });
            }

            // 防御建筑 → 实体塔（不进 Units，不贡献 base_damage）
            foreach (BoardBuilding b in _byTile.Values)
            {
                if (!Cfg.Buildings.TryGetValue(b.DefId, out BuildingDef def)) continue;
                if (def.Kind != BuildingKinds.Defense || def.Defense == null) continue;
                plan.Towers.Add(new ArmyUnit
                {
                    UnitId = def.Defense.Unit,
                    Star = b.Star,
                    Count = Math.Max(def.Defense.CountPerBuilding, 1),
                    SourceBuilding = def.Id,
                    SourceTile = b.Tile,
                });
            }

            MechanicBus.ApplyPlanningEnd(Cfg, Arena, new List<BoardBuilding>(_byTile.Values), plan.Modifiers);
            return plan;
        }

        public string DebugLine()
        {
            var sb = new System.Text.StringBuilder();
            sb.Append($"plan{Match.PlanningIndex} cp={Match.Cp}/{Cfg.CpCap} pop={Match.PopUsed()}/{Match.PopCap()} ");
            sb.Append($"buildings={_byTile.Count} army={Match.Army.Count} next={NextFillTile()}");
            return sb.ToString();
        }
    }
}
