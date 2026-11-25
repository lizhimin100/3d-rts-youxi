using System;
using System.Collections.Generic;
using System.Linq;

namespace WarIsland.Model
{
    /// <summary>自检结果（--check 的唯一读数口）。</summary>
    public sealed class CheckReport
    {
        public int Checks;
        public readonly List<string> Lines = new List<string>();
        public readonly List<string> Errors = new List<string>();
        public bool Ok => Errors.Count == 0;

        public void Pass(string line)
        {
            Checks += 1;
            Lines.Add("OK   " + line);
        }

        public void Fail(string line)
        {
            Checks += 1;
            Lines.Add("FAIL " + line);
            Errors.Add(line);
        }

        public void Expect(bool cond, string line, string detail = "")
        {
            if (cond) Pass(line + (string.IsNullOrEmpty(detail) ? "" : "  " + detail));
            else Fail(line + (string.IsNullOrEmpty(detail) ? "" : "  " + detail));
        }
    }

    /// <summary>
    /// Phase 2 规则自检（纯 Model，可不依赖 Godot 运行）。
    ///
    /// 覆盖：
    ///   · 4×4 克制表 / 废弃类型清零；
    ///   · base_damage / static 塔；
    ///   · 棋盘竖列顺序 / 钩子 / 3 合 1 / 拆除；
    ///   · 单轮波次（无 attack/defend）；
    ///   · 45 秒狂暴配置；
    ///   · 幸存 base_damage 结算（全额 / 差值 / 封顶）；
    ///   · 伤害跳字分级；
    ///   · 3 项**反向验错**（故意改坏 → 必须报错）。
    /// </summary>
    public static class Phase2Checks
    {
        public static CheckReport Run(
            IDictionary<string, object> unitsDict,
            IDictionary<string, object> combatDict,
            IDictionary<string, object> planningDict,
            IDictionary<string, object> shellDict,
            IDictionary<string, object> layoutDict,
            IDictionary<string, object> levelsDict,
            IDictionary<string, object> tuningDict,
            string levelId,
            bool includeReverse = true)
        {
            var report = new CheckReport();
            var notes = new List<string>();

            var rules = CombatRules.FromDict(combatDict);
            var units = UnitCatalog.FromDict(unitsDict, rules, notes);
            var planning = PlanningConfig.FromDict(planningDict, units, notes);
            var levels = LevelSet.FromDict(levelsDict, units, notes);
            var tuning = BattleTuning.FromDict(tuningDict);

            // ---- 1. 规则表 ----
            var ruleErrors = new List<string>(notes);
            ruleErrors.AddRange(rules.Validate());
            report.Expect(ruleErrors.Count == 0, "4×4 克制表合法（4 攻击 / 4 护甲 / 16 格）",
                ruleErrors.Count == 0 ? $"stride={CombatRules.Stride}" : string.Join("; ", ruleErrors));

            report.Expect(!HasLegacyTypeValue(unitsDict) && !HasLegacyTypeValue(planningDict) &&
                          !HasLegacyTypeValue(levelsDict) && !HasLegacyTypeValue(combatDict),
                "全仓 JSON 的 armor_type/attack_type 不再出现 坚固甲/神圣甲/混乱/神力");

            // ---- 2. 兵种 ----
            var unitErrors = units.Validate();
            report.Expect(unitErrors.Count == 0, "兵种数据合法（base_damage/static/4×4）",
                unitErrors.Count == 0 ? $"{units.All.Count} 个兵种" : string.Join("; ", unitErrors.Take(3)));

            UnitDef tower = units.Get("watchtower_bolt");
            report.Expect(tower != null && tower.Static && tower.Projectile &&
                          Math.Abs(tower.MoveSpeed) < 1e-9 &&
                          tower.BaseDamageOf(1) == 0.0 && tower.BaseDamageOf(3) == 0.0,
                "哨塔实体：static + 投射物 + base_damage 全 0");
            report.Expect(tower != null && tower.ArmorType == (int)ArmorType.Heavy,
                "哨塔护甲是 重甲（不是已废弃的坚固甲）");

            // ---- 3. 规划表 ----
            report.Expect(!ContainsKey(planningDict, "max_drain_reduction") &&
                          !ContainsKey(planningDict, "base_drain_reduction"),
                "规划表不再有占区减伤字段");
            report.Expect(!CardsHaveKey(planningDict, "role"), "训练牌不再有 role（攻防两轮已取消）");
            report.Expect(AllTrainCardsHave(planningDict, "building_tag") &&
                          AllTrainCardsHave(planningDict, "units_mode"),
                "训练牌都有 building_tag + units_mode");

            var planErrors = planning.Validate(units);
            report.Expect(planErrors.Count == 0, "规划表合法（kind/aura/economy/defense）",
                planErrors.Count == 0 ? $"{planning.Cards.Count} 张卡" : string.Join("; ", planErrors.Take(3)));

            // ---- 4. 关卡：单轮波次 + battlefield ----
            LevelDef level = levels.Get(levelId) ?? (levels.Levels.Count > 0 ? levels.Levels[0] : null);
            report.Expect(level != null, "找到关卡 " + levelId);
            if (level == null) return report;
            report.Expect(!LevelsRoundsHaveKey(levelsDict, "kind"), "关卡 rounds 不再按 attack/defend 分叉");
            report.Expect(level.Rounds.Count >= 1, "关卡至少有 1 轮敌军波次", $"{level.Rounds.Count} 轮");
            var levelErrors = level.Validate(units);
            report.Expect(levelErrors.Count == 0, "关卡合法（battlefield 部署线 / 波次 / 60 秒）",
                levelErrors.Count == 0 ? $"deploy {level.Battlefield.DeployPlayer}→{level.Battlefield.DeployEnemy}" : string.Join("; ", levelErrors.Take(3)));

            // ---- 5. 狂暴与结算 ----
            report.Expect(Math.Abs(tuning.BerserkStartSeconds - 45.0) < 1e-9,
                "45 秒狂暴配置存在", $"start={tuning.BerserkStartSeconds}");
            report.Expect(tuning.BerserkAttackSpeedMult >= 1.0 && tuning.BaseDamageCap > 0,
                "狂暴倍率与 base_damage 上限合法", $"atk×{tuning.BerserkAttackSpeedMult} cap={tuning.BaseDamageCap}");

            var full = RoundResolver.Resolve(10.0, 0.0, 48, false);
            report.Expect(Math.Abs(full.PlayerApplied - 10.0) < 1e-9 && full.EnemyApplied == 0.0,
                "结算：只有一方幸存 → 全额扣对方");
            var diff = RoundResolver.Resolve(10.0, 4.0, 48, true);
            report.Expect(Math.Abs(diff.PlayerApplied - 6.0) < 1e-9 && diff.EnemyApplied == 0.0 && diff.TieDiff,
                "结算：双方幸存 → 只扣差值（多的一方扣少的一方）");
            var equal = RoundResolver.Resolve(5.0, 5.0, 48, true);
            report.Expect(equal.PlayerApplied == 0.0 && equal.EnemyApplied == 0.0,
                "结算：双方相等 → 不扣血");
            var capped = RoundResolver.Resolve(100.0, 0.0, 48, false);
            report.Expect(Math.Abs(capped.PlayerApplied - 48.0) < 1e-9,
                "结算：单轮封顶生效", "100 → 48");

            // ---- 6. 跳字分级 ----
            var atk = new CombatAttacker
            {
                Damage = 10.0, Cooldown = 1.0, Hit = 100.0, CritChance = 0.0,
                AttackType = (int)AttackType.Pierce,
            };
            var light = new CombatDefender { Armor = 0.0, ArmorType = (int)ArmorType.Light, Dodge = 0.0 };
            var heavy = new CombatDefender { Armor = 0.0, ArmorType = (int)ArmorType.Heavy, Dodge = 0.0 };
            var medium = new CombatDefender { Armor = 0.0, ArmorType = (int)ArmorType.Medium, Dodge = 0.0 };
            report.Expect(CombatCalculator.Compute(atk, light, rules, 0.5, 0.5).Feedback == DamageFeedback.CritOrCounter,
                "跳字：克制倍率 >1 → crit_or_counter");
            report.Expect(CombatCalculator.Compute(atk, heavy, rules, 0.5, 0.5).Feedback == DamageFeedback.Resisted,
                "跳字：克制倍率 <1 → resisted");
            var normalAtk = atk; normalAtk.AttackType = (int)AttackType.Normal;
            report.Expect(CombatCalculator.Compute(normalAtk, medium, rules, 0.5, 0.5).Feedback == DamageFeedback.Normal,
                "跳字：1.0 倍 → normal");
            var missAtk = atk; missAtk.Hit = 0.0;
            report.Expect(CombatCalculator.Compute(missAtk, light, rules, 0.9, 0.5).Feedback == DamageFeedback.Miss,
                "跳字：未命中 → miss");

            // ---- 7. 棋盘：竖列顺序 / 钩子 / 合并 / 拆除 ----
            var boardNotes = new List<string>();
            BoardSession real = BoardSession.Create(planning, units, shellDict, layoutDict, 12345, boardNotes);
            report.Expect(real.Arena.RowCount == 3, "棋盘竖列每列 3 格", $"rows={real.Arena.RowCount} cols={real.Arena.ColumnCount}");
            report.Expect(real.Arena.ColumnCount >= 2, "棋盘至少 2 列", $"cols={real.Arena.ColumnCount}");
            report.Expect(real.NextFillTile() > 0, "棋盘有空位可填", "next=" + real.NextFillTile());

            real.BeginPlanning();
            real.Match.AddCp(24);
            real.Match.Hand.Add("build_barracks");
            real.Match.Hand.Add("build_barracks");
            real.Match.Hand.Add("build_barracks");
            int nextTile = real.NextFillTile();
            int firstCol = real.Arena.ColumnOf(nextTile);
            int wrongTile = FindTileInOtherColumn(real, firstCol);
            report.Expect(wrongTile > 0 && !real.CanPlaceAt(wrongTile),
                "列顺序：非当前列的空格被拒绝", $"next={nextTile} try={wrongTile}");
            report.Expect(real.PlaceBuild("build_barracks", wrongTile) == 0,
                "反向验错③：违背棋盘按列顺序落子 → 必须 FAIL");
            report.Expect(real.PlaceBuild("build_barracks", nextTile) == nextTile,
                "列顺序：当前填充位落子成功", "tile=" + nextTile);

            real.AllowFreePlacement = true;
            report.Expect(real.CanPlaceAt(wrongTile), "钩子：AllowFreePlacement=true 时任意空格可放");
            real.AllowFreePlacement = false;

            // 填满当前列 → 自动开下一列
            int guard = 0;
            while (real.Arena.ColumnOf(real.NextFillTile()) == firstCol && guard++ < 6)
            {
                if (real.PlaceBuild("build_barracks", 0) <= 0) break;
            }
            int afterColumn = real.NextFillTile();
            report.Expect(afterColumn > 0 && real.Arena.ColumnOf(afterColumn) > firstCol,
                "列顺序：填满一列才开下一列", $"next={afterColumn} col={real.Arena.ColumnOf(afterColumn)}");

            // 拆除：空出的格子成为下一个优先填充位
            int demolished = real.Arena.ColumnOf(afterColumn) > firstCol
                ? FindAnyOccupiedInColumn(real, firstCol)
                : 0;
            if (demolished > 0)
            {
                bool ok = real.Demolish(demolished);
                report.Expect(ok && real.NextFillTile() == demolished,
                    "拆除：空出的格子回到优先填充位", $"tile={demolished}");
            }

            // 3 合 1：用合成布局（同格 3 座兵营）验证，不依赖手牌
            var mergeLayout = MakeMergeLayout(shellDict);
            BoardSession mergeBoard = BoardSession.Create(planning, units, shellDict, mergeLayout, 999, new List<string>());
            int t2 = 2, t3 = 3, t4 = 4;
            int star2 = mergeBoard.Merge(t3, t2);
            int star3 = mergeBoard.Merge(t3, t4);
            report.Expect(star2 == 2 && star3 == 3, "3 合 1：目标格升到 3 星", $"{star2}→{star3}");
            report.Expect(mergeBoard.BuildingAt(t4) == null && mergeBoard.BuildingAt(t3) != null,
                "3 合 1：来源格清空、目标格保留");
            report.Expect(mergeBoard.Merge(t3, t2) == 0, "3 合 1：满星后拒绝继续合并");

            // ---- 8. 三项反向验错 ----
            if (includeReverse)
            {
                var badUnits = CloneDict(unitsDict);
                var badList = JVal.List(badUnits, "units");
                if (badList != null && badList.Count > 0)
                {
                    var first = JVal.AsDict(badList[0]);
                    if (first != null) first["armor_type"] = "坚固甲";
                }
                var badCatalog = UnitCatalog.FromDict(badUnits, rules, new List<string>());
                var badErrors = badCatalog.Validate();
                report.Expect(badErrors.Count > 0 && string.Join(";", badErrors).Contains("armor_type"),
                    "反向验错①：故意填 坚固甲 → 校验必须 FAIL");

                var badTower = CloneDict(unitsDict);
                var badTowerList = JVal.List(badTower, "units");
                if (badTowerList != null)
                {
                    foreach (object o in badTowerList)
                    {
                        var ud = JVal.AsDict(o);
                        if (ud != null && JVal.Str(ud, "id", "") == "watchtower_bolt")
                            ud["base_damage"] = new List<object> { 1.0, 2.0, 3.0 };
                    }
                }
                var badTowerCatalog = UnitCatalog.FromDict(badTower, rules, new List<string>());
                var badTowerErrors = badTowerCatalog.Validate();
                report.Expect(badTowerErrors.Count > 0 &&
                              string.Join(";", badTowerErrors).Contains("base_damage"),
                    "反向验错②：static 塔填非零 base_damage → 校验必须 FAIL");
                // 反向验错③ 已在上面的「强行落子返回失败」里（列顺序）。
            }

            return report;
        }

