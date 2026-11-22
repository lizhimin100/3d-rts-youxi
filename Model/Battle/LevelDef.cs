using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>横道几何与基地抽血规则（全部是游戏数值，落世界时乘 R1）。</summary>
    public sealed class LaneConfig
    {
        public double Length = 4000.0;
        public double Width = 420.0;
        public double ZoneDepth = 600.0;
        public double ZoneDpsPerSquad = 9.0;
        public double SpawnOffset = 250.0;
        public double BaseStop = 120.0;

        public double HalfWidth => Width * 0.5;
        public double PlayerSpawnX => SpawnOffset;
        public double EnemySpawnX => Length - SpawnOffset;
        public double PlayerZoneEnd => ZoneDepth;
        public double EnemyZoneStart => Length - ZoneDepth;
    }

    public sealed class WaveSquad
    {
        public string Unit = "";
        public int Count = 1;
        public int Star = 1;
    }

    public sealed class Wave
    {
        public double T;
        public readonly List<WaveSquad> Squads = new List<WaveSquad>();
    }

    public sealed class LevelRound
    {
        public string Kind = "";
        public string Label = "";
        public readonly List<Wave> Waves = new List<Wave>();
    }

    /// <summary>一关：两轮各 60 秒，基地血量跨轮保留。</summary>
    public sealed class LevelDef
    {
        public string Id = "";
        public string DisplayName = "";
        public string PlayerFaction = "";
        public string EnemyFaction = "";
        public double PlayerBaseHp = 2600.0;
        public double EnemyBaseHp = 2000.0;
        /// <summary>
        /// **单场限时（秒）的唯一真源**。2026-11-21 从 90 收到 60：
        /// 规划阶段无限时 + 执行 60 秒攻防双场，一局 3~5 分钟。
        /// 想改时长只改这里（+ levels.json 的 round_seconds），别在 GDScript 里写第二份。
        /// </summary>
        public const double RoundSecondsSpec = 60.0;

        public double RoundSeconds = RoundSecondsSpec;
        public LaneConfig Lane = new LaneConfig();
        public readonly List<LevelRound> Rounds = new List<LevelRound>();

        public static LevelDef FromDict(IDictionary<string, object> d, UnitCatalog units, List<string> notes)
        {
            var lv = new LevelDef();
            if (d == null)
            {
                notes.Add("关卡配置为空");
                return lv;
            }
            lv.Id = JVal.Str(d, "id", "");
            lv.DisplayName = JVal.Str(d, "display_name", "");
            lv.PlayerFaction = JVal.Str(d, "player_faction", "");
            lv.EnemyFaction = JVal.Str(d, "enemy_faction", "");
            lv.PlayerBaseHp = JVal.Double(d, "player_base_hp", lv.PlayerBaseHp);
            lv.EnemyBaseHp = JVal.Double(d, "enemy_base_hp", lv.EnemyBaseHp);
            lv.RoundSeconds = JVal.Double(d, "round_seconds", lv.RoundSeconds);

            var lane = JVal.Dict(d, "lane");
            if (lane != null)
            {
                lv.Lane.Length = JVal.Double(lane, "length", lv.Lane.Length);
                lv.Lane.Width = JVal.Double(lane, "width", lv.Lane.Width);
                lv.Lane.ZoneDepth = JVal.Double(lane, "zone_depth", lv.Lane.ZoneDepth);
                lv.Lane.ZoneDpsPerSquad = JVal.Double(lane, "zone_dps_per_squad", lv.Lane.ZoneDpsPerSquad);
                lv.Lane.SpawnOffset = JVal.Double(lane, "spawn_offset", lv.Lane.SpawnOffset);
                lv.Lane.BaseStop = JVal.Double(lane, "base_stop", lv.Lane.BaseStop);
            }
            else notes.Add("关卡缺 lane");

            var rounds = JVal.List(d, "rounds");
            if (rounds == null)
            {
                notes.Add("关卡缺 rounds");
                return lv;
            }
            foreach (var item in rounds)
            {
                var rd = JVal.AsDict(item);
                if (rd == null) continue;
                var round = new LevelRound
                {
                    Kind = JVal.Str(rd, "kind", ""),
                    Label = JVal.Str(rd, "label", ""),
                };
                var waves = JVal.List(rd, "enemy_waves");
                if (waves != null)
                {
                    foreach (var w in waves)
                    {
                        var wd = JVal.AsDict(w);
                        if (wd == null) continue;
                        var wave = new Wave { T = JVal.Double(wd, "t", 0.0) };
                        var squads = JVal.List(wd, "squads");
                        if (squads != null)
                        {
                            foreach (var sq in squads)
                            {
                                var sd = JVal.AsDict(sq);
                                if (sd == null) continue;
                                wave.Squads.Add(new WaveSquad
                                {
                                    Unit = JVal.Str(sd, "unit", ""),
                                    Count = JVal.Int(sd, "count", 1),
                                    Star = JVal.Int(sd, "star", 1),
                                });
                            }
                        }
                        round.Waves.Add(wave);
                    }
                }
                round.Waves.Sort((a, b) => a.T.CompareTo(b.T));
                lv.Rounds.Add(round);
            }
            _ = units;
            return lv;
        }

        public List<string> Validate(UnitCatalog units)
        {
            var errors = new List<string>();
            if (string.IsNullOrEmpty(Id)) errors.Add("关卡缺 id");
            if (string.IsNullOrEmpty(DisplayName)) errors.Add($"关卡 {Id} 缺 display_name");
            if (units == null)
            {
                errors.Add("关卡校验缺 UnitCatalog");
                return errors;
            }
            if (units.GetFaction(PlayerFaction) == null)
                errors.Add($"关卡 {Id}：player_faction={PlayerFaction} 未定义");
            if (units.GetFaction(EnemyFaction) == null)
                errors.Add($"关卡 {Id}：enemy_faction={EnemyFaction} 未定义");

            if (PlayerBaseHp <= 0.0 || EnemyBaseHp <= 0.0)
                errors.Add($"关卡 {Id}：基地血量必须 > 0");
            if (RoundSeconds <= 0.0)
                errors.Add($"关卡 {Id}：round_seconds 必须 > 0");

            var lane = Lane;
            if (lane.Length <= lane.ZoneDepth * 2.0)
                errors.Add($"关卡 {Id}：lane.length 必须大于两倍 zone_depth");
            if (lane.Width <= 0.0 || lane.ZoneDepth <= 0.0)
                errors.Add($"关卡 {Id}：lane 宽/敌区必须 > 0");
            if (lane.ZoneDpsPerSquad <= 0.0)
                errors.Add($"关卡 {Id}：zone_dps_per_squad 必须 > 0");
            if (lane.SpawnOffset <= 0.0 || lane.SpawnOffset >= lane.Length * 0.5)
                errors.Add($"关卡 {Id}：spawn_offset={lane.SpawnOffset} 越界");
            if (lane.BaseStop <= 0.0 || lane.BaseStop >= lane.ZoneDepth)
                errors.Add($"关卡 {Id}：base_stop={lane.BaseStop} 必须在 (0, zone_depth)");

            if (Rounds.Count != 2)
                errors.Add($"关卡 {Id}：必须是两轮（进攻 + 防守），现在 {Rounds.Count} 轮");
            else
            {
                if (Rounds[0].Kind != "attack")
                    errors.Add($"关卡 {Id}：第 1 轮必须是 attack");
                if (Rounds[1].Kind != "defend")
                    errors.Add($"关卡 {Id}：第 2 轮必须是 defend");
            }
            if (Math.Abs(RoundSeconds - RoundSecondsSpec) > 1e-9)
                errors.Add($"关卡 {Id}：round_seconds={RoundSeconds}，规格是 {RoundSecondsSpec:0} 秒");

            foreach (var round in Rounds)
            {
                if (round.Waves.Count == 0)
                    errors.Add($"关卡 {Id} 的 {round.Kind} 轮没有波次");
                foreach (var wave in round.Waves)
                {
                    if (wave.T < 0.0 || wave.T > RoundSeconds)
                        errors.Add($"关卡 {Id} 的 {round.Kind} 轮有波次时间 {wave.T} 越界");
                    if (wave.Squads.Count == 0)
                        errors.Add($"关卡 {Id} 的 {round.Kind} 轮 t={wave.T} 是空波次");
                    foreach (var sq in wave.Squads)
                    {
                        var u = units.Get(sq.Unit);
                        if (u == null)
                        {
                            errors.Add($"关卡 {Id} 波次 → 未定义单位 {sq.Unit}");
                            continue;
                        }
                        if (!u.Enabled)
                            errors.Add($"关卡 {Id} 波次 → 单位 {sq.Unit} 已禁用（enabled=false）");
                        if (u.Faction != EnemyFaction)
                            errors.Add($"关卡 {Id} 波次 → {sq.Unit} 不属于敌方阵营 {EnemyFaction}");
                        if (sq.Count < 1 || sq.Count > 24)
                            errors.Add($"关卡 {Id} 波次 → {sq.Unit} count={sq.Count} 越界（1..24 名单兵）");
                        if (sq.Star < 1 || sq.Star > 3)
                            errors.Add($"关卡 {Id} 波次 → {sq.Unit} star={sq.Star} 越界（1..3）");
                    }
                }
            }
            return errors;
        }
    }

    /// <summary>levels.json 的装载。</summary>
    public sealed class LevelSet
    {
        public readonly List<LevelDef> Levels = new List<LevelDef>();

        public LevelDef Get(string id)
        {
            foreach (var lv in Levels)
            {
                if (lv.Id == id) return lv;
            }
            return null;
        }

        public static LevelSet FromDict(IDictionary<string, object> d, UnitCatalog units, List<string> notes)
        {
            var set = new LevelSet();
            if (d == null)
            {
                notes.Add("levels 配置为空");
                return set;
            }
            var list = JVal.List(d, "levels");
            if (list == null)
            {
                notes.Add("缺少 levels 数组");
                return set;
            }
            foreach (var item in list)
            {
                var ld = JVal.AsDict(item);
                if (ld == null) continue;
                set.Levels.Add(LevelDef.FromDict(ld, units, notes));
            }
            return set;
        }

        public List<string> Validate(UnitCatalog units)
        {
            var errors = new List<string>();
            if (Levels.Count == 0) errors.Add("levels 为空");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var lv in Levels)
            {
                if (!seen.Add(lv.Id)) errors.Add($"关卡 id 重复：{lv.Id}");
                errors.AddRange(lv.Validate(units));
            }
            return errors;
        }
    }
}
