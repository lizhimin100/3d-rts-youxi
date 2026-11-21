using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>棋盘上的一座建筑（不是场上单位）。</summary>
    public sealed class PlanBuilding
    {
        public int Plot;
        public string DefId = "";

        /// <summary>累计吃掉的同名建筑数（1 = 刚造出来，3 = 满 3 星）。</summary>
        public int MergedBuildings = 1;

        public int Star => MergedBuildings < 1 ? 1 : MergedBuildings;
    }

    /// <summary>规划阶段产出的一队兵（还没落到横道）。</summary>
    public sealed class PlannedSquad
    {
        public string UnitId = "";
        public int Star = 1;
        public string SourceBuilding = "";
        public int PopCost;
    }

    /// <summary>本轮生效的策略加成。</summary>
    public sealed class RoundModifiers
    {
        public double MoveMult = 1.0;
        public double ArmorMult = 1.0;
        public double CritAdd;
        public readonly List<string> Active = new List<string>();

        public void Reset()
        {
            MoveMult = 1.0;
            ArmorMult = 1.0;
            CritAdd = 0.0;
            Active.Clear();
        }

        public void Apply(StrategyDef s)
        {
            if (s == null) return;
            if (s.MoveMult > 0.0) MoveMult *= s.MoveMult;
            if (s.ArmorMult > 0.0) ArmorMult *= s.ArmorMult;
            CritAdd += s.CritAdd;
            Active.Add(s.DisplayName);
        }
    }

    /// <summary>规划阶段的一次快照（给复盘 / 推演行看）。</summary>
    public sealed class PlanningSnapshot
    {
        public int CpStart;
        public int CpLeft;
        public int PopCap;
        public int PopUsed;
        public int PopBlocked;
        public int Buildings;
        public int Barracks;
        public int Farms;
        public int Towers;
        public int ArmySquads;
        public int ArmyModels;
        public double DrainReduction;
        public readonly List<string> Army = new List<string>();
        public readonly List<string> Actions = new List<string>();
        public readonly List<string> Strategies = new List<string>();
    }

    /// <summary>
    /// 一场比赛的规划状态：建筑、牌堆、手牌、CP、人口、训练出来的部队。
    ///
    /// 与战斗完全解耦：这里只产出 <see cref="Army"/> 与 <see cref="Mods"/>，
    /// LaneBattle 拿过去跑 90 秒。规划本身无限时，所有操作都是纯函数式状态变更。
    /// </summary>
    public sealed class PlanningMatch
    {
        public readonly PlanningConfig Cfg;
        public readonly UnitCatalog Units;
        public readonly List<PlanBuilding> Buildings = new List<PlanBuilding>();
        public readonly List<string> DrawPile = new List<string>();
        public readonly List<string> Discard = new List<string>();
        public readonly List<string> Exhaust = new List<string>();
        public readonly List<string> Hand = new List<string>();
        public readonly List<PlannedSquad> Army = new List<PlannedSquad>();
        public readonly RoundModifiers Mods = new RoundModifiers();
        public readonly List<string> Actions = new List<string>();

        public int PlanningIndex { get; private set; }
        public int Cp { get; private set; }
        public int CpAtStart { get; private set; }
        public int PopBlocked { get; private set; }

        private readonly Rng _rng;

        public PlanningMatch(PlanningConfig cfg, UnitCatalog units, int seed)
        {
            Cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
            Units = units ?? throw new ArgumentNullException(nameof(units));
            _rng = new Rng(seed);

            foreach (var sb in cfg.StartBuildings)
            {
                Buildings.Add(new PlanBuilding
                {
                    Plot = sb.Plot,
                    DefId = sb.Building,
                    MergedBuildings = 1,
                });
            }
            DrawPile.AddRange(cfg.MakeDeck());
            Shuffle(DrawPile);
        }

        // =================================================================
        // 阶段
        // =================================================================
        public void BeginPlanning()
        {
            PlanningIndex += 1;
            CpAtStart = PlanningIndex == 1 ? Cfg.CpStart : Cfg.CpPerPlanning;
            if (CpAtStart > Cfg.CpCap) CpAtStart = Cfg.CpCap;
            Cp = CpAtStart;

            Army.Clear();
            Mods.Reset();
            Actions.Clear();
            PopBlocked = 0;
            Hand.Clear();

            if (PlanningIndex == 1 && Cfg.OpeningHand.Count > 0)
            {
                foreach (var id in Cfg.OpeningHand)
                {
                    if (TakeFromDrawPile(id)) Hand.Add(id);
                    else Actions.Add("missing_opening:" + id);
                }
            }
            else
            {
                DrawCards(Cfg.Draw);
            }
        }

        /// <summary>收牌：未打出的手牌与循环牌一起洗回牌堆；建造牌已进 Exhaust，不回。</summary>
        public void EndPlanning()
        {
            foreach (var id in Hand) Discard.Add(id);
            Hand.Clear();

            if (Discard.Count > 0)
            {
                DrawPile.AddRange(Discard);
                Discard.Clear();
            }
            Shuffle(DrawPile);
        }

        // =================================================================
        // 手牌 / 牌堆
        // =================================================================
        public int DrawCards(int n)
        {
            int drawn = 0;
            for (int i = 0; i < n && Hand.Count < Cfg.MaxHand; i++)
            {
                if (DrawPile.Count == 0)
                {
                    if (Discard.Count == 0) break;
                    DrawPile.AddRange(Discard);
                    Discard.Clear();
                    Shuffle(DrawPile);
                }
                if (DrawPile.Count == 0) break;
                Hand.Add(DrawPile[0]);
                DrawPile.RemoveAt(0);
                drawn++;
            }
            return drawn;
        }

        private bool TakeFromDrawPile(string id)
        {
            int idx = DrawPile.IndexOf(id);
            if (idx >= 0)
            {
                DrawPile.RemoveAt(idx);
                return true;
            }
            return false;
        }

        private void Shuffle(List<string> list)
        {
            for (int i = list.Count - 1; i > 0; i--)
            {
                int j = _rng.RangeInt(0, i);
                (list[i], list[j]) = (list[j], list[i]);
            }
        }

        // =================================================================
        // 查询
        // =================================================================
        public bool HasCard(string cardId) => Hand.Contains(cardId);

        public BuildingDef DefOf(PlanBuilding b)
        {
            if (b == null) return null;
            Cfg.Buildings.TryGetValue(b.DefId, out BuildingDef def);
            return def;
        }

        public int CountTag(string tag)
        {
            int n = 0;
            foreach (var b in Buildings)
            {
                var def = DefOf(b);
                if (def != null && def.Tag == tag) n++;
            }
            return n;
        }

        public int PopCap()
        {
            int cap = Cfg.BasePop;
            foreach (var b in Buildings)
            {
                var def = DefOf(b);
                if (def == null || def.Tag == "base") continue;
                cap += (int)Math.Round(def.Pop * Cfg.StarPopMult(b.Star));
            }
            return cap;
        }

        public int PopUsed()
        {
            int used = 0;
            foreach (var s in Army) used += s.PopCost;
            return used;
        }

        public int PopFree() => Math.Max(PopCap() - PopUsed(), 0);

        public int FirstFreePlot()
        {
            var used = new HashSet<int>();
            foreach (var b in Buildings) used.Add(b.Plot);
            for (int i = 0; i < Cfg.Plots; i++)
            {
                if (!used.Contains(i)) return i;
            }
            return -1;
        }

        public PlanBuilding BuildingAt(int plot)
        {
            foreach (var b in Buildings)
            {
                if (b.Plot == plot) return b;
            }
            return null;
        }

        // =================================================================
        // 操作
        // =================================================================
        public bool CanPlayBuild(string cardId, int plot = -1)
        {
            if (!Cfg.Cards.TryGetValue(cardId, out CardDef card) || card.Kind != CardKind.Build) return false;
            if (!HasCard(cardId) || Cp < card.CostCp) return false;
            if (!Cfg.Buildings.TryGetValue(card.Building, out BuildingDef def) || !def.Buildable) return false;
            int p = plot >= 0 ? plot : FirstFreePlot();
            if (p < 0 || p >= Cfg.Plots) return false;
            if (BuildingAt(p) != null) return false;
            return true;
        }

        public bool PlayBuild(string cardId, int plot = -1)
        {
            if (!CanPlayBuild(cardId, plot)) return false;
            var card = Cfg.Cards[cardId];
            int p = plot >= 0 ? plot : FirstFreePlot();
            Cp -= card.CostCp;
            Buildings.Add(new PlanBuilding { Plot = p, DefId = card.Building, MergedBuildings = 1 });
            Hand.Remove(cardId);
            Exhaust.Add(cardId);
            Actions.Add($"build:{card.Building}@{p}");
            return true;
        }

        public bool CanMerge(int targetPlot, int sourcePlot)
        {
            if (targetPlot == sourcePlot) return false;
            var target = BuildingAt(targetPlot);
            var source = BuildingAt(sourcePlot);
            if (target == null || source == null) return false;
            if (target.DefId != source.DefId) return false;
            var def = DefOf(target);
            if (def == null || def.Tag == "base") return false;
            int merged = target.MergedBuildings + source.MergedBuildings;
            if (merged > Cfg.MaxStar || merged > Cfg.MergeRequired) return false;
            return true;
        }

        /// <summary>拖同名建筑 3 合 1：目标吃掉来源，星级 = 累计建筑数（封顶 3）。</summary>
        public bool Merge(int targetPlot, int sourcePlot)
        {
            if (!CanMerge(targetPlot, sourcePlot)) return false;
            var target = BuildingAt(targetPlot);
            var source = BuildingAt(sourcePlot);
            target.MergedBuildings += source.MergedBuildings;
            Buildings.Remove(source);
            Actions.Add($"merge:{target.DefId}@{targetPlot}={target.Star}star");
            return true;
        }

        public bool CanPlayTrain(string cardId)
        {
            if (!Cfg.Cards.TryGetValue(cardId, out CardDef card) || card.Kind != CardKind.Train) return false;
            if (!HasCard(cardId) || Cp < card.CostCp) return false;
            var unit = Units.Get(card.Unit);
            if (unit == null || !unit.Enabled) return false;
            int free = PopFree();
            foreach (var b in Buildings)
            {
                var def = DefOf(b);
                if (def == null || def.Tag != card.Tag) continue;
                if (free >= unit.PopCost) return true;
            }
            return false;
        }

        /// <summary>训练牌：全场同类建筑各产 1 队（人口不够的建筑跳过并计数）。</summary>
        public int PlayTrain(string cardId)
        {
            if (!CanPlayTrain(cardId)) return 0;
            var card = Cfg.Cards[cardId];
            var unit = Units.Get(card.Unit);
            Cp -= card.CostCp;
            Hand.Remove(cardId);
            Discard.Add(cardId);

            int produced = 0;
            foreach (var b in Buildings)
            {
                var def = DefOf(b);
                if (def == null || def.Tag != card.Tag) continue;
                if (PopUsed() + unit.PopCost > PopCap())
                {
                    PopBlocked += 1;
                    continue;
                }
                Army.Add(new PlannedSquad
                {
                    UnitId = unit.Id,
                    Star = b.Star,
                    SourceBuilding = b.DefId,
                    PopCost = unit.PopCost,
                });
                produced += 1;
            }
            Actions.Add($"train:{unit.Id}x{produced}");
            return produced;
        }

        public bool CanPlayStrategy(string cardId)
        {
            if (!Cfg.Cards.TryGetValue(cardId, out CardDef card) || card.Kind != CardKind.Strategy) return false;
            if (!HasCard(cardId) || Cp < card.CostCp) return false;
            return Cfg.Strategies.ContainsKey(card.Effect);
        }

        public bool PlayStrategy(string cardId)
        {
            if (!CanPlayStrategy(cardId)) return false;
            var card = Cfg.Cards[cardId];
            Cp -= card.CostCp;
            Hand.Remove(cardId);
            Discard.Add(cardId);
            Mods.Apply(Cfg.Strategies[card.Effect]);
            Actions.Add($"strategy:{card.Effect}");
            return true;
        }

        // =================================================================
        // 快照
        // =================================================================
        public PlanningSnapshot Snapshot()
        {
            var snap = new PlanningSnapshot
            {
                CpStart = CpAtStart,
                CpLeft = Cp,
                PopCap = PopCap(),
                PopUsed = PopUsed(),
                PopBlocked = PopBlocked,
                Buildings = Buildings.Count,
                Barracks = CountTag("barracks"),
                Farms = CountTag("farm"),
                Towers = CountTag("tower"),
                ArmySquads = Army.Count,
            };
            double drain = 0.0;
            foreach (var b in Buildings)
            {
                var def = DefOf(b);
                if (def != null) drain += def.BaseDrainReduction;
            }
            snap.DrainReduction = Math.Min(drain, Cfg.MaxDrainReduction);
            var groups = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var s in Army)
            {
                snap.ArmyModels += Units.Get(s.UnitId)?.SquadSize ?? 0;
                string key = $"{s.UnitId}★{s.Star}";
                groups.TryGetValue(key, out int n);
                groups[key] = n + 1;
            }
            foreach (var kv in groups) snap.Army.Add($"{kv.Key}×{kv.Value}");
            snap.Actions.AddRange(Actions);
            snap.Strategies.AddRange(Mods.Active);
            return snap;
        }
    }
}
