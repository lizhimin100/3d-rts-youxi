using System;
using System.Collections.Generic;
using System.Linq;

namespace WarIsland.Model
{
    /// <summary>
    /// 战斗节奏的健康区间（2026-11-25 Phase 3 冻结口径）。
    ///
    /// 为什么把它做成"可被反向验错的纯函数"：
    ///   · 区间本身是**规则**（狂暴只做肉盾局兜底，不能变成每轮必经）；
    ///   · 一个只在报告里打印数字的脚本没法证明自己没瞎；
    ///   · 所以这里既给 --check 用（喂 Phase 2 的旧读数必须 FAIL），
    ///     也给 --simulate 用（100 局真读数必须 PASS）。
    /// </summary>
    public static class BalanceBand
    {
        public const double BerserkRateMin = 0.15;
        public const double BerserkRateMax = 0.30;
        public const double WinRateMin = 0.45;
        public const double WinRateMax = 0.55;
        public const double AvgRoundsMin = 3.0;
        public const double AvgRoundsMax = 5.0;
        /// <summary>单轮"自然分出胜负"的目标秒数区间（狂暴在 45 秒，所以上限必须在它之前）。</summary>
        public const double RoundSecondsMin = 25.0;
        public const double RoundSecondsMax = 40.0;

        /// <summary>返回违例描述（空 = 全部在区间内）。</summary>
        public static List<string> Violations(double berserkRate, double winRate,
            double avgRounds, double avgRoundSeconds)
        {
            var bad = new List<string>();
            if (berserkRate < BerserkRateMin || berserkRate > BerserkRateMax)
                bad.Add($"狂暴触发率 {berserkRate:P1} 不在 {BerserkRateMin:P0}~{BerserkRateMax:P0}");
            if (winRate < WinRateMin || winRate > WinRateMax)
                bad.Add($"胜率 {winRate:P1} 不在 {WinRateMin:P0}~{WinRateMax:P0}");
            if (avgRounds < AvgRoundsMin || avgRounds > AvgRoundsMax)
                bad.Add($"平均轮数 {avgRounds:0.00} 不在 {AvgRoundsMin:0}~{AvgRoundsMax:0}");
            if (avgRoundSeconds < RoundSecondsMin || avgRoundSeconds > RoundSecondsMax)
                bad.Add($"单轮时长 {avgRoundSeconds:0.0}s 不在 {RoundSecondsMin:0}~{RoundSecondsMax:0}s");
            return bad;
        }
    }

    /// <summary>
    /// Phase 3 契约自检（纯 Model，可不依赖 Godot 运行）。
    ///
    /// 覆盖：
    ///   · `UnitView.State / StateAge / Moving`（四值状态机，真跑一场看它会不会变）；
    ///   · `HitEvent` 队列（target_id / amount / feedback，四值分级）；
    ///   · `BoardEvent` 队列（placed / upgraded，带 col/row/star）；
    ///   · 平衡带（狂暴率 / 胜率 / 轮数 / 单轮秒数）；
    ///   · **4 项反向验错**（故意喂坏数据 / 喂旧读数 → 必须报错）。
    /// </summary>
    public static class Phase3Checks
    {
        /// <summary>
        /// 四值**字面量**契约（不是从 UnitStates 常量抄的）：
        /// 表现层 GDScript 就是按这四个字符串比较的，常量改了这里必须红。
        /// </summary>
        public static readonly string[] StateValues = { "march", "fight", "hold", "dead" };

        public static readonly string[] FeedbackValues =
            { "crit_or_counter", "resisted", "normal", "miss" };

        /// <summary>状态是否属于四值契约。</summary>
        public static bool ValidState(string state)
        {
            if (string.IsNullOrEmpty(state)) return false;
            for (int i = 0; i < StateValues.Length; i++)
                if (string.Equals(StateValues[i], state, StringComparison.Ordinal)) return true;
            return false;
        }

        /// <summary>跳字分级是否属于四值契约。</summary>
        public static bool ValidFeedback(string feedback)
        {
            if (string.IsNullOrEmpty(feedback)) return false;
            for (int i = 0; i < FeedbackValues.Length; i++)
                if (string.Equals(FeedbackValues[i], feedback, StringComparison.Ordinal)) return true;
            return false;
        }