        // =================================================================
        // 工具
        // =================================================================
        private static int FindTileInOtherColumn(BoardSession board, int col)
        {
            foreach (TacticalTile t in board.Arena.Tiles)
            {
                if (board.Arena.ColumnOf(t.Index) != col && !board.OccupiedTiles().Contains(t.Index))
                    return t.Index;
            }
            return 0;
        }

        private static int FindAnyOccupiedInColumn(BoardSession board, int col)
        {
            foreach (BoardBuilding b in board.Buildings)
            {
                if (board.Arena.ColumnOf(b.Tile) != col) continue;
                if (string.Equals(b.DefId, "keep", StringComparison.Ordinal)) continue;
                return b.Tile;
            }
            return 0;
        }

        private static IDictionary<string, object> MakeMergeLayout(IDictionary<string, object> shell)
        {
            _ = shell;
            var layout = new Dictionary<string, object>(StringComparer.Ordinal);
            layout["active_tiles"] = new List<object> { 1.0, 2.0, 3.0, 4.0 };
            layout["slots"] = new List<object>
            {
                Slot(1, "keep", 1),
                Slot(2, "barracks", 1),
                Slot(3, "barracks", 1),
                Slot(4, "barracks", 1),
            };
            return layout;
        }

        private static IDictionary<string, object> Slot(int tile, string building, int star)
        {
            return new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["tile"] = (double)tile,
                ["building"] = building,
                ["star"] = (double)star,
            };
        }

