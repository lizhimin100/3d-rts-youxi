using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>阵营（联盟 / 豺狼人 / 鱼人）。</summary>
    public sealed class FactionDef
    {
        public string Id = "";
        public string DisplayName = "";
        public bool UsePlaceholderMesh;
        public string Note = "";
    }

    /// <summary>一个兵种（卡面数值，不是场上实例）。</summary>
    public sealed class UnitDef
    {
        public string Id = "";
        public string DisplayName = "";
        public string Faction = "";
        public bool Enabled = true;

        /// <summary>一队几个模型。</summary>
        public int SquadSize = 1;

        public double Hp;
        public double AttackDamage;
        public double AttackCooldown = 1.0;
        public double AttackRange;
        public int AttackType;
        public double Armor;
        public int ArmorType;

        public double Hit = CombatRules.SpecHitBase;
        public double Dodge;
        public double Crit;

        public double ArmorPenFlat;
        public double ArmorPenPct;

        /// <summary>移动速度（米/秒；落到横道时由 R1 换成游戏数值/秒）。</summary>
        public double MoveSpeed;

        /// <summary>单模型体积半径（米）。</summary>
        public double BodyRadius = 0.45;

        public bool Projectile;
        public double ProjectileSpeed;

        public int PopCost;
        public string PassiveTrait = "";
        public bool UsePlaceholderMesh;
        public string Note = "";

        public bool IsMelee => AttackRange < 300.0;

        public string Role => IsMelee ? "melee" : "ranged";
    }

    /// <summary>
    /// units.json 的装载与校验。
    ///
    /// 这里只做“卡面数据对不对”，不做战斗结算；结算在 CombatCalculator。
    /// 距离字段一律是游戏数值（95 / 155 / 650 / 850），只有 move_speed / body_radius
    /// 用米（它们不是“射程类”数值，落到横道时统一乘 R1 换成游戏数值）。
    /// </summary>
    public sealed class UnitCatalog
    {
        private readonly Dictionary<string, UnitDef> _units = new Dictionary<string, UnitDef>(StringComparer.Ordinal);
        private readonly Dictionary<string, FactionDef> _factions = new Dictionary<string, FactionDef>(StringComparer.Ordinal);
        private readonly List<UnitDef> _all = new List<UnitDef>();

        public IReadOnlyList<UnitDef> All => _all;
        public IReadOnlyDictionary<string, UnitDef> Units => _units;
        public IReadOnlyDictionary<string, FactionDef> Factions => _factions;

        public UnitDef Get(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            _units.TryGetValue(id, out UnitDef def);
            return def;
        }

        public FactionDef GetFaction(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            _factions.TryGetValue(id, out FactionDef def);
            return def;
        }

        public List<UnitDef> OfFaction(string faction, bool includeDisabled = false)
        {
            var list = new List<UnitDef>();
            foreach (var u in _all)
            {
                if (u.Faction == faction && (includeDisabled || u.Enabled)) list.Add(u);
            }
            return list;
        }

        public List<string> Validate()
        {
            var errors = new List<string>();

            foreach (var kv in _factions)
            {
                if (string.IsNullOrWhiteSpace(kv.Value.DisplayName))
                    errors.Add($"阵营 {kv.Key} 缺 display_name");
            }

            if (_all.Count == 0)
            {
                errors.Add("units 为空");
                return errors;
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var u in _all)
            {
                string tag = string.IsNullOrEmpty(u.Id) ? "(空 id)" : u.Id;
                if (string.IsNullOrEmpty(u.Id))
                    errors.Add("存在没有 id 的兵种");
                else if (!IsAscii(u.Id))
                    errors.Add($"{tag}：id 必须是 ASCII（跨语言 key）");
                if (!seen.Add(u.Id))
                    errors.Add($"{tag}：id 重复");

                if (string.IsNullOrWhiteSpace(u.DisplayName))
                    errors.Add($"{tag}：display_name 为空");

                FactionDef faction = GetFaction(u.Faction);
                if (faction == null)
                {
                    errors.Add($"{tag}：faction={u.Faction} 未定义");
                }
                else if (faction.UsePlaceholderMesh && !u.UsePlaceholderMesh)
                {
                    errors.Add($"{tag}：阵营 {faction.DisplayName} 要求占位网格（use_placeholder_mesh=true）");
                }

                if (u.SquadSize < 1 || u.SquadSize > 12)
                    errors.Add($"{tag}：squad_size={u.SquadSize} 越界（1..12）");

                if (u.Hp <= 0.0)
                    errors.Add($"{tag}：hp={u.Hp} 必须 > 0");
                if (u.AttackDamage < 0.0)
                    errors.Add($"{tag}：attack_damage={u.AttackDamage} 为负");
                if (u.AttackCooldown <= 0.0)
                    errors.Add($"{tag}：attack_cooldown={u.AttackCooldown} 必须 > 0");

                // 距离：游戏数值；至少 10，最多 30 米（2000 游戏数值）
                if (u.AttackRange < 10.0 || RtsUnits.ToMeters(u.AttackRange) > 30.0)
                    errors.Add($"{tag}：attack_range={u.AttackRange} 不是合法游戏数值（10..2000）");
                if (Math.Abs(u.AttackRange - Math.Round(u.AttackRange)) > 1e-9)
                    errors.Add($"{tag}：attack_range={u.AttackRange} 必须是整数游戏数值");

                if (!CombatTypes.IsValidAttack(u.AttackType))
                    errors.Add($"{tag}：attack_type 非法（只允许 普通/穿刺/魔法/攻城/混乱/神力）");
                if (!CombatTypes.IsValidArmor(u.ArmorType))
                    errors.Add($"{tag}：armor_type 非法（只允许 无甲/轻甲/中甲/重甲/坚固甲/神圣甲）");

                if (u.Armor < 0.0 || u.Armor > 100.0)
                    errors.Add($"{tag}：armor={u.Armor} 越界（0..100）");
                if (u.Hit < 0.0 || u.Hit > 200.0)
                    errors.Add($"{tag}：hit={u.Hit} 越界（0..200）");
                if (u.Dodge < 0.0 || u.Dodge > 100.0)
                    errors.Add($"{tag}：dodge={u.Dodge} 越界（0..100）");
                if (u.Crit < 0.0 || u.Crit > 1.0)
                    errors.Add($"{tag}：crit={u.Crit} 越界（0..1）");

                if (u.ArmorPenFlat < 0.0)
                    errors.Add($"{tag}：armor_pen_flat={u.ArmorPenFlat} 为负");
                if (u.ArmorPenPct < 0.0 || u.ArmorPenPct > 1.0)
                    errors.Add($"{tag}：armor_pen_pct={u.ArmorPenPct} 越界（0..1）");

                if (u.MoveSpeed <= 0.0 || u.MoveSpeed > 10.0)
                    errors.Add($"{tag}：move_speed={u.MoveSpeed} 越界（0..10 米/秒）");
                if (u.BodyRadius <= 0.0 || u.BodyRadius > 2.0)
                    errors.Add($"{tag}：body_radius={u.BodyRadius} 越界（0..2 米）");

                // 近战无投射物、远程必须生成投射物
                if (u.IsMelee && u.Projectile)
                    errors.Add($"{tag}：近战（{u.AttackRange}）不该有投射物");
                if (!u.IsMelee && !u.Projectile)
                    errors.Add($"{tag}：远程（{u.AttackRange}）必须 projectile=true");
                if (u.Projectile && u.ProjectileSpeed <= 0.0)
                    errors.Add($"{tag}：远程投射物速度必须 > 0");

                if (u.PopCost < 1 || u.PopCost > 12)
                    errors.Add($"{tag}：pop_cost={u.PopCost} 越界（1..12）");

                // 主动技能已取消；最多预留 1 个自动触发的 passive_trait，当前一律留空
                if (!string.IsNullOrEmpty(u.PassiveTrait))
                    errors.Add($"{tag}：passive_trait={u.PassiveTrait} 尚未实现（当前必须为 null）");

                if (!u.Enabled && u.SquadSize <= 0)
                    errors.Add($"{tag}：enabled=false 也要保留合法 squad_size");
            }
            return errors;
        }

        public CombatAttacker MakeAttacker(UnitDef u, double starAttackMult = 1.0, double attackMult = 1.0,
            double critAdd = 0.0, double hitAdd = 0.0)
        {
            return new CombatAttacker
            {
                Damage = u.AttackDamage * (starAttackMult > 0.0 ? starAttackMult : 1.0),
                Cooldown = u.AttackCooldown,
                AttackType = u.AttackType,
                Hit = u.Hit + hitAdd,
                CritChance = u.Crit + critAdd,
                CritMultiplier = 0.0,
                ArmorPenFlat = u.ArmorPenFlat,
                ArmorPenPct = u.ArmorPenPct,
                AttackMult = attackMult,
            };
        }

        public CombatDefender MakeDefender(UnitDef u, double armorMult = 1.0, double damageTakenMult = 1.0)
        {
            return new CombatDefender
            {
                Armor = u.Armor,
                ArmorType = u.ArmorType,
                Dodge = u.Dodge,
                ArmorMult = armorMult,
                DamageTakenMult = damageTakenMult,
            };
        }

        /// <summary>卡面期望 DPS（同星级、无策略加成）。</summary>
        public double ExpectedDps(string attackerId, string defenderId, CombatRules rules, double starAttackMult = 1.0)
        {
            UnitDef a = Get(attackerId);
            UnitDef d = Get(defenderId);
            if (a == null || d == null || rules == null) return 0.0;
            var atk = MakeAttacker(a, starAttackMult);
            var def = MakeDefender(d);
            return CombatCalculator.ExpectedDps(atk, def, rules);
        }

        public double ExpectedDpsVsArmor(string attackerId, double armor, int armorType, CombatRules rules,
            double starAttackMult = 1.0)
        {
            UnitDef a = Get(attackerId);
            if (a == null || rules == null) return 0.0;
            var atk = MakeAttacker(a, starAttackMult);
            var def = new CombatDefender
            {
                Armor = armor,
                ArmorType = armorType,
                Dodge = 0.0,
                ArmorMult = 1.0,
                DamageTakenMult = 1.0,
            };
            return CombatCalculator.ExpectedDps(atk, def, rules);
        }

        public static UnitCatalog FromDict(IDictionary<string, object> d, CombatRules rules, List<string> notes)
        {
            var cat = new UnitCatalog();
            if (d == null)
            {
                notes.Add("units 配置为空");
                return cat;
            }

            var factions = JVal.Dict(d, "factions");
            if (factions == null)
            {
                notes.Add("缺少 factions");
            }
            else
            {
                foreach (var kv in factions)
                {
                    var fd = JVal.AsDict(kv.Value);
                    if (fd == null)
                    {
                        notes.Add($"factions.{kv.Key} 不是对象");
                        continue;
                    }
                    cat._factions[kv.Key] = new FactionDef
                    {
                        Id = kv.Key,
                        DisplayName = JVal.Str(fd, "display_name", kv.Key),
                        UsePlaceholderMesh = JVal.Bool(fd, "use_placeholder_mesh", false),
                        Note = JVal.Str(fd, "note", ""),
                    };
                }
            }

            var units = JVal.List(d, "units");
            if (units == null)
            {
                notes.Add("缺少 units 数组");
                return cat;
            }

            foreach (var item in units)
            {
                var ud = JVal.AsDict(item);
                if (ud == null)
                {
                    notes.Add("units 里有非对象项");
                    continue;
                }
                var u = new UnitDef
                {
                    Id = JVal.Str(ud, "id", ""),
                    DisplayName = JVal.Str(ud, "display_name", ""),
                    Faction = JVal.Str(ud, "faction", ""),
                    Enabled = JVal.Bool(ud, "enabled", true),
                    SquadSize = JVal.Int(ud, "squad_size", 1),
                    Hp = JVal.Double(ud, "hp", 0.0),
                    AttackDamage = JVal.Double(ud, "attack_damage", 0.0),
                    AttackCooldown = JVal.Double(ud, "attack_cooldown", 1.0),
                    AttackRange = JVal.Double(ud, "attack_range", 0.0),
                    Armor = JVal.Double(ud, "armor", 0.0),
                    Hit = JVal.Double(ud, "hit", CombatRules.SpecHitBase),
                    Dodge = JVal.Double(ud, "dodge", 0.0),
                    Crit = JVal.Double(ud, "crit", 0.0),
                    ArmorPenFlat = JVal.Double(ud, "armor_pen_flat", 0.0),
                    ArmorPenPct = JVal.Double(ud, "armor_pen_pct", 0.0),
                    MoveSpeed = JVal.Double(ud, "move_speed", 0.0),
                    BodyRadius = JVal.Double(ud, "body_radius", 0.45),
                    Projectile = JVal.Bool(ud, "projectile", false),
                    ProjectileSpeed = JVal.Double(ud, "projectile_speed", 0.0),
                    PopCost = JVal.Int(ud, "pop_cost", JVal.Int(ud, "squad_size", 1)),
                    PassiveTrait = JVal.Str(ud, "passive_trait", ""),
                    Note = JVal.Str(ud, "note", ""),
                };

                string attackName = JVal.Str(ud, "attack_type", "");
                u.AttackType = CombatTypes.TryParseAttack(attackName, out int at) ? at : -1;

                string armorName = JVal.Str(ud, "armor_type", "");
                u.ArmorType = CombatTypes.TryParseArmor(armorName, out int ar) ? ar : -1;

                FactionDef faction = cat.GetFaction(u.Faction);
                u.UsePlaceholderMesh = JVal.Bool(ud, "use_placeholder_mesh",
                    faction != null && faction.UsePlaceholderMesh);

                cat._units[u.Id] = u;
                cat._all.Add(u);
            }

            // 让规则对象的表只用于结算；这里不复制表，避免第二份真值。
            _ = rules;
            return cat;
        }

        private static bool IsAscii(string s)
        {
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] > 127) return false;
            }
            return true;
        }
    }
}