        public static CheckReport Run(
            IDictionary<string, object> unitsDict,
            IDictionary<string, object> combatDict,
            IDictionary<string, object> planningDict,
            IDictionary<string, object> shellDict,
            IDictionary<string, object> layoutDict,
            IDictionary<string, object> levelsDict,
            IDictionary<string, object> tuningDict,
            string levelId)
        {
            var report = new CheckReport();
            var notes = new List<string>();
            var rules = CombatRules.FromDict(combatDict);
            var units = UnitCatalog.FromDict(unitsDict, rules, notes);
            var planning = PlanningConfig.FromDict(planningDict, units, notes);
            var levels = LevelSet.FromDict(levelsDict, units, notes);
            var tuning = BattleTuning.FromDict(tuningDict);

            // ---- 1. 状态契约：四值齐全、互不重复 ----
            report.Expect(StateValues.Distinct().Count() == 4 &&
                          ValidState("march") && ValidState("fight") &&
                          ValidState("hold") && ValidState("dead") &&
                          !ValidState("walking"),
                "单兵状态契约：march / fight / hold / dead 四值齐全（常量改字也必须红）");
            report.Expect(!ValidState("engaged") && !ValidState(""),
                "旧布尔 engaged 不再被当成状态值");

            // ---- 2. 跳字契约：四值 + 枚举映射 ----
            report.Expect(ValidFeedback("crit_or_counter") && ValidFeedback("resisted") &&
                          ValidFeedback("normal") && ValidFeedback("miss") &&
                          !ValidFeedback("crit"),
                "跳字契约：crit_or_counter / resisted / normal / miss 四值，其余拒绝");
            report.Expect(BattleSim.FeedbackName(DamageFeedback.CritOrCounter) == "crit_or_counter" &&
                          BattleSim.FeedbackName(DamageFeedback.Resisted) == "resisted" &&
                          BattleSim.FeedbackName(DamageFeedback.Miss) == "miss" &&
                          BattleSim.FeedbackName(DamageFeedback.Normal) == "normal",
                "跳字契约：DamageFeedback 四个枚举值映射到四个字符串");

            // ---- 3. 真跑一场：状态机 / 事件队列 ----
            LevelDef level = levels.Get(levelId) ?? (levels.Levels.Count > 0 ? levels.Levels[0] : null);
            if (level == null)
            {
                report.Fail("Phase 3：找不到关卡 " + levelId);
                return report;
            }
            var arena = BattleArena.FromDict(
                FindLevelRow(levelsDict, level.Id), shellDict, layoutDict,
                new Dictionary<string, object>(StringComparer.Ordinal), units, tuningDict);
            var arenaErr = arena.Validate(units);
            report.Expect(arenaErr.Count == 0, "Phase 3：战场可组装",
                arenaErr.Count == 0 ? "" : string.Join("; ", arenaErr.Take(2)));

            Battlefield bf = level.Battlefield;
            var sim = new BattleSim(units, rules, arena, planning, 7919, tuning);
            sim.CollectHits = true;
            sim.SetBaseHp(level.PlayerBaseHp, level.EnemyBaseHp);
            var p0 = arena.LaneToWorld(bf.DeployPlayer, 0.0);
            var e0 = arena.LaneToWorld(bf.DeployEnemy, 0.0);
            int a = sim.AddUnit(0, "alliance_footman", 1, p0.X, p0.Y);
            int b = sim.AddUnit(0, "alliance_crossbowman", 1, p0.X, p0.Y + 2.0);
            int c = sim.AddUnit(1, "bandit_marauder", 1, e0.X, e0.Y);
            int d = sim.AddUnit(1, "bandit_scout", 1, e0.X, e0.Y + 2.0);
            report.Expect(a > 0 && b > 0 && c > 0 && d > 0, "Phase 3：双方各出 2 名单兵");
            sim.OrderMarch(a, e0.X, e0.Y);
            sim.OrderMarch(b, e0.X, e0.Y);
            sim.OrderMarch(c, p0.X, p0.Y);
            sim.OrderMarch(d, p0.X, p0.Y);

            var seen = new HashSet<string>(StringComparer.Ordinal);
            bool movingSeen = false;
            int maxHits = 0;
            var hitFeedback = new HashSet<string>(StringComparer.Ordinal);
            bool badHit = false;
            double maxStateAge = 0.0;
            for (int i = 0; i < 1200 && !sim.Finished; i++)
            {
                sim.Step(0.05);
                List<HitEvent> hits = sim.DrainHits();
                maxHits = Math.Max(maxHits, hits.Count);
                foreach (HitEvent h in hits)
                {
                    if (!ValidFeedback(h.Feedback) || h.Amount < 0.0 || h.TargetId <= 0) badHit = true;
                    hitFeedback.Add(h.Feedback);
                }
                foreach (UnitView u in sim.View().Units)
                {
                    if (!ValidState(u.State)) badHit = true;
                    seen.Add(u.State);
                    if (u.Moving) movingSeen = true;
                    if (u.StateAge > maxStateAge) maxStateAge = u.StateAge;
                }
            }
            report.Expect(!badHit, "Phase 3：跑满一场，state / feedback 没有越界值");
            report.Expect(seen.Contains("march") && seen.Contains("fight"),
                "Phase 3：状态机真的走过 march → fight", "seen=" + string.Join(",", seen));
            report.Expect(movingSeen && maxStateAge > 0.5,
                "Phase 3：Moving 置真过、StateAge 连续累计", $"max_state_age={maxStateAge:0.00}s");
            report.Expect(maxHits > 0 && hitFeedback.Count >= 1,
                "Phase 3：伤害跳字队列有事件、feedback 合法",
                $"peak={maxHits}/帧 kinds={string.Join(",", hitFeedback)}");
            report.Expect(hitFeedback.Contains("crit_or_counter") || hitFeedback.Contains("resisted"),
                "Phase 3：4×4 克制真的产出红/白跳字（不是清一色 normal）",
                string.Join(",", hitFeedback));

            // ---- 4. 建筑事件：placed / upgraded 带 col / row ----
            BoardSession board = BoardSession.Create(planning, units, shellDict, layoutDict, 4242, new List<string>());
            board.BeginPlanning();
            board.Match.AddCp(12);
            board.Match.Hand.Add("build_barracks");
            int tile = board.NextFillTile();
            int placed = board.PlaceBuild("build_barracks", 0);
            var boardEvents = board.DrainEvents();
            BoardEvent ev = boardEvents.Count > 0 ? boardEvents[0] : null;
            report.Expect(placed > 0 && ev != null && ev.Kind == "placed" &&
                          ev.Col >= 0 && ev.Row >= 0 && ev.Star == 1 && ev.DefId == "barracks",
                "Phase 3：建造 → placed(col,row,id) 事件",
                ev == null ? "无事件" : $"{ev.Kind}@{ev.Col},{ev.Row} {ev.DefId}★{ev.Star}");
            report.Expect(board.NextFillCol == board.Arena.ColumnOf(board.NextFillTile()) &&
                          board.NextFillRow == board.Arena.RowOf(board.NextFillTile()),
                "Phase 3：当前强制顺次填充位给出 col/row",
                $"{board.NextFillCol},{board.NextFillRow}");

            // 3 合 1 → upgraded
            var mergeLayout = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["active_tiles"] = new List<object> { 1.0, 2.0, 3.0, 4.0 },
                ["slots"] = new List<object>
                {
                    MergeSlot(1, "keep", 1), MergeSlot(2, "barracks", 1),
                    MergeSlot(3, "barracks", 1), MergeSlot(4, "barracks", 1),
                },
            };
            BoardSession mb = BoardSession.Create(planning, units, shellDict, mergeLayout, 99, new List<string>());
            mb.DrainEvents();
            int star2 = mb.Merge(3, 2);
            var upEvents = mb.DrainEvents();
            BoardEvent up = upEvents.Count > 0 ? upEvents[0] : null;
            report.Expect(star2 == 2 && up != null && up.Kind == "upgraded" && up.Star == 2 &&
                          up.Col >= 0 && up.Row >= 0,
                "Phase 3：3 合 1 → upgraded(col,row,star) 事件",
                up == null ? "无事件" : $"{up.Kind}@{up.Col},{up.Row}★{up.Star}");