        private static bool CardsHaveKey(IDictionary<string, object> planning, string key)
        {
            var cards = JVal.List(planning, "cards");
            if (cards == null) return false;
            foreach (object o in cards)
            {
                var cd = JVal.AsDict(o);
                if (cd != null && cd.ContainsKey(key)) return true;
            }
            return false;
        }

        private static bool AllTrainCardsHave(IDictionary<string, object> planning, string key)
        {
            var cards = JVal.List(planning, "cards");
            if (cards == null) return false;
            foreach (object o in cards)
            {
                var cd = JVal.AsDict(o);
                if (cd == null) continue;
                if (JVal.Str(cd, "kind", "") != "train") continue;
                if (!cd.ContainsKey(key)) return false;
            }
            return true;
        }

        /// <summary>原始 levels.json 的 rounds[] 里是否还残留某个 key（例如 kind）。</summary>
        private static bool LevelsRoundsHaveKey(IDictionary<string, object> levels, string key)
        {
            var list = JVal.List(levels, "levels");
            if (list == null) return false;
            foreach (object o in list)
            {
                var ld = JVal.AsDict(o);
                if (ld == null) continue;
                var rounds = JVal.List(ld, "rounds");
                if (rounds == null) continue;
                foreach (object ro in rounds)
                {
                    var rd = JVal.AsDict(ro);
                    if (rd != null && rd.ContainsKey(key)) return true;
                }
            }
            return false;
        }

