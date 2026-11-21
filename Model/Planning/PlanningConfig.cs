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

    public sealed class BuildingDef
    {
        public string Id = "";
        public string DisplayName = "";
        public string Tag = "";
        public double Armor;
        public int ArmorType;
        public double Hp;
        public int Pop;
        public bool Buildable;
        public List<string> Trains = new List<string>();
        public double BaseDrainReduction;
    }

    public sealed class CardDef
    {
        public string Id = "";
        public string DisplayName = "";
        public CardKind Kind;
        public string Building = "";
        public string Unit = "";
        public string Tag = "";
        public string Effect = "";
        public int CostCp;
        public bool Exhaust;
        public int Count = 1;
    }

    public sealed class StrategyDef
    {
        public string Id = "";
        public string DisplayName = "";
        public double MoveMult = 1.0;
        public double ArmorMult = 1.0;
        public double CritAdd;
    }

    public sealed class StartBuilding
    {
        public string Building = "";
        public int Plot;
    }

    /// <summary>
    /// planning.json 的装载与校验。
    ///
    /// 口径：
    ///   · 建造牌打出即 Exhaust（本局不再回牌堆），落空地建 1 星；
    ///   · 训练牌循环，按建筑 Tag 让**全场同类建筑**各产 1 队对应星级兵；
    ///   · 策略牌循环，只影响本轮；
    ///   · 拖同名建筑 3 合 1：累计 3 座 → 3 星（星级 = 1 + 合并数）。
    /// </summary>
    public sealed class PlanningConfig
    {
        public int CpStart = 16;
        public int CpPerPlanning = 16;
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

        public int Plots = 10;
        public List<StartBuilding> StartBuildings = new List<StartBuilding>();

        public readonly Dictionary<string, BuildingDef> Buildings = new Dictionary<string, BuildingDef>(StringComparer.Ordinal);
        public readonly Dictionary<string, CardDef> Cards = new Dictionary<string, CardDef>(StringComparer.Ordinal);
        public readonly Dictionary<string, StrategyDef> Strategies = new Dictionary<string, StrategyDef>(StringComparer.Ordinal);

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
                        Tag = JVal.Str(bd, "tag", ""),
                        Armor = JVal.Double(bd, "armor", 0.0),
                        Hp = JVal.Double(bd, "hp", 0.0),
                        Pop = JVal.Int(bd, "pop", 0),
                        Buildable = JVal.Bool(bd, "buildable", false),
                        BaseDrainReduction = JVal.Double(bd, "base_drain_reduction", 0.0),
                    };
                    string armorName = JVal.Str(bd, "armor_type", "坚固甲");
                    b.ArmorType = CombatTypes.TryParseArmor(armorName, out int ar) ? ar : -1;
                    var trains = JVal.StringArray(bd, "trains");
                    if (trains != null) b.Trains.AddRange(trains);
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
                        Tag = JVal.Str(cd, "tag", ""),
                        Effect = JVal.Str(cd, "effect", ""),
                        CostCp = JVal.Int(cd, "cost_cp", 0),
                        Exhaust = JVal.Bool(cd, "exhaust", false),
                        Count = JVal.Int(cd, "count", 1),
                    };
                    if (kind == "build") c.Kind = CardKind.Build;
                    else if (kind == "train") c.Kind = CardKind.Train;
                    else if (kind == "strategy") c.Kind = CardKind.Strategy;
                    else
                    {
                        c.Kind = (CardKind)(-1);
                        notes.Add($"卡 {c.Id}：kind={kind} 非法（build/train/strategy）");
                    }
                    cfg.Cards[c.Id] = c;
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
            int startBases = 0, startFarms = 0, startBarracks = 0;
            foreach (var sb in StartBuildings)
            {
                if (!Buildings.TryGetValue(sb.Building, out BuildingDef b))
                {
                    errors.Add($"开局建筑 {sb.Building} 未定义");
                    continue;
                }
                if (b.Tag == "base") { hasBase = true; startBases += 1; }
                else if (b.Tag == "farm") startFarms += 1;
                else if (b.Tag == "barracks") startBarracks += 1;
                if (sb.Plot < 0 || sb.Plot >= Plots)
                    errors.Add($"开局建筑 {sb.Building} 的 plot={sb.Plot} 越界");
                if (!usedPlots.Add(sb.Plot))
                    errors.Add($"开局建筑 plot={sb.Plot} 重复");
            }
            if (!hasBase)
                errors.Add("开局必须有 1 座基地（tag=base）");
            if (startBases != 1 || startFarms != 2 || startBarracks != 1)
                errors.Add($"开局预设必须是 1 基地 + 2 农场 + 1 兵营，现在是 {startBases}/{startFarms}/{startBarracks}");

            foreach (var kv in Buildings)
            {
                var b = kv.Value;
                if (string.IsNullOrEmpty(b.Id)) errors.Add("建筑缺 id");
                if (string.IsNullOrEmpty(b.Tag)) errors.Add($"建筑 {b.Id} 缺 tag");
                if (!CombatTypes.IsValidArmor(b.ArmorType))
                    errors.Add($"建筑 {b.Id} 的 armor_type 非法");
                if (b.Hp <= 0.0) errors.Add($"建筑 {b.Id} 的 hp<=0");
                if (b.Pop < 0) errors.Add($"建筑 {b.Id} 的 pop<0");
                if (b.BaseDrainReduction < 0.0 || b.BaseDrainReduction > 0.9)
                    errors.Add($"建筑 {b.Id} 的 base_drain_reduction 越界（0..0.9）");
                foreach (var uid in b.Trains)
                {
                    if (units == null || units.Get(uid) == null)
                        errors.Add($"建筑 {b.Id} trains → 未定义单位 {uid}");
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
                        if (string.IsNullOrEmpty(c.Tag))
                        {
                            errors.Add($"训练牌 {c.Id} 缺 tag（按建筑 Tag 产兵）");
                        }
                        else
                        {
                            int matched = 0;
                            foreach (var bd in Buildings.Values)
                            {
                                if (bd.Tag == c.Tag) matched++;
                            }
                            if (matched == 0)
                            {
                                errors.Add($"训练牌 {c.Id} 的 tag={c.Tag} 没有任何建筑匹配（Tag 闭环断了）");
                            }
                            else
                            {
                                bool trains = false;
                                foreach (var bd in Buildings.Values)
                                {
                                    if (bd.Tag == c.Tag && bd.Trains.Contains(c.Unit)) trains = true;
                                }
                                if (!trains)
                                    errors.Add($"训练牌 {c.Id} → tag={c.Tag} 的建筑都不训练 {c.Unit}");
                            }
                        }
                        if (c.Exhaust)
                            errors.Add($"训练牌 {c.Id} 必须循环（exhaust=false）");
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

            return errors;
        }
    }
}