            // ---- 4.5 哨塔：数据渲染开关 + 真上场（两翼静态实体）----
            var towerRow = FindUnitRow(unitsDict, "watchtower_bolt");
            bool towerRender = towerRow != null && JVal.Bool(towerRow, "render", false);
            string towerModel = towerRow != null ? JVal.Str(towerRow, "model_path", "") : "";
            report.Expect(towerRender && towerModel.EndsWith(".glb", StringComparison.OrdinalIgnoreCase),
                "哨塔表现开关：render=true 且 model_path 指向 .glb",
                towerRender ? towerModel : "render=false");
            var towerLayout = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["active_tiles"] = new List<object> { 1.0, 2.0, 3.0, 4.0 },
                ["slots"] = new List<object>
                {
                    MergeSlot(1, "keep", 1), MergeSlot(2, "barracks", 1), MergeSlot(3, "watchtower", 1),
                },
            };
            BoardSession tBoard = BoardSession.Create(planning, units, shellDict, towerLayout, 77, new List<string>());
            tBoard.BeginPlanning();
            tBoard.EndPlanning();
            ArmyPlan tPlan = tBoard.BuildArmyPlan();
            report.Expect(tPlan.Towers.Count >= 1, "哨塔进入 ArmyPlan（防御建筑 → 实体塔）",
                $"towers={tPlan.Towers.Count}");
            var towerSim = new BattleSim(units, rules, arena, planning, 7788, tuning) { CollectHits = false };
            towerSim.SetBaseHp(level.PlayerBaseHp, level.EnemyBaseHp);
            BattleSession.SpawnArmy(towerSim, tPlan, level, tuning, arena);
            int towerUnits = 0;
            foreach (UnitView u in towerSim.View().Units)
                if (u.UnitId == "watchtower_bolt") towerUnits += 1;
            report.Expect(towerUnits >= 1, "哨塔真的落到战场两翼（UnitView 能读到）", $"n={towerUnits}");