        private static bool ContainsKey(object node, string key)
        {
            if (node is IDictionary<string, object> d)
            {
                foreach (var kv in d)
                {
                    if (kv.Key == key) return true;
                    if (ContainsKey(kv.Value, key)) return true;
                }
                return false;
            }
            if (node is List<object> list)
            {
                foreach (object o in list)
                    if (ContainsKey(o, key)) return true;
            }
            return false;
        }

        private static bool ContainsString(object node, string needle)
        {
            if (node is string s) return s.Contains(needle, StringComparison.Ordinal);
            if (node is IDictionary<string, object> d)
            {
                foreach (var kv in d)
                {
                    if (kv.Key.Contains(needle, StringComparison.Ordinal)) return true;
                    if (ContainsString(kv.Value, needle)) return true;
                }
                return false;
            }
            if (node is List<object> list)
            {
                foreach (object o in list)
                    if (ContainsString(o, needle)) return true;
            }
            return false;
        }

        /// <summary>只扫 armor_type / attack_type 的**取值**，不误伤说明文字。</summary>
        private static bool HasLegacyTypeValue(object node)
        {
            if (node is IDictionary<string, object> d)
            {
                foreach (var kv in d)
                {
                    if ((kv.Key == "armor_type" || kv.Key == "attack_type") && kv.Value is string s)
                    {
                        if (s == "坚固甲" || s == "神圣甲" || s == "混乱" || s == "神力") return true;
                    }
                    if (HasLegacyTypeValue(kv.Value)) return true;
                }
                return false;
            }
            if (node is List<object> list)
            {
                foreach (object o in list)
                    if (HasLegacyTypeValue(o)) return true;
            }
            return false;
        }

        private static IDictionary<string, object> CloneDict(IDictionary<string, object> src)
        {
            var dst = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var kv in src) dst[kv.Key] = CloneNode(kv.Value);
            return dst;
        }

        private static object CloneNode(object node)
        {
            if (node is IDictionary<string, object> d)
            {
                var copy = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (var kv in d) copy[kv.Key] = CloneNode(kv.Value);
                return copy;
            }
            if (node is List<object> list)
            {
                var copy = new List<object>();
                foreach (object o in list) copy.Add(CloneNode(o));
                return copy;
            }
            return node;
        }
    }
}
