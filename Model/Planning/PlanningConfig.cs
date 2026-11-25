using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    public enum CardKind
    {
        Build = 0,
        Train = 1,
        Strategy = 2,
    }

    /// <summary>
    /// 建筑大类。规则只认 kind，不认具体 id：
    ///   · Producer：训练牌的产兵建筑（tag 再细分步兵/远程）；
    ///   · Economy：规划期产 CP / 人口；
    ///   · Support：光环（空间邻接/跨格加成）；
    ///   · Defense：战斗场景投射实体塔。
    /// </summary>
    public static class BuildingKinds
    {
        public const string Keep = "keep";
        public const string Producer = "producer";
        public const string Economy = "economy";
        public const string Support = "support";
        public const string Defense = "defense";

        public static bool IsValid(string kind)
        {
            return kind == Keep || kind == Producer || kind == Economy || kind == Support || kind == Defense;
        }
    }

    /// <summary>空间光环（数据修饰器）：加成打包进 ArmyPlan.Modifiers，战斗里只乘数。</summary>
    public sealed class BuildingAura
    {
        /// <summary>army（全军）/ adjacent（上下左右 N 格）/ column（同列）/ self（只作用本建筑产出）。</summary>
        public string Scope = "adjacent";
        public int Radius = 1;
        public double[] AttackMult = { 1.0, 1.0, 1.0 };
        public double[] ArmorAdd = { 0.0, 0.0, 0.0 };

        public double AttackOf(int star) => Pick(AttackMult, star, 1.0);
        public double ArmorOf(int star) => Pick(ArmorAdd, star, 0.0);

        private static double Pick(double[] arr, int star, double fallback)
        {
            if (arr == null || arr.Length == 0) return fallback;
            int i = star - 1;
            if (i < 0) i = 0;
            if (i >= arr.Length) i = arr.Length - 1;
            return arr[i];
        }
    }

    /// <summary>经济建筑：每次规划开始额外产 CP。</summary>
    public sealed class BuildingEconomy
    {
        public int[] CpPerPlanning = { 0, 0, 0 };

        public int CpOf(int star)
        {
            if (CpPerPlanning == null || CpPerPlanning.Length == 0) return 0;
            int i = star - 1;
            if (i < 0) i = 0;
            if (i >= CpPerPlanning.Length) i = CpPerPlanning.Length - 1;
            return CpPerPlanning[i] > 0 ? CpPerPlanning[i] : 0;
        }
    }

    /// <summary>防御建筑：每场战斗投射几台什么实体塔、放在哪。</summary>
    public sealed class BuildingDefense
    {
        public string Unit = "";
        public int CountPerBuilding = 1;
        /// <summary>flank（部署线后方两翼）/ center（部署线后方中间）。</summary>
        public string Anchor = "flank";
    }

    public sealed class BuildingDef
    {
        public string Id = "";
        public string DisplayName = "";
        /// <summary>keep / producer / economy / support / defense（<see cref="BuildingKinds"/>）。</summary>
        public string Kind = "";
        /// <summary>大类下的细分：base / farm / infantry / ranged / economy / forge / tower。</summary>
        public string Tag = "";
        public double Armor;
        public int ArmorType;
        public double Hp;
        public int Pop;
        public bool Buildable;
        public List<string> Trains = new List<string>();

        public BuildingAura Aura;
        public BuildingEconomy Economy;
        public BuildingDefense Defense;
    }

    public sealed class CardDef
    {
        public string Id = "";
        public string DisplayName = "";
        public CardKind Kind;
        public string Building = "";
        public string Unit = "";
        /// <summary>训练牌匹配的建筑 Tag（2026-11-24 由 tag 更名，语义明确）。</summary>
        public string BuildingTag = "";
        public string Effect = "";
        public int CostCp;
        public bool Exhaust;
        /// <summary>卡组里的副本数（一张卡 = 几张牌）。</summary>
        public int Count = 1;
        /// <summary>
        /// 训练牌一次产**几名独立单兵**（每座匹配建筑各一批，见 <see cref="UnitsMode"/>）。
        /// 「加快训练」在本回合把这里乘 1.5 再向上取整。
        /// </summary>
        public int Units = 1;
        /// <summary>per_building（每座各产，默认）/ split（一张牌总数分摊）。</summary>
        public string UnitsMode = "per_building";

        public bool PerBuilding => UnitsMode != "split";
    }

    public sealed class StrategyDef
    {
        public string Id = "";
        public string DisplayName = "";
        public double MoveMult = 1.0;
        public double ArmorMult = 1.0;
        public double CritAdd;
        /// <summary>
        /// 本回合征召牌产出数量的倍率（「加快训练」= 1.5）。
        /// 只乘在训练牌上，不影响 CP/人口，也不跨回合。
        /// </summary>
        public double TrainCountMult = 1.0;
    }

    public sealed class StartBuilding
    {
        public string Building = "";
        public int Plot;
    }

    /// <summary>
    /// planning.json 的装载与校验。
    ///
    /// 口径（2026-11-24 冻结）：
    ///   · 建造牌打出即 Exhaust（本局不再回牌堆），落空地建 1 星；
    ///   · 训练牌循环，按 building_tag 让**全场同类建筑各产一批**（units_mode=per_building）；
    ///   · 策略牌循环，只影响本轮；
    ///   · 拖同名建筑 3 合 1：累计 3 座 → 3 星；
    ///   · 建筑效果（aura/economy/defense）只声明数据，结算走 MechanicBus。
    /// </summary>
    public sealed class PlanningConfig
    {
        public int CpStart = 12;
        public int CpPerPlanning = 12;
        public int CpCap = 24;

        public int BasePop = 12;
        public int Draw = 6;
        public int MaxHand = 8;
        public List<string> OpeningHand = new List<string>();

        public int MergeRequired = 3;
        public int MaxStar = 3;

        public double[] StarAttack = { 1.0, 1.35, 1.8 };
        public double[] StarHp = { 1.0, 1.4, 2.0 };
        public double[] StarPop = { 1.0, 1.4, 2.0 };

        public int Plots = 18;
        public List<StartBuilding> StartBuildings = new List<StartBuilding>();

        public readonly Dictionary<string, BuildingDef> Buildings = new Dictionary<string, BuildingDef>(StringComparer.Ordinal);
        public readonly Dictionary<string, CardDef> Cards = new Dictionary<string, CardDef>(StringComparer.Ordinal);
        public readonly Dictionary<string, StrategyDef> Strategies = new Dictionary<string, StrategyDef>(StringComparer.Ordinal);

        /// <summary>全局机制（遗物/被动）：只有数据，不进代码分支。</summary>
        public readonly List<MechanicDef> Mechanics = new List<MechanicDef>();

        public double StarAttackMult(int star) => Pick(StarAttack, star);
        public double StarHpMult(int star) => Pick(StarHp, star);
        public double StarPopMult(int star) => Pick(StarPop, star);

        private static double Pick(double[] arr, int star)
        {
            if (arr == null || arr.Length == 0) return 1.0;
            int i = star - 1;
            if (i < 0) i = 0;
            if (i >= arr.Length) i = arr.Length - 1;
            return arr[i] > 0.0 ? arr[i] : 1.0;
        }

        public List<string> MakeDeck()
        {
            var deck = new List<string>();
            foreach (var c in Cards.Values)
            {
                for (int i = 0; i < Math.Max(c.Count, 1); i++) deck.Add(c.Id);
            }
            deck.Sort(StringComparer.Ordinal);
            return deck;
        }

        public static PlanningConfig FromDict(IDictionary<string, object> d, UnitCatalog units, List<string> notes)
        {
            var cfg = new PlanningConfig();
            if (d == null)
            {
                notes.Add("planning 配置为空");
                return cfg;
            }

            var cp = JVal.Dict(d, "cp");
            if (cp != null)
            {
                cfg.CpStart = JVal.Int(cp, "start", cfg.CpStart);
                cfg.CpPerPlanning = JVal.Int(cp, "per_planning", cfg.CpPerPlanning);
                cfg.CpCap = JVal.Int(cp, "cap", cfg.CpCap);
            }
            else notes.Add("缺少 cp");

            var pop = JVal.Dict(d, "pop");
            if (pop != null) cfg.BasePop = JVal.Int(pop, "base", cfg.BasePop);
            else notes.Add("缺少 pop");

            var hand = JVal.Dict(d, "hand");
            if (hand != null)
            {
                cfg.Draw = JVal.Int(hand, "draw", cfg.Draw);
                cfg.MaxHand = JVal.Int(hand, "max", cfg.MaxHand);
                var opening = JVal.StringArray(hand, "opening");
                if (opening != null) cfg.OpeningHand.AddRange(opening);
            }
            else notes.Add("缺少 hand");

            var merge = JVal.Dict(d, "merge");
            if (merge != null)
            {
                cfg.MergeRequired = JVal.Int(merge, "required", cfg.MergeRequired);
                cfg.MaxStar = JVal.Int(merge, "max_star", cfg.MaxStar);
            }

            var star = JVal.Dict(d, "star");
            if (star != null)
            {
                var a = JVal.DoubleArray(star, "attack_mult", 3);
                if (a != null) cfg.StarAttack = a;
                var h = JVal.DoubleArray(star, "hp_mult", 3);
                if (h != null) cfg.StarHp = h;
                var p = JVal.DoubleArray(star, "pop_mult", 3);
                if (p != null) cfg.StarPop = p;
            }
            else notes.Add("缺少 star");

            var board = JVal.Dict(d, "board");
            if (board != null)
            {
                cfg.Plots = JVal.Int(board, "plots", cfg.Plots);
                var start = JVal.List(board, "start");
                if (start != null)
                {
                    foreach (var item in start)
                    {
                        var sd = JVal.AsDict(item);
                        if (sd == null) continue;
                        cfg.StartBuildings.Add(new StartBuilding
                        {
                            Building = JVal.Str(sd, "building", ""),
                            Plot = JVal.Int(sd, "plot", -1),
                        });
                    }
                }
            }
            else notes.Add("缺少 board");

            var buildings = JVal.List(d, "buildings");
            if (buildings == null)
            {
                notes.Add("缺少 buildings");
            }
            else
            {
                foreach (var item in buildings)
                {
                    var bd = JVal.AsDict(item);
                    if (bd == null) continue;
                    var b = new BuildingDef
                    {
                        Id = JVal.Str(bd, "id", ""),
                        DisplayName = JVal.Str(bd, "display_name", ""),
                        Kind = JVal.Str(bd, "kind", ""),
                        Tag = JVal.Str(bd, "tag", ""),
                        Armor = JVal.Double(bd, "armor", 0.0),
                        Hp = JVal.Double(bd, "hp", 0.0),
                        Pop = JVal.Int(bd, "pop", 0),
                        Buildable = JVal.Bool(bd, "buildable", false),
                    };
                    string armorName = JVal.Str(bd, "armor_type", "重甲");
                    b.ArmorType = CombatTypes.TryParseArmor(armorName, out int ar) ? ar : -1;
                    var trains = JVal.StringArray(bd, "trains");
                    if (trains != null) b.Trains.AddRange(trains);

                    var aura = JVal.Dict(bd, "aura");
                    if (aura != null)
                    {
                        b.Aura = new BuildingAura
                        {
                            Scope = JVal.Str(aura, "scope", "adjacent"),
                            Radius = JVal.Int(aura, "radius", 1),
                        };
                        var am = JVal.DoubleArray(aura, "attack_mult", 3);
                        if (am != null) b.Aura.AttackMult = am;
                        var aa = JVal.DoubleArray(aura, "armor_add", 3);
                        if (aa != null) b.Aura.ArmorAdd = aa;
                    }

                    var eco = JVal.Dict(bd, "economy");
                    if (eco != null)
                    {
                        b.Economy = new BuildingEconomy();
                        var cps = JVal.DoubleArray(eco, "cp_per_planning", 3);
                        if (cps != null)
                        {
                            b.Economy.CpPerPlanning = new int[cps.Length];
                            for (int i = 0; i < cps.Length; i++)
                                b.Economy.CpPerPlanning[i] = (int)Math.Round(cps[i]);
                        }
                    }

                    var def = JVal.Dict(bd, "defense");
                    if (def != null)
                    {
                        b.Defense = new BuildingDefense
                        {
                            Unit = JVal.Str(def, "unit", ""),
                            CountPerBuilding = JVal.Int(def, "count_per_building", 1),
                            Anchor = JVal.Str(def, "anchor", "flank"),
                        };
                    }

                    if (cfg.Buildings.ContainsKey(b.Id))
                        notes.Add($"建筑 id 重复：{b.Id}（后一条会覆盖前一条）");
                    cfg.Buildings[b.Id] = b;
                }
            }

            var strategies = JVal.Dict(d, "strategies");
            if (strategies != null)
            {
                foreach (var kv in strategies)
                {
                    var sd = JVal.AsDict(kv.Value);
                    if (sd == null) continue;
                    cfg.Strategies[kv.Key] = new StrategyDef
                    {
                        Id = kv.Key,
                        DisplayName = JVal.Str(sd, "display_name", kv.Key),
                        MoveMult = JVal.Double(sd, "move_mult", 1.0),
                        ArmorMult = JVal.Double(sd, "armor_mult", 1.0),
                        CritAdd = JVal.Double(sd, "crit_add", 0.0),
                        TrainCountMult = JVal.Double(sd, "train_count_mult", 1.0),
                    };
                }
            }

            var cards = JVal.List(d, "cards");
            if (cards == null)
            {
                notes.Add("缺少 cards");
            }
            else
            {
                foreach (var item in cards)
                {
                    var cd = JVal.AsDict(item);
                    if (cd == null) continue;
                    string kind = JVal.Str(cd, "kind", "");
                    var c = new CardDef
                    {
                        Id = JVal.Str(cd, "id", ""),
                        DisplayName = JVal.Str(cd, "display_name", ""),
                        Building = JVal.Str(cd, "building", ""),
                        Unit = JVal.Str(cd, "unit", ""),
                        BuildingTag = JVal.Str(cd, "building_tag", JVal.Str(cd, "tag", "")),
                        Effect = JVal.Str(cd, "effect", ""),
                        CostCp = JVal.Int(cd, "cost_cp", 0),
                        Exhaust = JVal.Bool(cd, "exhaust", false),
                        Count = JVal.Int(cd, "count", 1),
                        Units = JVal.Int(cd, "units", 1),
                        UnitsMode = JVal.Str(cd, "units_mode", "per_building"),
                    };
                    if (kind == "build") c.Kind = CardKind.Build;
                    else if (kind == "train") c.Kind = CardKind.Train;
                    else if (kind == "strategy") c.Kind = CardKind.Strategy;
                    else
                    {
                        c.Kind = (CardKind)(-1);
                        notes.Add($"卡 {c.Id}：kind={kind} 非法（build/train/strategy）");
                    }
                    if (cfg.Cards.ContainsKey(c.Id))
                        notes.Add($"卡 id 重复：{c.Id}（后一条会覆盖前一条）");
                    cfg.Cards[c.Id] = c;
                }
            }

            var mechanics = JVal.List(d, "mechanics");
            if (mechanics != null)
            {
                foreach (var item in mechanics)
                {
                    var md = JVal.AsDict(item);
                    if (md == null) continue;
                    if (!JVal.Bool(md, "enabled", true)) continue;
                    cfg.Mechanics.Add(MechanicBus.ParseDef(md, notes));
                }
            }

            _ = units;
            return cfg;
        }

        public List<string> Validate(UnitCatalog units)
        {
            var errors = new List<string>();

            if (CpStart < 0 || CpPerPlanning < 0 || CpCap <= 0)
                errors.Add($"cp 配置非法（start={CpStart} per={CpPerPlanning} cap={CpCap}）");
            if (CpStart > CpCap || CpPerPlanning > CpCap)
                errors.Add($"cp start/per 不能超过 cap（{CpStart}/{CpPerPlanning} > {CpCap}）");
            if (BasePop < 0)
                errors.Add($"pop.base={BasePop} 为负");
            if (Draw < 1 || MaxHand < Draw)
                errors.Add($"hand 配置非法（draw={Draw} max={MaxHand}）");

            // 单兵制：不靠农场也不许卡死 —— 基地自带人口必须够造第一座产兵建筑。
            foreach (var kv in Buildings)
            {
                if (kv.Value.Kind != BuildingKinds.Producer) continue;
                if (BasePop < Math.Max(kv.Value.Pop, 1))
                    errors.Add($"pop.base={BasePop} 不够造一座产兵建筑 {kv.Key}（pop={kv.Value.Pop}）—— 无农场牌时会卡死");
            }
            if (MergeRequired != 3)
                errors.Add($"merge.required={MergeRequired}，规格是 3 合 1");
            if (MaxStar != 3)
                errors.Add($"merge.max_star={MaxStar}，规格是满 3 星");
            if (StarAttack == null || StarAttack.Length != 3 || StarHp == null || StarHp.Length != 3 ||
                StarPop == null || StarPop.Length != 3)
                errors.Add("star 三个倍率数组都必须是 3 项（1/2/3 星）");
            else if (Math.Abs(StarAttack[0] - 1.0) > 1e-9 || Math.Abs(StarHp[0] - 1.0) > 1e-9)
                errors.Add("1 星倍率必须是 1.0（新造出来不该有隐藏加成）");

            if (Plots < 1)
                errors.Add($"board.plots={Plots} 非法");

            var usedPlots = new HashSet<int>();
            bool hasBase = false;
            int startBases = 0, startFarms = 0, startProducers = 0;
            foreach (var sb in StartBuildings)
            {
                if (!Buildings.TryGetValue(sb.Building, out BuildingDef b))
                {
                    errors.Add($"开局建筑 {sb.Building} 未定义");
                    continue;
                }
                if (b.Kind == BuildingKinds.Keep) { hasBase = true; startBases += 1; }
                else if (b.Tag == "farm") startFarms += 1;
                if (b.Kind == BuildingKinds.Producer) startProducers += 1;
                if (sb.Plot < 0 || sb.Plot >= Plots)
                    errors.Add($"开局建筑 {sb.Building} 的 plot={sb.Plot} 越界");
                if (!usedPlots.Add(sb.Plot))
                    errors.Add($"开局建筑 plot={sb.Plot} 重复");
            }
            if (!hasBase)
                errors.Add("开局必须有 1 座基地（kind=keep）");
            if (startBases != 1 || startFarms != 2 || startProducers < 1)
                errors.Add($"开局预设必须是 1 基地 + 2 农场 + ≥1 产兵建筑，现在是 {startBases}/{startFarms}/{startProducers}");

            foreach (var kv in Buildings)
            {
                var b = kv.Value;
                if (string.IsNullOrEmpty(b.Id)) errors.Add("建筑缺 id");
                if (string.IsNullOrEmpty(b.Tag)) errors.Add($"建筑 {b.Id} 缺 tag");
                if (!BuildingKinds.IsValid(b.Kind))
                    errors.Add($"建筑 {b.Id} 的 kind={b.Kind} 非法（keep/producer/economy/support/defense）");
                if (!CombatTypes.IsValidArmor(b.ArmorType))
                    errors.Add($"建筑 {b.Id} 的 armor_type 非法");
                if (b.Hp <= 0.0) errors.Add($"建筑 {b.Id} 的 hp<=0");
                if (b.Pop < 0) errors.Add($"建筑 {b.Id} 的 pop<0");
                if (b.Kind == BuildingKinds.Producer && b.Trains.Count == 0)
                    errors.Add($"产兵建筑 {b.Id} 的 trains 为空");
                if (b.Kind != BuildingKinds.Producer && b.Trains.Count > 0)
                    errors.Add($"非产兵建筑 {b.Id} 不该有 trains");
                foreach (var uid in b.Trains)
                {
                    if (units == null || units.Get(uid) == null)
                        errors.Add($"建筑 {b.Id} trains → 未定义单位 {uid}");
                }
                if (b.Aura != null)
                {
                    if (b.Kind != BuildingKinds.Support)
                        errors.Add($"建筑 {b.Id} 有 aura 但 kind={b.Kind}（应为 support）");
                    if (b.Aura.Scope != "army" && b.Aura.Scope != "adjacent" &&
                        b.Aura.Scope != "column" && b.Aura.Scope != "self")
                        errors.Add($"建筑 {b.Id} 的 aura.scope={b.Aura.Scope} 非法（army/adjacent/column/self）");
                    if (b.Aura.Radius < 0 || b.Aura.Radius > 3)
                        errors.Add($"建筑 {b.Id} 的 aura.radius={b.Aura.Radius} 越界（0..3）");
                    foreach (double v in b.Aura.AttackMult)
                        if (v < 0.5 || v > 2.0) errors.Add($"建筑 {b.Id} 的 aura.attack_mult={v} 越界（0.5..2.0）");
                    foreach (double v in b.Aura.ArmorAdd)
                        if (v < 0.0 || v > 20.0) errors.Add($"建筑 {b.Id} 的 aura.armor_add={v} 越界（0..20）");
                }
                if (b.Economy != null)
                {
                    if (b.Kind != BuildingKinds.Economy)
                        errors.Add($"建筑 {b.Id} 有 economy 但 kind={b.Kind}（应为 economy）");
                    foreach (int v in b.Economy.CpPerPlanning)
                        if (v < 0 || v > 6) errors.Add($"建筑 {b.Id} 的 economy.cp_per_planning={v} 越界（0..6）");
                }
                if (b.Defense != null)
                {
                    if (b.Kind != BuildingKinds.Defense)
                        errors.Add($"建筑 {b.Id} 有 defense 但 kind={b.Kind}（应为 defense）");
                    UnitDef tower = units != null ? units.Get(b.Defense.Unit) : null;
                    if (tower == null) errors.Add($"建筑 {b.Id} 的 defense.unit={b.Defense.Unit} 未定义");
                    else if (!tower.Static) errors.Add($"建筑 {b.Id} 的 defense.unit={b.Defense.Unit} 不是 static 单位");
                    if (b.Defense.CountPerBuilding < 1 || b.Defense.CountPerBuilding > 4)
                        errors.Add($"建筑 {b.Id} 的 defense.count_per_building={b.Defense.CountPerBuilding} 越界（1..4）");
                    if (b.Defense.Anchor != "flank" && b.Defense.Anchor != "center")
                        errors.Add($"建筑 {b.Id} 的 defense.anchor={b.Defense.Anchor} 非法（flank/center）");
                }
            }

            var seenCards = new HashSet<string>(StringComparer.Ordinal);
            int buildCards = 0, trainCards = 0, strategyCards = 0;
            foreach (var kv in Cards)
            {
                var c = kv.Value;
                if (string.IsNullOrEmpty(c.Id)) errors.Add("卡缺 id");
                if (!seenCards.Add(c.Id)) errors.Add($"卡 {c.Id} 重复");
                if (string.IsNullOrWhiteSpace(c.DisplayName)) errors.Add($"卡 {c.Id} 缺 display_name");
                if (c.Count < 1) errors.Add($"卡 {c.Id} 的 count<1");
                if (c.CostCp < 0) errors.Add($"卡 {c.Id} 的 cost_cp<0");
                if (!Enum.IsDefined(typeof(CardKind), (int)c.Kind) || (int)c.Kind < 0)
                {
                    errors.Add($"卡 {c.Id} 的 kind 非法");
                    continue;
                }

                switch (c.Kind)
                {
                    case CardKind.Build:
                        buildCards++;
                        if (!Buildings.TryGetValue(c.Building, out BuildingDef bdef))
                        {
                            errors.Add($"建造牌 {c.Id} → 未定义建筑 {c.Building}");
                        }
                        else if (!bdef.Buildable)
                        {
                            errors.Add($"建造牌 {c.Id} → 建筑 {c.Building} 不可建造");
                        }
                        if (!c.Exhaust)
                            errors.Add($"建造牌 {c.Id} 必须 exhaust=true（打出即消耗）");
                        break;

                    case CardKind.Train:
                        trainCards++;
                        if (units == null || units.Get(c.Unit) == null)
                            errors.Add($"训练牌 {c.Id} → 未定义单位 {c.Unit}");
                        else if (!units.Get(c.Unit).Enabled)
                            errors.Add($"训练牌 {c.Id} → 单位 {c.Unit} 已禁用");
                        if (string.IsNullOrEmpty(c.BuildingTag))
                        {
                            errors.Add($"训练牌 {c.Id} 缺 building_tag（按建筑 Tag 产兵）");
                        }
                        else
                        {
                            int matched = 0;
                            foreach (var bd in Buildings.Values)
                            {
                                if (bd.Kind != BuildingKinds.Producer) continue;
                                if (bd.Tag == c.BuildingTag) matched++;
                            }
                            if (matched == 0)
                            {
                                errors.Add($"训练牌 {c.Id} 的 building_tag={c.BuildingTag} 没有任何产兵建筑匹配");
                            }
                            else
                            {
                                bool trains = false;
                                foreach (var bd in Buildings.Values)
                                {
                                    if (bd.Kind == BuildingKinds.Producer && bd.Tag == c.BuildingTag &&
                                        bd.Trains.Contains(c.Unit)) trains = true;
                                }
                                if (!trains)
                                    errors.Add($"训练牌 {c.Id} → building_tag={c.BuildingTag} 的建筑都不训练 {c.Unit}");
                            }
                        }
                        if (c.Exhaust)
                            errors.Add($"训练牌 {c.Id} 必须循环（exhaust=false）");
                        if (c.Units < 1 || c.Units > 12)
                            errors.Add($"训练牌 {c.Id} 的 units={c.Units} 越界（1..12 名单兵）");
                        if (c.UnitsMode != "per_building" && c.UnitsMode != "split")
                            errors.Add($"训练牌 {c.Id} 的 units_mode={c.UnitsMode} 非法（per_building/split）");
                        break;

                    case CardKind.Strategy:
                        strategyCards++;
                        if (!Strategies.ContainsKey(c.Effect))
                            errors.Add($"策略牌 {c.Id} → 未定义策略 {c.Effect}");
                        if (c.Exhaust)
                            errors.Add($"策略牌 {c.Id} 必须循环（exhaust=false）");
                        break;
                }
            }

            foreach (var kv in Strategies)
            {
                if (kv.Value.TrainCountMult < 1.0 || kv.Value.TrainCountMult > 3.0)
                    errors.Add($"策略 {kv.Key} 的 train_count_mult={kv.Value.TrainCountMult} 越界（1.0..3.0）");
            }

            if (buildCards == 0) errors.Add("没有建造牌");
            if (trainCards == 0) errors.Add("没有训练牌");

            // 起手牌：必须真实存在，且副本数够
            var openingCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var id in OpeningHand)
            {
                if (!Cards.ContainsKey(id))
                {
                    errors.Add($"起手牌 {id} 未定义");
                    continue;
                }
                openingCounts.TryGetValue(id, out int n);
                openingCounts[id] = n + 1;
            }
            foreach (var kv in openingCounts)
            {
                if (kv.Value > Cards[kv.Key].Count)
                    errors.Add($"起手牌 {kv.Key} 要 {kv.Value} 张，但卡组只有 {Cards[kv.Key].Count} 张");
            }
            if (OpeningHand.Count > MaxHand)
                errors.Add($"起手牌 {OpeningHand.Count} 张超过手牌上限 {MaxHand}");

            // 机制总线：数据驱动定义必须自洽
            errors.AddRange(MechanicBus.Validate(Mechanics));
            return errors;
        }
    }
}