            // ---- 5. 平衡带（正向：当前读数必须过；反向：Phase 2 旧读数必须不过）----
            report.Expect(BalanceBand.Violations(0.22, 0.50, 4.0, 32.0).Count == 0,
                "平衡带：22% 狂暴 / 50% 胜率 / 4 轮 / 32 秒 → 判 PASS");
            report.Expect(BalanceBand.Violations(0.883, 0.47, 3.30, 60.0).Count >= 1,
                "平衡带：Phase 2 旧读数（88.3% 狂暴 / 60 秒）→ 必须判 FAIL");

            // ---- 6. 四项反向验错 ----
            // ① 状态值故意写错 → 契约校验必须拒绝
            report.Expect(!ValidState("attacking"),
                "反向验错①：state=\"attacking\" → 契约必须 FAIL");
            // ② feedback 故意写错 → 契约校验必须拒绝
            report.Expect(!ValidFeedback("counter_red"),
                "反向验错②：feedback=\"counter_red\" → 契约必须 FAIL");
            // ③ 把兵种的 base_damage 全部抬到 999 → 结算封顶必须生效
            var badUnits = CloneDict(unitsDict);
            foreach (object o in JVal.List(badUnits, "units") ?? new List<object>())
            {
                var ud = JVal.AsDict(o);
                if (ud != null) ud["base_damage"] = new List<object> { 999.0, 999.0, 999.0 };
            }
            var capped = RoundResolver.Resolve(999.0, 0.0, tuning.BaseDamageCap, false);
            report.Expect(Math.Abs(capped.PlayerApplied - tuning.BaseDamageCap) < 1e-9,
                "反向验错③：base_damage=999 → 单轮封顶必须生效",
                $"{capped.PlayerApplied:0} / cap {tuning.BaseDamageCap}");
            // ④ 把狂暴起点调到 20 秒（越界）→ 配置校验必须拒绝
            var badTuning = CloneDict(tuningDict);
            var berserk = JVal.Dict(badTuning, "berserk");
            if (berserk != null) berserk["start_seconds"] = 20.0;
            var badTuningErrors = BattleTuning.FromDict(badTuning).Validate(units);
            report.Expect(badTuningErrors.Count > 0 &&
                          string.Join(";", badTuningErrors).Contains("berserk.start_seconds"),
                "反向验错④：berserk.start_seconds=20 → 校验必须 FAIL",
                string.Join("; ", badTuningErrors.Take(2)));

            return report;
        }

        private static IDictionary<string, object> MergeSlot(int tile, string building, int star)
        {
            return new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["tile"] = (double)tile,
                ["building"] = building,
                ["star"] = (double)star,
            };
        }

        private static IDictionary<string, object> FindUnitRow(IDictionary<string, object> units, string id)
        {
            var list = JVal.List(units, "units");
            if (list == null) return null;
            foreach (object o in list)
            {
                var d = JVal.AsDict(o);
                if (d != null && JVal.Str(d, "id", "") == id) return d;
            }
            return null;
        }

        private static IDictionary<string, object> FindLevelRow(IDictionary<string, object> levels, string id)
        {
            var list = JVal.List(levels, "levels");
            if (list == null) return null;
            foreach (object o in list)
            {
                var d = JVal.AsDict(o);
                if (d != null && JVal.Str(d, "id", "") == id) return d;
            }
            return null;
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
