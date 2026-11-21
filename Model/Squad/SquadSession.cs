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
        public int PlanningIndex;
        public int Cp;
        public int CpStart;
        public int PopUsed;
        public int PopCap;
        public int PopBlocked;
        public int ArmySquads;
        public int ArmyModels;
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
    ///   · 推演（--simulate）用"先规划、开打前统一落地"，试玩用"打牌即落地"，
    ///     两条路共用同一份 CP/人口结算，不写第二份规则。
    /// </summary>
    public sealed class SquadSession
    {
        public readonly SquadArena Arena;
        public readonly PlanningMatch Match;
        public readonly SquadBattle Battle;
        public readonly bool InstantTrain;

        private readonly Dictionary<int, int> _plotTile = new Dictionary<int, int>();
        private readonly Dictionary<string, List<int>> _tilesByBuilding = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        private readonly Dictionary<string, int> _tileCursor = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly HashSet<int> _usedTiles = new HashSet<int>();
        private readonly List<string> _log = new List<string>();
        private bool _executing;
        private bool _armySpawned;

        public SquadSession(
            UnitCatalog units,
            CombatRules rules,
            PlanningConfig planning,
            SquadArena arena,
            int seed,
            bool instantTrain,
            double playerBaseHp = -1.0,
            double enemyBaseHp = -1.0)
        {
            Arena = arena ?? throw new ArgumentNullException(nameof(arena));
            InstantTrain = instantTrain;
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

        private int NextFreePlayerTile()
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

        // =================================================================
        // 规划
        // =================================================================
        public void BeginPlanning()
        {
            _executing = false;
            _armySpawned = false;
            Match.BeginPlanning();
            _log.Add($"planning:{Match.PlanningIndex}");
        }

        /// <summary>打一张训练牌。即时模式：产出的每一队立刻落到对应建筑的格子中心。</summary>
        public int PlayTrainCard(string cardId)
        {
            if (_executing) return 0;
            var produced = new List<PlannedSquad>();
            int n = Match.PlayTrainOut(cardId, produced, !InstantTrain);
            if (InstantTrain && n > 0)
            {
                for (int i = 0; i < produced.Count; i++) SpawnPlanned(produced[i], i);
            }
            _log.Add($"train:{cardId}->{n}");
            return n;
        }

        /// <summary>打一张建造牌；新建筑占用下一块空的玩家建造格（出兵锚点随之落位）。</summary>
        public bool PlayBuildCard(string cardId)
        {
            if (_executing) return false;
            int plot = Match.FirstFreePlot();
            if (plot < 0) return false;
            if (!Match.PlayBuild(cardId, plot)) return false;

            PlanBuilding b = Match.BuildingAt(plot);
            if (b == null) return false;
            int tile = NextFreePlayerTile();
            if (tile <= 0)
            {
                _log.Add($"build:{b.DefId}@{plot}=no_tile");
                return true;
            }
            _plotTile[plot] = tile;
            _usedTiles.Add(tile);
            if (!_tilesByBuilding.TryGetValue(b.DefId, out List<int> list))
            {
                list = new List<int>();
                _tilesByBuilding[b.DefId] = list;
            }
            list.Add(tile);
            list.Sort();
            _log.Add($"build:{b.DefId}@{plot}->tile{tile}");
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

        public void BeginExecution(int roundIndex = 0)
        {
            if (_executing) return;
            _executing = true;
            // 策略牌只影响本轮：把加成一次性灌给战场（即时模式下也要刷新已落地的队）
            Battle.SetModifiers(Match.Mods, null);
            Battle.RefreshModifiers();
            if (roundIndex >= 0 && roundIndex < Arena.Rounds.Count)
            {
                LevelRound round = Arena.Rounds[roundIndex];
                for (int wi = 0; wi < round.Waves.Count; wi++)
                {
                    Battle.ScheduleWave(round.Waves[wi], 1, Arena.EnemyBarracksTile);
                }
                _log.Add($"execution:begin:{round.Kind}");
            }
            else
            {
                _log.Add("execution:begin");
            }
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
            int id = Battle.AddSquadAtTile(0, sq.UnitId, sq.Star, tile, sq.SourceBuilding, ordinal);
            _log.Add($"spawn:{sq.UnitId}★{sq.Star}@tile{tile}#{id}#{ordinal}");
        }

        // =================================================================
        // 快照
        // =================================================================
        public SquadSessionState State()
        {
            var state = new SquadSessionState
            {
                Phase = _executing ? "executing" : "planning",
                PlanningIndex = Match.PlanningIndex,
                Cp = Match.Cp,
                CpStart = Match.CpAtStart,
                PopUsed = Match.PopUsed(),
                PopCap = Match.PopCap(),
                PopBlocked = Match.PopBlocked,
                ArmySquads = Match.Army.Count,
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
