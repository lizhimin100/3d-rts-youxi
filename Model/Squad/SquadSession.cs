using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>训练牌一行（给 UI 画卡 + 可用性原因）。</summary>
    public sealed class SquadTrainEntry
    {
        public string CardId = "";
        public string DisplayName = "";
        public string UnitId = "";
        public string UnitName = "";
        public string Tag = "";
        /// <summary>attack / defend / ""（不限时空）。</summary>
        public string Role = SquadRoles.Any;
        public int CostCp;
        public int SquadSize;
        public string Formation = "";
        public double SquadRadius;
        public int Buildings;
        public bool InHand;
        public bool Available;
        public string Reason = "ok";
    }

    /// <summary>规划/执行阶段的小队会话快照。</summary>
    public sealed class SquadSessionState
    {
        public string Phase = "planning";
        /// <summary>"" = 还没开打；attack / defend = 当前时空；done = 本轮结束。</summary>
        public string RoundKind = "";
        public int PlanningIndex;
        public int Cp;
        public int CpStart;
        public int PopUsed;
        public int PopCap;
        public int PopBlocked;
        public int ArmySquads;
        public int ArmyModels;
        public int AttackSquads;
        public int DefendSquads;
        public bool OutpostCaptured;
        public bool OutpostAvailable;
        public int OutpostCpCost;
        public readonly List<string> Hand = new List<string>();
        public readonly List<SquadTrainEntry> TrainCards = new List<SquadTrainEntry>();
        public readonly List<string> Log = new List<string>();
    }

    /// <summary>
    /// 一局小队战斗的"规划 + 执行"会话。
    ///
    /// 为什么要有这一层：
    ///   · 训练牌是**规划规则**（CP/人口/建筑 Tag/星级），必须走 <see cref="PlanningMatch"/> 唯一实现；
    ///   · 小队要**立刻**落在对应建筑所在格子的 SquadSpawnAnchor（格子正中心）——
    ///     `PlanningMatch.PlayTrainOut` 会告诉我们是哪座建筑产的队，这里只负责查格子锚点；
    ///   · 建造牌要落在**玩家点的那一格**（左上角建筑位），所以这里是"格子 ↔ 规划块"的唯一映射点；
    ///   · 攻防时空流转（2026-11-22）：进攻小队只打进攻战、防守小队只打防守战，
    ///     切换时空时把另一批队伍整批抹掉（PurgeSide），建筑与据点跨轮保留；
    ///   · 推演（--simulate）用"先规划、开打前统一落地"，试玩用"打牌即落地"，
    ///     两条路共用同一份 CP/人口结算，不写第二份规则。
    /// </summary>
    public sealed class SquadSession
    {
        public readonly SquadArena Arena;
        public readonly PlanningMatch Match;
        public readonly SquadBattle Battle;
        public readonly bool InstantTrain;
        public readonly SquadTuning Tuning;

        private readonly Dictionary<int, int> _plotTile = new Dictionary<int, int>();
        private readonly Dictionary<string, List<int>> _tilesByBuilding = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        private readonly Dictionary<string, int> _tileCursor = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly HashSet<int> _usedTiles = new HashSet<int>();
        private readonly List<string> _log = new List<string>();
        private bool _executing;
        private bool _armySpawned;
        private int _attackSquads;
        private int _defendSquads;

        public SquadSession(
            UnitCatalog units,
            CombatRules rules,
            PlanningConfig planning,
            SquadArena arena,
            int seed,
            bool instantTrain,
            double playerBaseHp = -1.0,
            double enemyBaseHp = -1.0,
            IDictionary<string, object> tuning = null)
        {
            Arena = arena ?? throw new ArgumentNullException(nameof(arena));
            InstantTrain = instantTrain;
            Tuning = SquadTuning.FromDict(tuning);
            Match = new PlanningMatch(planning, units, seed);
            Battle = new SquadBattle(units, rules, arena, planning, seed ^ 0x5F3759DF);
            if (playerBaseHp >= 0.0)
            {
                Battle.SetBaseHp(playerBaseHp, enemyBaseHp >= 0.0 ? enemyBaseHp : arena.EnemyBaseHp);
            }
            MapStartBuildings();
        }

        public bool Executing => _executing;
        public IReadOnlyList<string> Log => _log;
        /// <summary>"" = 规划中；attack / defend = 当前时空；done = 本轮已结算。</summary>
        public string RoundKind { get; private set; } = "";
        public bool OutpostCaptured { get; private set; }
        public int OutpostCpCost => Tuning.OutpostCpCost;
        public bool OutpostAvailable => Tuning.OutpostEnabled && Arena.NeutralOutpostTile > 0;

        private void MapStartBuildings()
        {
            var byDef = new Dictionary<string, List<int>>(StringComparer.Ordinal);
            var tiles = new List<int>();
            for (int i = 0; i < Arena.PlayerBuildings.Count; i++)
            {
                ArenaBuilding b = Arena.PlayerBuildings[i];
                if (b.Tile <= 0) continue;
                tiles.Add(b.Tile);
                if (!byDef.TryGetValue(b.DefId, out List<int> list))
                {
                    list = new List<int>();
                    byDef[b.DefId] = list;
                }
                list.Add(b.Tile);
                _usedTiles.Add(b.Tile);
            }
            foreach (var kv in byDef)
            {
                kv.Value.Sort();
                _tilesByBuilding[kv.Key] = kv.Value;
            }
            tiles.Sort();

            var buildings = new List<PlanBuilding>(Match.Buildings);
            buildings.Sort((a, b) => a.Plot.CompareTo(b.Plot));
            foreach (PlanBuilding b in buildings)
            {
                int tile = TakeTile(b.DefId);
                if (tile <= 0 && tiles.Count > 0)
                {
                    for (int i = 0; i < tiles.Count; i++)
                    {
                        if (!_usedTiles.Contains(tiles[i]))
                        {
                            tile = tiles[i];
                            _usedTiles.Add(tile);
                            break;
                        }
                    }
                }
                if (tile > 0) _plotTile[b.Plot] = tile;
            }
        }

        private int TakeTile(string defId)
        {
            if (string.IsNullOrEmpty(defId)) return 0;
            if (!_tilesByBuilding.TryGetValue(defId, out List<int> list) || list.Count == 0) return 0;
            _tileCursor.TryGetValue(defId, out int cursor);
            int idx = ((cursor % list.Count) + list.Count) % list.Count;
            _tileCursor[defId] = (idx + 1) % list.Count;
            return list[idx];
        }

        /// <summary>下一块空的玩家建造格（不含主堡格、不含据点格）。</summary>
        public int NextFreePlayerTile()
        {
            var candidates = new List<int>();
            for (int i = 0; i < Arena.Tiles.Count; i++)
            {
                TacticalTile t = Arena.Tiles[i];
                if (t.Side != RegionKinds.Player || t.Role == "keep") continue;
                if (_usedTiles.Contains(t.Index)) continue;
                candidates.Add(t.Index);
            }
            candidates.Sort();
            return candidates.Count > 0 ? candidates[0] : 0;
        }

        /// <summary>玩家还能把建筑放在哪些格子（HUD 高亮 + 自检用）。</summary>
        public List<int> FreePlayerTiles()
        {
            var outTiles = new List<int>();
            for (int i = 0; i < Arena.Tiles.Count; i++)
            {
                TacticalTile t = Arena.Tiles[i];
                if (t.Side != RegionKinds.Player || t.Role == "keep") continue;
                if (_usedTiles.Contains(t.Index)) continue;
                outTiles.Add(t.Index);
            }
            outTiles.Sort();
            return outTiles;
        }

        // =================================================================
        // 规划
        // =================================================================
        public void BeginPlanning()
        {
            _executing = false;
            _armySpawned = false;
            RoundKind = "";
            Match.BeginPlanning();
            _log.Add($"planning:{Match.PlanningIndex}");
        }

        /// <summary>打一张训练牌。即时模式：产出的每一队立刻落到对应建筑的格子中心。</summary>
        public int PlayTrainCard(string cardId)
        {
            if (_executing) return 0;
            var produced = new List<PlannedSquad>();
            int n = Match.PlayTrainOut(cardId, produced, !InstantTrain);
            if (n > 0)
            {
                for (int i = 0; i < produced.Count; i++)
                {
                    if (produced[i].Role == SquadRoles.Attack) _attackSquads += 1;
                    else if (produced[i].Role == SquadRoles.Defend) _defendSquads += 1;
                }
            }
            if (InstantTrain && n > 0)
            {
                for (int i = 0; i < produced.Count; i++) SpawnPlanned(produced[i], i);
            }
            _log.Add($"train:{cardId}->{n}");
            return n;
        }

        /// <summary>
        /// 打一张建造牌，并**落到玩家点的那一格**（tileIndex=0 = 自动挑第一块空格）。
        /// 建筑位是格子的左上角（TacticalTile.BuildingAnchorWorld），出兵位是正中心。
        /// </summary>
        public bool PlayBuildCardAt(string cardId, int tileIndex)
        {
            if (_executing) return false;
            if (!Match.Cfg.Cards.TryGetValue(cardId, out CardDef card) || card.Kind != CardKind.Build) return false;
            if (tileIndex > 0)
            {
                TacticalTile t = Arena.Tile(tileIndex);
                if (t == null || t.Side != RegionKinds.Player || t.Role == "keep") return false;
                if (Arena.PlayerTileOccupied(tileIndex)) return false;
                if (_usedTiles.Contains(tileIndex)) return false;
            }
            int plot = Match.FirstFreePlot();
            if (plot < 0) return false;
            if (!Match.PlayBuild(cardId, plot)) return false;

            int tile = tileIndex > 0 ? tileIndex : NextFreePlayerTile();
            if (tile <= 0)
            {
                _log.Add($"build:{card.Building}@{plot}=no_tile");
                return true;
            }
            Arena.AddPlayerBuilding(tile, card.Building, 1);
            _plotTile[plot] = tile;
            _usedTiles.Add(tile);
            if (!_tilesByBuilding.TryGetValue(card.Building, out List<int> list))
            {
                list = new List<int>();
                _tilesByBuilding[card.Building] = list;
            }
            list.Add(tile);
            list.Sort();
            _log.Add($"build:{card.Building}@{plot}->tile{tile}");
            return true;
        }

        /// <summary>兼容旧调用：不指定格子（自动挑第一块空的玩家格）。</summary>
        public bool PlayBuildCard(string cardId) => PlayBuildCardAt(cardId, 0);

        /// <summary>
        /// 买下中立据点（规划期动作）：进攻小队下一场从**中立区靠敌侧**出发。
        /// 花的是 CP，走 PlanningMatch 的同一份结算，不另开钱包。
        /// </summary>
        public bool CaptureOutpost()
        {
            if (_executing || OutpostCaptured || !OutpostAvailable) return false;
            int cost = Math.Max(Tuning.OutpostCpCost, 0);
            if (Match.Cp < cost) return false;
            if (!Match.SpendCp(cost)) return false;
            OutpostCaptured = true;
            _log.Add($"outpost:captured(-{cost}cp)");
            return true;
        }

        /// <summary>
        /// 收规划：推演模式下把 <see cref="PlanningMatch.Army"/> 统一落到各自建筑的出兵锚点。
        /// 试玩模式（instantTrain）已经落地过了，这里只做收牌。
        /// </summary>
        public void EndPlanning(bool spawnArmy = true)
        {
            // 策略牌只影响本轮：必须在"统一落地"之前灌进去，否则新兵读到的还是默认加成。
            Battle.SetModifiers(Match.Mods, null);
            if (!InstantTrain && spawnArmy && !_armySpawned)
            {
                for (int i = 0; i < Match.Army.Count; i++) SpawnPlanned(Match.Army[i], i);
                _armySpawned = true;
            }
            Match.EndPlanning();
            _log.Add("planning:end");
        }

        // =================================================================
        // 执行：进攻战 → 防守战 → 结算
        // =================================================================

        /// <summary>
        /// 进入**进攻战**（60 秒）：只激活进攻小队；已占领据点则先前压到中立区靠敌侧。
        /// 敌方波次按 attack 轮排。
        /// </summary>
        public void BeginAttack()
        {
            if (_executing) return;
            _executing = true;
            RoundKind = SquadRoles.Attack;
            Battle.SetModifiers(Match.Mods, null);
            Battle.RefreshModifiers();
            Battle.SetActiveRole(SquadRoles.Attack);

            // 进攻前压：买了据点 → 中立区靠敌侧；没买 → 玩家区前缘。
            var attackStage = Arena.AttackStageWorld(OutpostCaptured);
            int staged = Battle.StageSide(0, SquadRoles.Attack, attackStage.X, attackStage.Y);
            _log.Add($"attack:stage{(OutpostCaptured ? "_outpost" : "_front")}:{staged}");
            ScheduleRound("attack", 0.0);
            PushForward(SquadRoles.Attack);
            _log.Add("execution:begin:attack");
        }

        /// <summary>
        /// 进入**防守战**（60 秒）：清掉进攻时空的残兵，激活防守小队 + 据点免费防守队。
        /// </summary>
        public void BeginDefend()
        {
            if (RoundKind == SquadRoles.Defend) return;
            if (!_executing) BeginAttack();
            double offset = Battle.Time;

            // 轮末清场：上一场的部队（双方）全部离场，基地血量/建筑/据点保留。
            Battle.PurgeSide(0, SquadRoles.Attack);
            Battle.PurgeSide(1, null);

            RoundKind = SquadRoles.Defend;
            Battle.SetActiveRole(SquadRoles.Defend);
            SpawnFreeDefenders();

            if (OutpostCaptured)
            {
                var stage = Arena.OutpostStageWorld();
                int moved = Battle.StageSide(0, SquadRoles.Defend, stage.X, stage.Y);
                if (moved > 0) _log.Add($"defend:stage_outpost:{moved}");
            }
            ScheduleRound("defend", offset);
            PushForward(SquadRoles.Defend);
            _log.Add("execution:begin:defend");
        }

        /// <summary>本轮结算：双方部队清空（建筑与据点保留）。</summary>
        public void EndRound()
        {
            if (RoundKind == "done") return;
            Battle.PurgeSide(1, null);
            Battle.PurgeSide(0, null);
            RoundKind = "done";
            _log.Add("round:done");
        }

        /// <summary>兼容旧入口：roundIndex 0 = 进攻战，1 = 防守战。</summary>
        public void BeginExecution(int roundIndex = 0)
        {
            if (roundIndex <= 0) BeginAttack();
            else BeginDefend();
        }

        /// <summary>据点/主堡免费防守小队：防守战开场白送一支（不占 CP / 人口）。</summary>
        private void SpawnFreeDefenders()
        {
            if (!Tuning.FreeDefendEnabled) return;
            int tile = Arena.PlayerBaseTile;
            if (tile <= 0) return;
            int id = Battle.AddSquadAtTileRole(0, Tuning.FreeDefendUnit, Tuning.FreeDefendStar,
                tile, "keep", 0, SquadRoles.Defend);
            if (id > 0) _log.Add($"free_defend:{Tuning.FreeDefendUnit}@tile{tile}");
        }

        private void ScheduleRound(string kind, double offset)
        {
            for (int ri = 0; ri < Arena.Rounds.Count; ri++)
            {
                LevelRound round = Arena.Rounds[ri];
                if (round.Kind != kind) continue;
                for (int wi = 0; wi < round.Waves.Count; wi++)
                {
                    Battle.ScheduleWaveAt(round.Waves[wi], 1, Arena.EnemyBarracksTile, offset);
                }
            }
        }

        /// <summary>
        /// 预设偏好（不是玩家微操）：本时空里我方该往哪走。
        ///   · 进攻：全力压向敌方基地（胜利条件就是拆家）；
        ///   · 防守：前出到玩家区前缘迎战，不追进敌区。
        /// </summary>
        private void PushForward(string role)
        {
            var ids = new List<int>(Battle.SquadIdsOfSideAndRole(0, role));
            if (ids.Count == 0) return;
            double x;
            if (role == SquadRoles.Attack)
            {
                var target = Arena.LaneToWorld(Arena.EnemyBaseX, 0.0);
                x = target.X;
            }
            else
            {
                x = Arena.NeutralStartWorldX - 4.0;
            }
            int n = Battle.OrderMany(ids, SquadOrders.AttackMove, x, 0.0, -1);
            _log.Add($"pref:{role}:attack_move={n}");
        }

        private void SpawnPlanned(PlannedSquad sq, int ordinal)
        {
            int tile = TakeTile(sq.SourceBuilding);
            if (tile <= 0)
            {
                // 兜底：按规划块顺序落到玩家格
                foreach (var kv in _plotTile)
                {
                    tile = kv.Value;
                    break;
                }
            }
            if (tile <= 0) tile = Arena.PlayerBarracksTile;
            int id = Battle.AddSquadAtTileRole(0, sq.UnitId, sq.Star, tile, sq.SourceBuilding, ordinal, sq.Role);
            _log.Add($"spawn:{sq.UnitId}★{sq.Star}@{tile}#{id}#{sq.Role}");
        }

        // =================================================================
        // 快照
        // =================================================================
        public SquadSessionState State()
        {
            var state = new SquadSessionState
            {
                Phase = _executing ? "executing" : "planning",
                RoundKind = RoundKind,
                PlanningIndex = Match.PlanningIndex,
                Cp = Match.Cp,
                CpStart = Match.CpAtStart,
                PopUsed = Match.PopUsed(),
                PopCap = Match.PopCap(),
                PopBlocked = Match.PopBlocked,
                ArmySquads = Match.Army.Count,
                AttackSquads = _attackSquads,
                DefendSquads = _defendSquads,
                OutpostCaptured = OutpostCaptured,
                OutpostAvailable = OutpostAvailable,
                OutpostCpCost = OutpostCpCost,
            };
            for (int i = 0; i < Match.Hand.Count; i++) state.Hand.Add(Match.Hand[i]);

            var cards = new List<CardDef>(Match.Cfg.Cards.Values);
            cards.Sort((a, b) => string.CompareOrdinal(a.Id, b.Id));
            foreach (CardDef card in cards)
            {
                if (card.Kind != CardKind.Train) continue;
                UnitDef def = Match.Units.Get(card.Unit);
                int buildings = Match.CountTag(card.Tag);
                bool inHand = Match.Hand.Contains(card.Id);
                bool available = Match.CanPlayTrain(card.Id);
                string reason = "ok";
                if (!inHand) reason = "not_in_hand";
                else if (Match.Cp < card.CostCp) reason = "no_cp";
                else if (buildings <= 0) reason = "no_building";
                else if (def != null && Match.PopFree() < def.PopCost) reason = "no_pop";

                state.TrainCards.Add(new SquadTrainEntry
                {
                    CardId = card.Id,
                    DisplayName = card.DisplayName,
                    UnitId = card.Unit,
                    UnitName = def != null ? def.DisplayName : card.Unit,
                    Tag = card.Tag,
                    Role = card.Role,
                    CostCp = card.CostCp,
                    SquadSize = def != null ? def.SquadSize : 0,
                    Formation = def != null ? def.Formation : "",
                    SquadRadius = def != null ? def.SquadRadius : 0.0,
                    Buildings = buildings,
                    InHand = inHand,
                    Available = available,
                    Reason = reason,
                });
            }
            state.Log.AddRange(_log);
            return state;
        }

        public int PlayerTileOfPlot(int plot)
        {
            return _plotTile.TryGetValue(plot, out int tile) ? tile : 0;
        }
    }
}
