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
        /// <summary>2026-11-24 起恒为空（攻防轮已取消，字段只留给桥契约）。</summary>
        public string Role = "";
        public int CostCp;
        /// <summary>这张牌现在打出去会产几名单兵（已含本回合「加快训练」倍率与 per_building 建筑数）。</summary>
        public int Units;
        public int Buildings;
        public bool InHand;
        public bool Available;
        public string Reason = "ok";
    }

    /// <summary>规划/执行阶段的会话快照。</summary>
    public sealed class SquadSessionState
    {
        public string Phase = "planning";
        /// <summary>"" = 还没开打；attack / defend = 当前是第几场（UI 两段式展示）；done = 本轮结束。</summary>
        public string RoundKind = "";
        public int PlanningIndex;
        public int Cp;
        public int CpStart;
        public int CpCap;
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
        public double TrainCountMult = 1.0;
        public int DrawPile;
        public int DiscardPile;
        public int HandCount;
        /// <summary>本局已打过的轮数 / 当前轮次（单轮死斗）。</summary>
        public int RoundsPlayed;
        public string Outcome = "";
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        /// <summary>战败简报（只有战败非空）。</summary>
        public string DefeatRecord = "";
        public readonly List<string> Hand = new List<string>();
        public readonly List<SquadTrainEntry> TrainCards = new List<SquadTrainEntry>();
        public readonly List<string> Log = new List<string>();
    }

    /// <summary>
    /// 一局战役的"规划 + 单场战斗"会话（UI 的唯一入口）。
    ///
    /// 2026-11-24 起规则全部下沉：
    ///   · 规划/建造/升星 → <see cref="BoardSession"/>（竖列顺序、3 合 1、光环/经济）；
    ///   · 单场 60 秒死斗 → <see cref="BattleSession"/> / <see cref="SquadBattle"/>；
    ///   · 幸存 base_damage 结算 → <see cref="RoundResolver"/>。
    ///
    /// 这个类只做三件事：把 UI 的调用翻译成上面三层的调用、保持旧方法名、维护
    /// "每轮开场清场 + 从 ArmyPlan 重新落地"的会话状态。它**不写任何战斗/规划公式**。
    /// </summary>
    public sealed class SquadSession
    {
        public readonly SquadArena Arena;
        public readonly BoardSession Board;
        /// <summary>当前这一场的战斗内核（每轮新建，避免 finished/time/stats 跨轮残留）。</summary>
        public SquadBattle Battle { get; private set; }
        public readonly bool InstantTrain;
        public readonly SquadTuning Tuning;

        private readonly UnitCatalog _units;
        private readonly CombatRules _rules;
        private readonly PlanningConfig _planning;
        private readonly int _seed;
        private readonly double _playerHpMax;
        private readonly double _enemyHpMax;

        public PlanningMatch Match => Board.Match;

        private readonly List<string> _log = new List<string>();
        private readonly List<RoundResult> _roundResults = new List<RoundResult>();
        private ArmyPlan _plan = new ArmyPlan();
        private double _playerHp;
        private double _enemyHp;
        private bool _executing;
        private bool _settled = true;
        private int _roundIndex = -1;
        private string _outcome = "";

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

            var notes = new List<string>();
            Board = BoardSession.Create(planning, units, arena.ShellDict, arena.LayoutDict, seed, notes);
            _log.AddRange(notes);

            _units = units;
            _rules = rules;
            _planning = planning;
            _seed = seed;
            _playerHp = playerBaseHp >= 0.0 ? playerBaseHp : arena.PlayerBaseHp;
            _enemyHp = enemyBaseHp >= 0.0 ? enemyBaseHp : arena.EnemyBaseHp;
            _playerHpMax = Math.Max(_playerHp, arena.Level != null ? arena.Level.PlayerBaseHp : _playerHp);
            _enemyHpMax = Math.Max(_enemyHp, arena.Level != null ? arena.Level.EnemyBaseHp : _enemyHp);

            Battle = new SquadBattle(units, rules, arena, planning, seed ^ 0x5F3759DF, Tuning);
            Battle.SetBaseHp(_playerHp, _enemyHp, _playerHpMax, _enemyHpMax);
            SyncArenaBuildings();
        }

        public bool Executing => _executing;
        public IReadOnlyList<string> Log => _log;
        /// <summary>"" = 规划中；attack / defend = 当前场次；done = 本轮已结算。</summary>
        public string RoundKind { get; private set; } = "";
        public bool OutpostCaptured => false;
        public int OutpostCpCost => 0;
        public bool OutpostAvailable => false;
        public string Outcome => _outcome;
        public IReadOnlyList<RoundResult> Rounds => _roundResults;
        public string DefeatRecord { get; private set; } = "";

        // =================================================================
        // 规划
        // =================================================================
        public void BeginPlanning()
        {
            _executing = false;
            _settled = true;
            RoundKind = "";
            Board.BeginPlanning();
            _plan = new ArmyPlan();
            _log.Add($"planning:{Match.PlanningIndex}:eco+{Board.LastEconomyCp}");
        }

        /// <summary>
        /// 打一张训练牌。即时模式：产出的每批立刻落到对应格子的小阵列（表现层预览）；
        /// 真正的军队在每轮开场由 ArmyPlan 统一落地。
        /// </summary>
        public int PlayTrainCard(string cardId)
        {
            if (_executing) return 0;
            var produced = new List<PlannedSquad>();
            int n = Board.PlayTrain(cardId, produced);
            if (InstantTrain && n > 0)
            {
                for (int i = 0; i < produced.Count; i++)
                {
                    PlannedSquad sq = produced[i];
                    int tile = sq.SourceTile;
                    if (tile <= 0) continue;
                    Battle.AddUnitsAtTile(0, sq.UnitId, sq.Star, tile, sq.SourceBuilding,
                        Math.Max(sq.Units, 1), 0, SquadRoles.Any);
                }
            }
            _log.Add($"train:{cardId}->{n}");
            return n;
        }

        /// <summary>
        /// 打一张建造牌。tile=0 表示按列顺序自动挑下一个填充位；
        /// 非顺序格会被 BoardSession 拒绝（AllowFreePlacement 钩子可放开）。
        /// </summary>
        public bool PlayBuildCardAt(string cardId, int tileIndex)
        {
            if (_executing) return false;
            int tile = Board.PlaceBuild(cardId, tileIndex);
            if (tile <= 0) return false;
            SyncArenaBuildings();
            _log.Add($"build:{cardId}@{tile}");
            return true;
        }

        public bool PlayBuildCard(string cardId) => PlayBuildCardAt(cardId, 0);

        /// <summary>3 合 1（拖放）：目标格保留，来源格清空。</summary>
        public int MergeBuildings(int targetTile, int sourceTile)
        {
            if (_executing) return 0;
            int star = Board.Merge(targetTile, sourceTile);
            if (star > 0) SyncArenaBuildings();
            return star;
        }

        /// <summary>拆除：空出的格子成为下一个顺次填充位。</summary>
        public bool DemolishBuilding(int tile)
        {
            if (_executing) return false;
            bool ok = Board.Demolish(tile);
            if (ok) SyncArenaBuildings();
            return ok;
        }

        public bool CaptureOutpost() => false;

        /// <summary>收规划：把 Army 固化成 ArmyPlan（军队在每轮开场统一落地）。</summary>
        public void EndPlanning(bool spawnArmy = true)
        {
            _ = spawnArmy;
            Board.EndPlanning();
            _plan = Board.BuildArmyPlan();
            Battle.SetModifiers(Match.Mods, null);
            Battle.SetArmyModifiers(_plan.Modifiers);
            _log.Add($"planning:end army={_plan.UnitCount} towers={_plan.Towers.Count}");
        }

        // =================================================================
        // 执行：单场死斗（UI 的两段 = 连续两轮）
        // =================================================================
        public void BeginAttack() => StartRound(0, "attack");

        public void BeginDefend()
        {
            if (!_executing) BeginAttack();
            if (!_settled) SettleCurrent(true);
            StartRound(Math.Max(_roundIndex + 1, 1), "defend");
        }

        public void EndRound()
        {
            if (!_settled) SettleCurrent(true);
            Battle.PurgeSide(1, null);
            Battle.PurgeSide(0, null);
            _executing = false;
            RoundKind = "done";
            _log.Add("round:done");
        }

        public void BeginExecution(int roundIndex = 0)
        {
            if (roundIndex <= 0) BeginAttack();
            else BeginDefend();
        }

        private void StartRound(int index, string kind)
        {
            _executing = true;
            _settled = false;
            _roundIndex = index;
            RoundKind = kind;

            // 每轮开场：新建一份战斗内核（不继承上一场的 finished/time/stats），
            // 棋盘建筑与基地血保留；部队由 ArmyPlan 重新落地。
            Battle = new SquadBattle(_units, _rules, Arena, _planning, _seed ^ (0x5F3759DF + index * 7919), Tuning);
            _plan = Board.BuildArmyPlan();
            Battle.SetModifiers(Match.Mods, null);
            Battle.SetArmyModifiers(_plan.Modifiers);
            Battle.SetBaseHp(_playerHp, _enemyHp, _playerHpMax, _enemyHpMax);

            LevelDef level = Arena.Level ?? new LevelDef();
            BattleSession.SpawnArmy(Battle, _plan, level, Tuning, Arena);
            LevelRound round = level.Rounds.Count > 0
                ? level.Rounds[Math.Min(index, level.Rounds.Count - 1)]
                : new LevelRound { Label = $"第 {index + 1} 轮" };
            BattleSession.ScheduleEnemyWaves(Battle, round, level, Arena);

            _log.Add($"round:begin{index + 1}:{kind}:army={_plan.UnitCount}:towers={_plan.Towers.Count}");
        }

        private void SettleCurrent(bool timeUp)
        {
            if (_settled) return;
            LevelDef level = Arena.Level ?? new LevelDef();
            LevelRound round = level.Rounds.Count > 0
                ? level.Rounds[Math.Min(Math.Max(_roundIndex, 0), level.Rounds.Count - 1)]
                : new LevelRound { Label = $"第 {_roundIndex + 1} 轮" };
            bool up = timeUp && Battle.Time >= level.RoundSeconds - 0.06;
            RoundResult rr = RoundResolver.Settle(Math.Max(_roundIndex, 0), round.Label, Battle, Tuning,
                _playerHp, _enemyHp, up);
            _roundResults.Add(rr);
            _playerHp = rr.PlayerBaseHpAfter;
            _enemyHp = rr.EnemyBaseHpAfter;
            Battle.SetBaseHp(_playerHp, _enemyHp, _playerHpMax, _enemyHpMax);
            Battle.Finish(up ? "time" : "wipe");
            _settled = true;
            _log.Add($"round:settle{rr.Index + 1}:{rr.PlayerBaseDamageApplied:0.#}/{rr.EnemyBaseDamageApplied:0.#}");

            if (_playerHp <= 0.0 && _enemyHp <= 0.0) _outcome = "draw";
            else if (_enemyHp <= 0.0) _outcome = "win";
            else if (_playerHp <= 0.0) _outcome = "lose";
            if (_outcome == "lose")
                DefeatRecord = BuildDefeatRecord(rr);
        }

        private static string BuildDefeatRecord(RoundResult rr)
        {
            var killers = new List<string>();
            if (rr.Stats != null)
            {
                var rows = new List<KeyValuePair<string, int>>();
                foreach (var kv in rr.Stats.EnemyByUnit)
                    if (kv.Value.Kills > 0) rows.Add(new KeyValuePair<string, int>(kv.Key, kv.Value.Kills));
                rows.Sort((a, b) => b.Value.CompareTo(a.Value));
                for (int i = 0; i < rows.Count && i < 3; i++) killers.Add($"{rows[i].Key}（{rows[i].Value} 杀）");
            }
            string fatal = rr.EnemyFatalUnits.Count > 0 ? string.Join("、", rr.EnemyFatalUnits) : "（无幸存单位）";
            return $"败于第 {rr.Index + 1} 轮；敌方主力击杀：{(killers.Count > 0 ? string.Join("、", killers) : "（无）")}；" +
                   $"致命扣血：{fatal}，扣 {rr.EnemyBaseDamageApplied:0.#} 点。";
        }

        /// <summary>把棋盘建筑同步到 SquadArena（3D 表现层按 arena.player_buildings 渲染）。</summary>
        private void SyncArenaBuildings()
        {
            Arena.PlayerBuildings.Clear();
            foreach (BoardBuilding b in Board.Buildings)
            {
                Arena.PlayerBuildings.Add(new ArenaBuilding
                {
                    Tile = b.Tile,
                    Side = RegionKinds.Player,
                    DefId = b.DefId,
                    Star = b.Star,
                });
            }
            Arena.PlayerBuildings.Sort((a, b) => a.Tile.CompareTo(b.Tile));
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
                CpCap = Board.Cfg.CpCap,
                PopUsed = Match.PopUsed(),
                PopCap = Match.PopCap(),
                PopBlocked = Match.PopBlocked,
                ArmySquads = _plan != null && _plan.UnitCount > 0 ? _plan.UnitCount : ArmyCount(),
                ArmyModels = _plan != null && _plan.UnitCount > 0 ? _plan.UnitCount : ArmyCount(),
                AttackSquads = ArmyCount(),
                DefendSquads = 0,
                OutpostCaptured = false,
                OutpostAvailable = false,
                OutpostCpCost = 0,
                TrainCountMult = Match.Mods.TrainCountMult,
                DrawPile = Match.DrawPile.Count,
                DiscardPile = Match.Discard.Count,
                HandCount = Match.Hand.Count,
                RoundsPlayed = _roundResults.Count,
                Outcome = _outcome,
                PlayerBaseHp = _playerHp,
                EnemyBaseHp = _enemyHp,
                DefeatRecord = DefeatRecord,
            };
            for (int i = 0; i < Match.Hand.Count; i++) state.Hand.Add(Match.Hand[i]);

            var cards = new List<CardDef>(Board.Cfg.Cards.Values);
            cards.Sort((a, b) => string.CompareOrdinal(a.Id, b.Id));
            foreach (CardDef card in cards)
            {
                if (card.Kind != CardKind.Train) continue;
                UnitDef def = Match.Units.Get(card.Unit);
                int buildings = CountProducers(card.BuildingTag);
                bool inHand = Match.Hand.Contains(card.Id);
                bool available = Match.CanPlayTrain(card.Id);
                string reason = "ok";
                if (!inHand) reason = "not_in_hand";
                else if (Match.Cp < card.CostCp) reason = "no_cp";
                else if (buildings <= 0) reason = "no_building";
                else if (!available) reason = "no_pop";

                int units = Match.Mods.UnitsOf(card);
                if (card.PerBuilding) units *= Math.Max(buildings, 0);

                state.TrainCards.Add(new SquadTrainEntry
                {
                    CardId = card.Id,
                    DisplayName = card.DisplayName,
                    UnitId = card.Unit,
                    UnitName = def != null ? def.DisplayName : card.Unit,
                    Tag = card.BuildingTag,
                    Role = "",
                    CostCp = card.CostCp,
                    Units = units,
                    Buildings = buildings,
                    InHand = inHand,
                    Available = available,
                    Reason = reason,
                });
            }
            state.Log.AddRange(_log);
            return state;
        }

        private int ArmyCount()
        {
            int n = 0;
            for (int i = 0; i < Match.Army.Count; i++) n += Math.Max(Match.Army[i].Units, 1);
            return n;
        }

        private int CountProducers(string tag)
        {
            int n = 0;
            foreach (PlanBuilding b in Match.Buildings)
            {
                BuildingDef def = Match.DefOf(b);
                if (def != null && def.Kind == BuildingKinds.Producer && def.Tag == tag) n++;
            }
            return n;
        }

        public List<int> FreePlayerTiles() => Board.PlaceableTiles();

        public int PlayerTileOfPlot(int plot)
        {
            _ = plot;
            return 0;
        }
    }
}
