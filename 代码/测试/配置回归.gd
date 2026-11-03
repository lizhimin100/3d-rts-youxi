extends SceneTree
## **配置回归（6.6）**：改一点数值，断言"该动的方向都动了、不该崩的没崩"。
##
## 为什么写成 `--script`（不进引擎）：
##   · 战斗模型 / 伤害公式 / 成本效率全是纯函数，不需要场景、不需要那张 224m 地图；
##   · 一次跑完 1~2 秒，改数值后可以当"改完立刻验"的闸门。
##
## 跑法：
##   godot --headless --path . --script 代码/测试/配置回归.gd
## 输出：结尾一行 `CONFIG-REGRESSION {json}`；退出码 0 = 全过。
##
## ⚠ `--script` 的脚本在 autoload 注册**之前**编译，所以这里不能直接写 `Cfg`，
##   一律走 root.get_node("Cfg") + 运行时 load()（与 战斗自检.gd 同一套写法）。
##
## 覆盖范围（按"改数值会不会把 AI 的估值带歪"选）：
##   A 攻击 +10%      → dps 线性、战力 ×√1.1（几何平均）
##   B 造价 +20%      → 每金战力线性下降（只看金币项）
##   C 造价 -20%      → 每金战力线性上升
##   D 克制表改一项   → dps 按新倍率变化（普通×重甲 0.85 → 1.10）
##   E 空集/零值     → 不除零、不返回 NaN（零攻击模板/空队伍/全零成本）
##   F 出击门槛      → 门槛数值 + 三条否决条件（威胁/低侵略/兵力比）
##   G 哪些"需引擎"   → 只登记不伪造（选兵权重依赖建筑/阵营/场景扫描）

var _cfg: Node = null
var _model = null

var _pass: int = 0
var _fail: int = 0
var _detail: Array = []
## 需要引擎、本轮**不测**的纯函数/半纯函数（4.2 要求列出来，不许伪造）
var _engine_only: Array = [
	{
		"func": "简单AI._pick_army_unit() / _weighted_pick()",
		"why": "仍依赖 RtsBuilding.can_train、_can_spend(Cfg+Game)、_faction.count_units()、_enemy_army() 场景扫描；"
			+ "**权重公式已抽成 战斗模型.selection_weight（static 纯函数）**，并在本轮韧性 A/B/D 里断言。",
		"可拆": "已完成（selection_weight）；只剩 can_train / 场景扫描不可脱。",
	},
	{
		"func": "简单AI._ratio_foe_army()（A/B/C 分母）",
		"why": "要真实的 RtsFaction.units 列表与队伍关系；用假数据测等于测我自己写的假数据。",
		"可拆": "bench 三组对照（第二段 §2）已经是它的验收",
	},
]


## 假单位：只提供 战斗模型 真正读的三个字段（def / hp / faction）。
## 用 RefCounted 而不是 RtsUnit —— 后者会把整条 单位.gd 拉进引擎依赖。
class FakeUnit extends RefCounted:
	var def: Resource = null
	var hp: float = 100.0
	var faction = null


func _initialize() -> void:
	# 延迟一帧：SceneTree 脚本的 _initialize 阶段 autoload 还没进树（见 战斗自检.gd）
	call_deferred("_run")


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	_cfg = root.get_node_or_null("Cfg")
	if _cfg == null:
		_record("环境", false, "找不到 Cfg 自动加载单例")
		_finish(t0)
		return
	_model = load("res://代码/ai/战斗模型.gd").new()
	if _model == null:
		_record("环境", false, "战斗模型.gd 加载失败")
		_finish(t0)
		return

	_case_attack()
	_case_cost(0.2, "造价+20%")
	_case_cost(-0.2, "造价-20%")
	_case_counter()
	_case_edge()
	_case_attack_gate()
	_case_wave_cost()
	# 2C-3：数值可变韧性 / 角色标签 / 判定表 / 理论值
	_case_resilience()
	_case_roles()
	_case_verdict_table()
	_case_theory()
	# 2C-4：判定层修正 + 决策层纯函数 + 卡系统
	_case_2c4()
	# 2C-5：承伤分母 / 军队规模目标 / 修理 / 达成归属
	_case_2c5()
	# 2C-6：0.4 系数 / B 输出分母 / 修理 200 HP / 农场预判 / 兵营座数 / 移速换算
	_case_2c6()
	_finish(t0)


# ===========================================================================
# A 攻击 +10%
# ===========================================================================
func _case_attack() -> void:
	var d0: UnitDef = _cfg.unit(&"footman")
	if d0 == null:
		_record("攻击+10%", false, "找不到 footman")
		return
	var prof: Dictionary = _model.call("profile", [_unit(_cfg.unit(&"footman")),
			_unit(_cfg.unit(&"footman"))])
	var d1: UnitDef = d0.duplicate()
	d1.attack_damage = float(d0.attack_damage) * 1.1

	var dps0: float = _model.call("dps", d0, prof)
	var dps1: float = _model.call("dps", d1, prof)
	_record("攻击+10% → dps ×1.10", _near(dps1 / maxf(dps0, 0.0001), 1.1, 0.001),
			"%.3f → %.3f（×%.4f）" % [dps0, dps1, dps1 / maxf(dps0, 0.0001)])

	var v0: float = _model.call("value", d0, prof)
	var v1: float = _model.call("value", d1, prof)
	_record("攻击+10% → 战力 ×√1.10", _near(v1 / maxf(v0, 0.0001), sqrt(1.1), 0.002),
			"%.2f → %.2f（×%.4f，期望 %.4f）" % [v0, v1, v1 / maxf(v0, 0.0001), sqrt(1.1)])


# ===========================================================================
# B/C 造价 ±20%
# ===========================================================================
func _case_cost(delta: float, label: String) -> void:
	var d0: UnitDef = _cfg.unit(&"footman")
	if d0 == null:
		_record(label, false, "找不到 footman")
		return
	var d1: UnitDef = d0.duplicate()
	var g0: float = float(d0.gold_cost)
	d1.gold_cost = maxi(1, int(round(g0 * (1.0 + delta))))
	var g1: float = float(d1.gold_cost)

	var prof: Dictionary = _model.call("profile", [_unit(_cfg.unit(&"archer"))])
	# 只留金币项（木/人口/时间的权重置 0）——这样期望比值就是 g0/g1，
	# 不会掺进"木材折算"这类与本次变更无关的系数。
	var w0: float = _model.call("worth_per_cost", d0, prof, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0)
	var w1: float = _model.call("worth_per_cost", d1, prof, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0)
	var expect: float = g0 / g1
	var got: float = w1 / maxf(w0, 0.0000001)
	_record("%s → 每金战力 ×%.3f" % [label, expect], _near(got, expect, 0.0005),
			"金 %d→%d，每金战力 %.5f→%.5f（×%.4f）" % [int(g0), int(g1), w0, w1, got])


# ===========================================================================
# D 克制表改一项（普通×重甲 0.85 → 1.10）
# ===========================================================================
func _case_counter() -> void:
	var d0: UnitDef = _cfg.unit(&"footman")
	var table: Array = _cfg.game.damage_table
	var idx: int = 0 * 4 + 1          # 普通(0) × 重甲(1)
	if d0 == null or idx >= table.size():
		_record("克制表改一项", false, "索引越界或找不到 footman")
		return
	var old: float = float(table[idx])
	var prof: Dictionary = _model.call("profile", [_unit(_cfg.unit(&"footman"))])
	var dps0: float = _model.call("dps", d0, prof)
	table[idx] = 1.10
	var dps1: float = _model.call("dps", d0, prof)
	table[idx] = old                  # ★ 立刻还原：后面的用例还要用干净的配置
	var got: float = dps1 / maxf(dps0, 0.0001)
	var expect: float = 1.10 / old
	_record("克制 普通×重甲 %.2f→1.10 → dps ×%.3f" % [old, expect],
			_near(got, expect, 0.002),
			"%.3f → %.3f（×%.4f，期望 %.4f）" % [dps0, dps1, got, expect])
	_record("克制表已还原", is_equal_approx(float(_cfg.game.damage_table[idx]), old),
			"当前值 %.3f（原 %.3f）" % [float(_cfg.game.damage_table[idx]), old])


# ===========================================================================
# E 空集 / 零值 / 不除零
# ===========================================================================
func _case_edge() -> void:
	# 空队伍画像：必须有默认护甲/伤害分布，不能空字典（下游 _expected_counter 会乘 0）
	var p_empty: Dictionary = _model.call("profile", [])
	var has_mix: bool = not Dictionary(p_empty.get("armor_mix", {})).is_empty() \
			and not Dictionary(p_empty.get("dmg_mix", {})).is_empty()
	_record("空队伍画像有默认分布", has_mix and float(p_empty.get("hp", -1)) == 0.0,
			"armor_mix=%s dmg_mix=%s hp=%.1f" % [p_empty.get("armor_mix"), p_empty.get("dmg_mix"),
				float(p_empty.get("hp", -1))])

	# 零攻击单位（把步兵的攻击改成 0，模拟"完全没有武器"的模板）：
	# 战力必须落在 MIN_VALUE，不能 0/NaN。★ 不要拿农民当"零攻击"样本 ——
	# 本工程的农民是有攻击的（实测 value≈22），拿它测会得到假阴性。
	var zero: UnitDef = _cfg.unit(&"footman").duplicate()
	zero.attack_damage = 0.0
	var prof: Dictionary = _model.call("profile", [_unit(_cfg.unit(&"footman"))])
	var v: float = _model.call("value", zero, prof)
	_record("零攻击单位 → 战力=1.0（不除零）", _near(v, 1.0, 0.0001), "value=%.4f" % v)
	# 成本全 0：分母被 maxf(...,1.0) 兜住
	var w: float = _model.call("worth_per_cost", zero, prof, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0)
	_record("零成本 → 每金战力有限", is_finite(w) and w > 0.0, "worth=%.4f" % w)
	# 冷却 0：dps 必须直接返回 0，不是 INF
	var wz: UnitDef = _cfg.unit(&"footman").duplicate()
	wz.attack_damage = 10.0
	wz.attack_cooldown = 0.0
	var dz: float = _model.call("dps", wz, prof)
	_record("冷却=0 → dps=0（不产生 INF）", dz == 0.0, "dps=%.4f" % dz)
	# 观察项（不是断言）：农民不是"零攻击"，AI 估值里它是能打的
	var pw: UnitDef = _cfg.unit(&"peasant")
	if pw != null:
		_record("观察：农民也有战力（不是零攻击模板）",
				_model.call("dps", pw, prof) > 0.0,
				"peasant value=%.2f" % float(_model.call("value", pw, prof)))

	# 空敌方 = 没有情报 → ratio 必须返回 -1（由调用方决定怎么解释）
	var empty_ratio: float = _model.call("ratio", [], [])
	_record("ratio(空,空) = -1（无情报哨兵）", empty_ratio < 0.0, "ratio=%.3f" % empty_ratio)

	# 同兵对同兵：比值应落在 1 附近（±5%），说明双方画像对称
	var r_mirror: float = _model.call("ratio",
			[_unit(_cfg.unit(&"footman"))], [_unit(_cfg.unit(&"footman"))])
	_record("同兵对同兵 ratio≈1", _near(r_mirror, 1.0, 0.05), "ratio=%.4f" % r_mirror)


# ===========================================================================
# F 出击门槛（纯函数：只需要一份伪造的 metrics）
#
# 2026-11-03 2C-2 改口径：出击许可**不再读军力比**（设计文档 §3.6）。
# 断言随之改成"兵比高低都放行、只剩威胁/侵略性两条否决"，
# 同时保留"门槛数值仍可算"（它现在只进报告，不参与判断）。
# ===========================================================================
func _case_attack_gate() -> void:
	var director = load("res://代码/ai/战略导演.gd").new()
	director.call("setup", [], 0)     # 难度 0（简单）→ skill 0.85 → 门槛 1.35/0.85
	var need: float = float(director.call("_attack_ratio_needed"))
	_record("简单档门槛报告值 = 1.59（仅记录，不判断）", _near(need, 1.59, 0.01), "need=%.4f" % need)

	var base := {
		"base_threat": 0.0, "army_ratio": 0.50, "attack_ratio": 0.50,
		"my_army_value": 300.0, "enemy_static_defense": 100.0, "army_food": 5.0,
	}
	var low: bool = bool(director.call("_compute_allow_attack", base, 0.8))
	_record("兵比 0.50 < 1.59 → 仍然放行（已移除军力比依赖）", low, "allow=%s" % str(low))

	var high: Dictionary = base.duplicate()
	high["army_ratio"] = 1.70
	high["attack_ratio"] = 1.70
	var ok_hi: bool = bool(director.call("_compute_allow_attack", high, 0.8))
	_record("兵比 1.70 → 放行", ok_hi, "allow=%s" % str(ok_hi))

	var threat: Dictionary = high.duplicate()
	threat["base_threat"] = 1.0
	_record("家里挨打 → 收回许可", not bool(director.call("_compute_allow_attack", threat, 0.8)),
			"allow=%s" % str(bool(director.call("_compute_allow_attack", threat, 0.8))))

	_record("侵略性 0.20 < 0.30 → 不放行",
			not bool(director.call("_compute_allow_attack", high, 0.20)),
			"allow=%s" % str(bool(director.call("_compute_allow_attack", high, 0.20))))


# ===========================================================================
# H 波次成本口径（C1：只金 + 木，不含人口；2C-2 新增）
# ===========================================================================
func _case_wave_cost() -> void:
	var foot: UnitDef = _cfg.unit(&"footman")
	var arch: UnitDef = _cfg.unit(&"archer")
	if foot == null or arch == null:
		_record("unit_cost / wave_cost", false, "找不到 footman / archer")
		return
	var c_foot: float = float(_model.call("unit_cost", foot))
	var expect_foot: float = float(foot.gold_cost) + float(foot.wood_cost)
	_record("unit_cost(footman) = 金+木（不含人口）", _near(c_foot, expect_foot, 0.0001),
			"%.1f（金 %d + 木 %d，人口 %d 未计入）"
				% [c_foot, foot.gold_cost, foot.wood_cost, foot.food_cost])

	var units: Array = [_unit(foot), _unit(foot), _unit(arch)]
	var c_wave: float = float(_model.call("wave_cost", units))
	var expect_wave: float = 2.0 * c_foot + float(_model.call("unit_cost", arch))
	_record("wave_cost(2 步 + 1 弓) = 按编制求和", _near(c_wave, expect_wave, 0.0001),
			"%.1f（期望 %.1f）" % [c_wave, expect_wave])

	var empty_cost: float = float(_model.call("wave_cost", []))
	_record("wave_cost(空编制) = 0（不报错）", empty_cost == 0.0, "%.1f" % empty_cost)


# ===========================================================================
# I 数值可变韧性（2C-3 · 第 1 部分）
#
# 断言口径：用户改数值/攻防关系/增删兵种后，AI 的派生量与选兵权重**跟着变**，
# 不崩、不需要改 AI 代码。全部用 UnitDef 的运行时副本，不写 .tres，测完还原。
# ===========================================================================
func _case_resilience() -> void:
	var foot: UnitDef = _cfg.unit(&"footman")
	var arch: UnitDef = _cfg.unit(&"archer")
	if foot == null or arch == null:
		_record("韧性：基础兵种存在", false, "找不到 footman / archer")
		return
	var prof: Dictionary = _model.call("profile", [_unit(foot)])

	# --- 改弓箭手攻击 +10% → dps ×1.1 → power ×√1.1 → 选兵权重上升 ---
	var a1: UnitDef = arch.duplicate()
	a1.attack_damage = float(arch.attack_damage) * 1.1
	var r_dps: float = float(_model.call("unit_dps", a1)) / maxf(float(_model.call("unit_dps", arch)), 0.0001)
	var r_pow: float = float(_model.call("unit_power", a1)) / maxf(float(_model.call("unit_power", arch)), 0.0001)
	_record("韧性A：弓攻击+10% → unit_dps ×1.10", _near(r_dps, 1.1, 0.001), "×%.4f" % r_dps)
	_record("韧性A：弓攻击+10% → unit_power ×√1.10", _near(r_pow, sqrt(1.1), 0.002),
			"×%.4f（期望 %.4f）" % [r_pow, sqrt(1.1)])
	var w0: float = float(_model.call("selection_weight", arch, 3.0, 0, prof, 1.0, 1.0))
	var w1: float = float(_model.call("selection_weight", a1, 3.0, 0, prof, 1.0, 1.0))
	_record("韧性A：弓攻击+10% → 选兵权重上升（方向断言）",
			w1 > w0 * 1.02, "%.5f → %.5f（×%.4f）" % [w0, w1, w1 / maxf(w0, 0.0001)])

	# --- 改步兵护甲 +2 → 有效生命上升 → 前排权重上升 ---
	var f1: UnitDef = foot.duplicate()
	f1.armor = float(foot.armor) + 2.0
	var e0: float = float(_model.call("unit_effective_hp", foot))
	var e1: float = float(_model.call("unit_effective_hp", f1))
	_record("韧性B：步兵护甲+2 → unit_effective_hp 上升",
			e1 > e0 * 1.15, "%.1f → %.1f（×%.3f）" % [e0, e1, e1 / maxf(e0, 0.0001)])
	var fw0: float = float(_model.call("selection_weight", foot, 5.0, 0, prof, 1.0, 1.0))
	var fw1: float = float(_model.call("selection_weight", f1, 5.0, 0, prof, 1.0, 1.0))
	_record("韧性B：步兵护甲+2 → 前排选兵权重上升（方向断言）",
			fw1 > fw0 * 1.02, "%.5f → %.5f（×%.4f）" % [fw0, fw1, fw1 / maxf(fw0, 0.0001)])

	# --- 克制表 普通×重甲 0.85 → 1.10 ---
	var table: Array = _cfg.game.damage_table
	var idx: int = 0 * 4 + 1
	var old: float = float(table[idx])
	var before: float = float(_model.call("counter_multiplier", 0, 1))
	table[idx] = 1.10
	var after: float = float(_model.call("counter_multiplier", 0, 1))
	var best_at_110: int = int(_model.call("best_counter_damage_type", [_unit(foot)]))
	# 机制自检：把值抬到 1.20（**只在本条断言内**，不是规格值）→ 推荐必须翻成普通
	table[idx] = 1.20
	var best_at_120: int = int(_model.call("best_counter_damage_type", [_unit(foot)]))
	table[idx] = old
	_record("韧性C：克制 普通×重甲 %.2f→1.10 → counter_multiplier 跟着变" % old,
			_near(after, 1.10, 0.0001) and after != before,
			"%.2f → %.2f" % [before, after])
	_record("韧性C：1.10 时推荐仍是魔法（1.15>1.10，规格预期不成立，见报告）",
			best_at_110 == RtsConst.DamageType.MAGIC,
			"best=%d（%d=普通/%d=魔法）" % [best_at_110, RtsConst.DamageType.NORMAL,
				RtsConst.DamageType.MAGIC])
	_record("韧性C：克制推荐机制本身会翻（1.20 时 → 普通）",
			best_at_120 == RtsConst.DamageType.NORMAL,
			"best@1.20=%d" % best_at_120)
	_record("韧性C：克制表已还原", is_equal_approx(float(table[idx]), old),
			"当前 %.3f（原 %.3f）" % [float(table[idx]), old])

	# --- 新增一个假兵种（role=ranged）→ 不崩、能被选兵逻辑纳入 ---
	var fake := UnitDef.new()
	fake.id = &"fake_ranged_2c3"
	fake.display_name = "假远程"
	fake.kind = RtsConst.Kind.UNIT
	fake.role = &"ranged"
	fake.tags.append(&"light")
	fake.anim_set = RtsConst.AnimSet.ARCHER
	fake.max_hp = 210.0
	fake.armor = 1.0
	fake.attack_damage = 12.0
	fake.attack_cooldown = 1.3
	fake.attack_range = 9.0
	fake.gold_cost = 111
	fake.wood_cost = 11
	# 2C-4：候选池走**职能权重**（承伤/输出）；假兵无卡 → 能力回退（远+攻 → 输出）也进池
	var weights: Dictionary = {&"承伤": 5.0, &"输出": 5.0}
	_cfg.game.units[fake.id] = fake
	var ids_add: Array = _model.call("candidate_combat_ids", weights)
	var wf: float = float(_model.call("selection_weight", fake, 3.0, 0, prof, 1.0, 1.0))
	_record("韧性D：新增职能未填的假兵 → 能力回退进入候选池", ids_add.has(fake.id),
			"候选 %d 个，含 fake=%s" % [ids_add.size(), str(ids_add.has(fake.id))])
	_record("韧性D：假兵选兵权重有限且 >0", is_finite(wf) and wf > 0.0, "w=%.6f" % wf)
	_cfg.game.units.erase(fake.id)
	var ids_after: Array = _model.call("candidate_combat_ids", weights)
	_record("韧性D：假兵已移除", not ids_after.has(fake.id),
			"候选 %d 个" % ids_after.size())

	# --- 删除一个兵种（archer）→ 不崩、配比自动重排 ---
	var before_n: int = int(_model.call("candidate_combat_ids", weights).size())
	var saved: UnitDef = _cfg.game.units.get(&"archer", null)
	_cfg.game.units.erase(&"archer")
	var ids_del: Array = _model.call("candidate_combat_ids", weights)
	var has_arch: bool = ids_del.has(&"archer")
	var has_front: bool = ids_del.has(&"footman")
	_cfg.game.units[&"archer"] = saved
	_record("韧性E：删除 archer → 候选池少 1、不崩", not has_arch and ids_del.size() == before_n - 1,
			"%d → %d" % [before_n, ids_del.size()])
	_record("韧性E：删除 archer → 其它 role 仍可选中（自动重排）", has_front,
			"footman 在候选池=%s" % str(has_front))
	_record("韧性E：archer 已还原", _cfg.game.units.get(&"archer", null) != null, "ok")


# ===========================================================================
# J 角色标签（2C-3 · 第 2 部分，3 条）
# ===========================================================================
func _case_roles() -> void:
	var foot: UnitDef = _cfg.unit(&"footman")
	var arch: UnitDef = _cfg.unit(&"archer")
	var steam: UnitDef = _cfg.unit(&"steam_guard")
	_record("角色：is_frontline(步兵)=true", bool(_model.call("is_frontline", foot)),
			"role=%s" % String(foot.role) if foot != null else "null")
	_record("角色：is_backline(弓箭手)=true", bool(_model.call("is_backline", arch)),
			"role=%s" % String(arch.role) if arch != null else "null")
	_record("角色：has_tag(蒸汽重步兵, siege)=true",
			bool(_model.call("has_tag", steam, &"siege")),
			"tags=%s" % str(steam.tags) if steam != null else "null")


# ===========================================================================
# K 判定表（2C-3 · A4，7 条；纯函数，直接喂数）
# ===========================================================================
func _case_verdict_table() -> void:
	var T: float = 40.0
	var rows: Array = [
		# 名称, achieved, forced, combat, out_eff, dmg_ratio, survivors, strength, 期望
		["达成优先于一切", true, false, 0.0, 0.0, 0.0, 0, 5, "达成"],
		["时间≥0.8 + 输出/承伤在区间 → 好", false, false, 32.0, 1.0, 0.6, 5, 5, "好"],
		["时间≥0.8 但输出偏离 → 一般", false, false, 32.0, 1.5, 0.6, 5, 5, "一般"],
		["时间 0.5~0.8 → 一般", false, false, 24.0, 1.0, 0.6, 5, 5, "一般"],
		["时间<0.5 且全灭 → 差", false, false, 16.0, 1.0, 0.6, 0, 5, "差"],
		["时间<0.5 存活≤ceil(出发/3) → 差（2C-4 放宽：非全灭也判）", false, false, 16.0, 1.0, 0.6, 3, 10, "差"],
		["时间<0.5 存活>ceil(出发/3) → 未判（不许当差）", false, false, 16.0, 1.0, 0.6, 5, 10, "未判"],
		["存活>180s 强制 → 一般", false, true, 16.0, 1.0, 0.6, 5, 10, "一般"],
	]
	for r in rows:
		var got: String = String(_model.call("classify_verdict",
				r[1], r[2], r[3], T, r[4], r[5], int(r[6]), int(r[7])))
		_record("判定表：%s" % String(r[0]), got == String(r[8]),
				"判=%s（期望 %s，战斗时间 %.0f/%.0fs）" % [got, String(r[8]), float(r[3]), T])


# ===========================================================================
# L 理论值公式（2C-3 · A2，3 条）
# ===========================================================================
func _case_theory() -> void:
	var t: float = float(_model.call("theory_combat_time", 1000.0))
	_record("理论值：1000 金木成本 → 40 s", _near(t, 40.0, 0.0001), "%.1f s" % t)

	var foot: UnitDef = _cfg.unit(&"footman")
	var comp: Dictionary = {&"footman": 1}
	var dps: float = float(_model.call("unit_dps", foot))
	var out: float = float(_model.call("theory_output", comp, 10.0, 0.7))
	var expect: float = dps * 10.0 * 0.7
	_record("理论值：1 步兵 10 s 理论输出 = dps×10×0.7", _near(out, expect, 0.001),
			"%.3f（dps=%.3f，期望 %.3f）" % [out, dps, expect])

	var hp: float = float(_model.call("theory_hp", comp))
	var ehp: float = float(_model.call("unit_effective_hp", foot))
	_record("理论值：1 步兵理论承伤 = unit_effective_hp", _near(hp, ehp, 0.001),
			"%.2f（期望 %.2f）" % [hp, ehp])


# ===========================================================================
# M 2C-4：判定层修正 + 决策层纯函数 + 卡系统
# ===========================================================================
func _case_2c4() -> void:
	var UT = load("res://代码/配置/单位表.gd")
	# ★ --script 模式**不能** load 带 class_name 的脚本（Godot 怪癖：
	#   "Class X hides a global script class"），简单AI.gd 的常量用**文本级断言**；
	#   它的编译检查由 --ai-bench / --autotest 真跑兜底（那两个模式没有这个限制）。
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var LW = load("res://代码/配置/定位词表.gd")

	# --- 判定层：有效交战时间 ---
	_record("2C4：hit_gap_contrib 正常间隔计入", _near(float(_model.call("hit_gap_contrib", 10.0, 13.0, 3.0)), 3.0, 0.0001), "=3")
	_record("2C4：hit_gap_contrib 断档(>gap)不计", float(_model.call("hit_gap_contrib", 10.0, 14.0, 3.0)) == 0.0, "=0")
	_record("2C4：hit_gap_contrib 首刀起表贡献0", float(_model.call("hit_gap_contrib", -1.0, 13.0, 3.0)) == 0.0, "=0")
	_record("2C6：输出系数默认 0.4（2C-6 用户拍板 0.55→0.4）",
			_near(float(AIV.DEFAULT_COEF), 0.4, 0.0001) and _near(float(AIV.output_coef()), 0.4, 0.0001)
			and _near(float(load("res://代码/ai/战斗模型.gd").THEORY_OUTPUT_COEF), 0.4, 0.0001),
			"coef=%.2f" % float(AIV.output_coef()))
	# 交战断档参数可命令行口径存在
	AIV.set_combat_gap_sec(5.0)
	_record("2C4：combat_gap_sec 可设（敏感性 2/3/5 用）", _near(float(AIV.combat_gap_sec()), 5.0, 0.0001), "=5")
	AIV.reset_defaults()

	# --- 判定层：差放宽 / 好护栏 ---
	_record("2C4：bad_survivor_cap(10)=ceil(10/3)=4", int(_model.call("bad_survivor_cap", 10)) == 4, "=4")
	_record("2C4：bad_survivor_cap(9)=3", int(_model.call("bad_survivor_cap", 9)) == 3, "=3")
	_record("2C4：好护栏 26/52 = 恰好一半不告警", not bool(_model.call("good_ratio_warning", 26, 52)), ">50% 才告警")
	_record("2C4：好护栏 27/52 告警", bool(_model.call("good_ratio_warning", 27, 52)), "27/52")
	_record("2C4：好护栏 空记录不告警", not bool(_model.call("good_ratio_warning", 0, 0)), "total=0 → false")

	# --- 决策层：防守下限 / 出击比例 / 攒大波门槛 ---
	_record("2C4：防守下限 5+2×1+1×1=8", int(_model.call("defense_floor_of", 1, 1)) == 8, "=8")
	_record("2C4：保底留守 ceil(8×2/3)=6", int(_model.call("bank_garrison_floor", 8)) == 6, "=6")
	_record("2C4：常态出击 10 人下限 8 → 派 2", int(_model.call("normal_push_n", 10, 8)) == 2, "=2")
	_record("2C4：常态出击 16 人下限 9 → 派 7（0.75 floor）", int(_model.call("normal_push_n", 16, 9)) == 7, "=7")
	_record("2C4：大波出击 10 人下限 8 → 派 4", int(_model.call("bank_push_n", 10, 8)) == 4, "=4")
	_record("2C4：大波出击 6 人下限 8 → 派 0（保底不为负）", int(_model.call("bank_push_n", 6, 8)) == 0, "=0")
	_record("2C4：bank_baseline 有历史=上次实际派出成本", _near(float(_model.call("bank_baseline", 200.0, 100.0)), 200.0, 0.0001), "=200")
	_record("2C4：bank_baseline 无历史=可用×0.75（首波退化）", _near(float(_model.call("bank_baseline", 0.0, 100.0)), 75.0, 0.0001), "=75")
	_record("2C4：bank_ready 226≥1.5×150 → 出击", bool(_model.call("bank_ready", 226.0, 150.0)), "1.5×150=225")
	_record("2C4：bank_ready 224<225 → 不出击", not bool(_model.call("bank_ready", 224.0, 150.0)), "差1")
	_record("2C4：bank_ready 不封顶（10000 也真）", bool(_model.call("bank_ready", 10000.0, 150.0)), "P5 已删")

	# --- 决策层：简单AI 常量与状态机形态（文本级）---
	_record("2C4：ST_TECH 已删除（四状态机）", not sa_src.contains("const ST_TECH"),
			"含 ST_TECH 定义=%s" % str(sa_src.contains("const ST_TECH")))
	_record("2C4：BANK_MAX_SEC=90（超时直接出击）",
			sa_src.contains("const BANK_MAX_SEC: float = 90.0"), "文本命中")
	_record("2C4：科技前 5 分钟不科研",
			sa_src.contains("const RESEARCH_NOT_BEFORE_SEC: float = 300.0"), "文本命中")
	_record("2C4：常态出击比例 0.75",
			sa_src.contains("const ATTACK_RATIO_NORMAL: float = 0.75"), "文本命中")
	_record("2C4：农民软上限直接覆盖（总=软+4）",
			sa_src.contains("PEASANT_GOLD_SOFT_CAP: int = 8")
			and sa_src.contains("PEASANT_TOTAL_CAP: int = PEASANT_GOLD_SOFT_CAP + 4"),
			"软=8 总=12（TODO 农民测试标定）")

	# --- 卡系统（C1~C5）---
	var foot_card: EntityCard = UT.get_card(&"footman")
	_record("2C4卡：get_card(footman) 命中且 power=-1",
			foot_card != null and (foot_card as UnitCard).power == -1
			and String((foot_card as UnitCard).icon) == "",
			"power=%d icon='%s'" % [(foot_card as UnitCard).power if foot_card != null else -99,
				String((foot_card as UnitCard).icon) if foot_card != null else "?"])
	_record("2C4卡：职能承伤含 步兵/蒸汽重步兵/豺狼人战士",
			UT.find_by_role(&"承伤").any(func(c): return c.card_id == "footman")
			and UT.find_by_role(&"承伤").any(func(c): return c.card_id == "steam_guard")
			and UT.find_by_role(&"承伤").any(func(c): return c.card_id == "gnoll_warrior"),
			"承伤=%d 张" % UT.find_by_role(&"承伤").size())
	_record("2C4卡：范围档派生 步兵=近战(1.35) / 蒸汽重步兵=中程(1.6，阈值占位 TODO)",
			UT.find_by_range_tier(&"近战").any(func(c): return c.card_id == "footman")
			and UT.find_by_range_tier(&"中程").any(func(c): return c.card_id == "steam_guard"),
			"阈值 1.5/3.0/6.0")
	var fake_def: UnitDef = UnitDef.new()
	fake_def.id = &"fake_cardless"
	fake_def.attack_damage = 10.0
	fake_def.attack_range = 9.0
	var fw := {&"承伤": 6.0, &"输出": 4.0}
	_record("2C4卡：无卡兵走能力回退（远+攻→输出，权重取 max）",
			bool(_model.call("def_roles_is_fallback", fake_def))
			and _near(float(_model.call("def_function_weight", fake_def, fw)), 4.0, 0.0001),
			"回退=输出 w=4")
	var bad: PackedStringArray = LW.validate_words(&"魔法兵种", [&"坦克"], [], &"普通", &"轻甲")
	_record("2C4卡：词表校验拦下非法词", bad.size() >= 2, "%s" % str(bad))
	var all_units: Dictionary = UT.build_units()
	_record("2C4卡：build_units = 17 卡 + 6 可采集物 = 23",
			all_units.size() == 23 and all_units.has(&"footman") and all_units.has(&"goldmine"),
			"size=%d" % all_units.size())
	var tiers: Array = [LW.range_tier(1.0), LW.range_tier(2.0), LW.range_tier(5.0), LW.range_tier(9.0)]
	_record("2C4卡：range_tier 四档单调",
			String(tiers[0]) == "近战" and String(tiers[1]) == "中程"
			and String(tiers[2]) == "远程" and String(tiers[3]) == "超远程", str(tiers))


# ===========================================================================
# N 2C-5：承伤分母口径 / 军队规模目标 / 修理 / 达成归属（9 条）
# ===========================================================================
func _case_2c5() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var sched_src: String = FileAccess.get_file_as_string("res://代码/ai/命令调度.gd")
	var foot: UnitDef = _cfg.unit(&"footman")
	var ehp: float = float(_model.call("unit_effective_hp", foot))
	var comp: Dictionary = {&"footman": 3}

	# --- P0-1 承伤分母：只算"曾作为 target 的成员"---
	var dt: float = float(_model.call("damage_theory", comp, {&"footman": 1}, "targeted"))
	_record("2C5：承伤分母 targeted 只算挨过打的成员（3 步兵 / 1 挨打）",
			_near(dt, ehp, 0.001) and String(AIV.damage_theory_mode()) == "targeted",
			"%.1f（期望 %.1f = 1 个有效生命；默认口径=%s）"
				% [dt, ehp, String(AIV.damage_theory_mode())])
	var da: float = float(_model.call("damage_theory", comp, {&"footman": 1}, "all"))
	_record("2C5：承伤分母 all 回 2C-4 旧口径（全程 3 个有效生命）",
			_near(da, ehp * 3.0, 0.001), "%.1f（期望 %.1f）" % [da, ehp * 3.0])

	# --- P0-2 军队规模目标 ---
	_record("2C5：军队目标 1 基地 1 兵营 = 10+4+2 = 16",
			int(_model.call("army_target_of", 1, 1, 0.0, 8)) == 16,
			"=%d" % int(_model.call("army_target_of", 1, 1, 0.0, 8)))
	_record("2C5：军队目标 420 s 起解除（-1）",
			int(_model.call("army_target_of", 1, 1, 420.0, 8)) == -1
			and int(_model.call("army_target_of", 1, 1, 419.9, 8)) == 16,
			"419.9s=%d / 420s=%d" % [int(_model.call("army_target_of", 1, 1, 419.9, 8)),
				int(_model.call("army_target_of", 1, 1, 420.0, 8))])
	_record("2C5：军队目标不低于防守下限（公式值 10 < 下限 12 → 取 12）",
			int(_model.call("army_target_of", 0, 0, 0.0, 12)) == 12,
			"=%d" % int(_model.call("army_target_of", 0, 0, 0.0, 12)))

	# --- P1-4 修理阈值（默认 70%）---
	_record("2C5：修理 血量 50% < 70% → 要修",
			bool(_model.call("repair_needed", 500.0, 1000.0, 0.7)), "500/1000")
	_record("2C5：修理 血量 80% ≥ 70% → 不修",
			not bool(_model.call("repair_needed", 800.0, 1000.0, 0.7)), "800/1000")

	# --- P1-5 达成归属 ---
	var gr: float = float(_model.call("goal_damage_ratio_of", 300.0, 1000.0))
	_record("2C5：达成归属 伤害占比 = 300/1000 = 0.3（目标 0 血返回 -1）",
			_near(gr, 0.3, 0.0001)
			and float(_model.call("goal_damage_ratio_of", 300.0, 0.0)) == -1.0,
			"%.2f" % gr)

	# --- 接线（文本级：--script 模式不能 load 带 class_name 的脚本）---
	_record("2C5：接线 波次记录有 was_target / goal_last_hit / goal_damage_ratio；调度器有 repair 命令口",
			sa_src.contains("\"was_target\"") and sa_src.contains("\"goal_last_hit\"")
			and sa_src.contains("\"goal_damage_ratio\"")
			and sched_src.contains("func repair(")
			and sa_src.contains("_manage_repair()"),
			"简单AI=%s/%s/%s 调度=%s" % [str(sa_src.contains("\"was_target\"")),
				str(sa_src.contains("\"goal_last_hit\"")),
				str(sa_src.contains("\"goal_damage_ratio\"")),
				str(sched_src.contains("func repair("))])


# ===========================================================================
# O 2C-6：0.4 系数 / B 输出分母 / 修理 200 HP / 农场预判 / 兵营座数 / 移速换算
# ===========================================================================
func _case_2c6() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var UT = load("res://代码/配置/单位表.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var cmd_src: String = FileAccess.get_file_as_string("res://代码/界面/命令卡.gd")
	var foot: UnitDef = _cfg.unit(&"footman")
	var dps: float = float(_model.call("unit_dps", foot))

	# --- P0 系数 0.4 + 命令行可覆盖（1 条）---
	AIV.set_output_coef(0.3)
	var ok_override: bool = _near(float(AIV.output_coef()), 0.3, 0.0001)
	AIV.reset_defaults()
	_record("2C6：系数 0.4 且 --verdict-coef 可覆盖（0.3 生效后回默认）",
			_near(float(AIV.DEFAULT_COEF), 0.4, 0.0001) and ok_override
			and _near(float(AIV.output_coef()), 0.4, 0.0001),
			"默认 %.2f / 覆盖 0.3 / 复位 %.2f" % [
				float(AIV.DEFAULT_COEF), float(AIV.output_coef())])

	# --- P0 输出分母 B（2 条）---
	# 5 人编制里只有 2 人最近出过手 → 分母只算 2 人的纸面 DPS
	var b_out: float = float(_model.call("theory_output_recent", {&"footman": 2}, 10.0, 0.4))
	var a_out: float = float(_model.call("theory_output", {&"footman": 5}, 10.0, 0.4))
	_record("2C6：B 分母 只算最近出过手的成员（5 人编制 / 2 人出手）",
			_near(b_out, dps * 2.0 * 10.0 * 0.4, 0.001) and b_out < a_out,
			"B=%.1f（2×dps×10×0.4）/ A=%.1f（5×dps×10×0.4）" % [b_out, a_out])
	AIV.set_output_theory_mode("all")
	var mode_all: String = String(AIV.output_theory_mode())
	AIV.reset_defaults()
	AIV.set_recent_attack_window(5.0)
	var win5: float = float(AIV.recent_attack_window())
	AIV.reset_defaults()
	_record("2C6：默认口径 recent / 窗口 3.0 s / all 与 5 s 可切（对照用）",
			mode_all == "all" and _near(win5, 5.0, 0.0001)
			and String(AIV.output_theory_mode()) == "recent"
			and _near(float(AIV.recent_attack_window()), 3.0, 0.0001),
			"all=%s / win5=%.1f / 复位 %.1f s" % [mode_all, win5,
				float(AIV.recent_attack_window())])

	# --- P3 修理判据：固定掉血 200 HP（1 条）---
	# 1000 血掉 200：比例口径 80% 不修（2C-5 实测 0 触发的那个死结），新口径要修
	_record("2C6：修理判据 掉血≥200（1000 血掉 200 修 / 掉 199 不修；70% 比例口径不修）",
			bool(_model.call("repair_needed_deficit", 800.0, 1000.0, 200.0))
			and not bool(_model.call("repair_needed_deficit", 801.0, 1000.0, 200.0))
			and not bool(_model.call("repair_needed", 800.0, 1000.0, 0.7))
			and _near(float(AIV.repair_hp_deficit()), 200.0, 0.0001),
			"掉200=%s / 掉199=%s / 70%%口径=%s" % [
				str(bool(_model.call("repair_needed_deficit", 800.0, 1000.0, 200.0))),
				str(bool(_model.call("repair_needed_deficit", 801.0, 1000.0, 200.0))),
				str(bool(_model.call("repair_needed", 800.0, 1000.0, 0.7)))])

	# --- P1 农场预判（2 条：C 占用率 / A 训练量）---
	_record("2C6：农场预判 C：占用 23/32=71.9% 建 / 22/32=68.8% 不建",
			bool(_model.call("pop_occupied_over", 23, 32))
			and not bool(_model.call("pop_occupied_over", 22, 32)),
			"23/32=%s 22/32=%s" % [str(bool(_model.call("pop_occupied_over", 23, 32))),
				str(bool(_model.call("pop_occupied_over", 22, 32)))])
	# 2 兵营 × 60 s ÷ 18 s 平均训练 = 6.67 人 → 余量 13 < 13.33 建，14 不建
	var pred: float = float(_model.call("predicted_trainees_60s", 2, 18.0))
	_record("2C6：农场预判 A：60 s 预计 6.67 兵 ×2 → 余量 13 建 / 14 不建",
			_near(pred, 6.6667, 0.001)
			and bool(_model.call("farm_headroom_low", 13, pred))
			and not bool(_model.call("farm_headroom_low", 14, pred)),
			"预计=%.2f 余量13=%s 余量14=%s" % [pred,
				str(bool(_model.call("farm_headroom_low", 13, pred))),
				str(bool(_model.call("farm_headroom_low", 14, pred)))])

	# --- P2 兵营座数（2 条：公式 / 接线不再用 max_army）---
	_record("2C6：兵营目标 军队 16→2 座 / 17→3 座 / 0→2 座",
			int(_model.call("barracks_want_of", 16)) == 2
			and int(_model.call("barracks_want_of", 17)) == 3
			and int(_model.call("barracks_want_of", 0)) == 2,
			"16=%d 17=%d 0=%d" % [int(_model.call("barracks_want_of", 16)),
				int(_model.call("barracks_want_of", 17)), int(_model.call("barracks_want_of", 0))])
	_record("2C6：接线 兵营目标不再 ceil(max_army/UNITS_PER_BARRACKS)；农场排在兵营之前",
			not sa_src.contains("ceili(float(diff.max_army) / UNITS_PER_BARRACKS)")
			and sa_src.contains("_barracks_want()")
			and sa_src.find("_manage_food(diff, false)") < sa_src.find("_manage_army(diff)"),
			"农场 idx=%d < 兵营 idx=%d" % [
				sa_src.find("_manage_food(diff, false)"), sa_src.find("_manage_army(diff)")])

	# --- 移速换算（1 条：用户填 460，卡里必须是 4.6）---
	var ids: Array = [&"footman", &"archer", &"mage", &"peasant", &"gnoll_warrior", &"gnoll_scout"]
	var speeds: Array = []
	var all_ok: bool = true
	for id in ids:
		var d: UnitDef = _cfg.unit(id)
		if d == null:
			all_ok = false
			continue
		speeds.append(snappedf(d.move_speed, 0.01))
		if d.move_speed >= 20.0 or d.move_speed <= 0.5:
			all_ok = false
	_record("2C6：移速换算 460→4.6（全部单位 <20，无三位数漏写）",
			all_ok and _near(float(_cfg.unit(&"footman").move_speed), 4.6, 0.0001),
			"%s（步兵 %.2f）" % [str(speeds), float(_cfg.unit(&"footman").move_speed)])

	# --- P4 大本营：有成本 / 玩家可建 / AI 不建（接线，1 条）---
	var th_card = UT.get_card(&"townhall")
	_record("2C6：大本营 320 金/125 木 + 建造页含 townhall + AI 固定不建",
			th_card != null and int(th_card.cost_gold) == 320 and int(th_card.cost_wood) == 125
			and cmd_src.contains("&\"townhall\"")
			and sa_src.contains("func can_build_townhall() -> bool:") \
				and sa_src.contains("func can_build_townhall() -> bool:\n\treturn false"),
			"金=%d 木=%d 建造页=%s AI=%s" % [
				int(th_card.cost_gold) if th_card != null else -1,
				int(th_card.cost_wood) if th_card != null else -1,
				str(cmd_src.contains("&\"townhall\"")),
				str(sa_src.contains("func can_build_townhall() -> bool:\n\treturn false"))])


# ===========================================================================
# 工具
# ===========================================================================
func _unit(def: UnitDef, hp: float = -1.0) -> FakeUnit:
	var u := FakeUnit.new()
	u.def = def
	u.hp = float(def.max_hp) if hp < 0.0 else hp
	return u


func _near(a: float, b: float, tol: float) -> bool:
	if not is_finite(a):
		return false
	return absf(a - b) <= tol


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	_detail.append({"name": name, "ok": ok, "detail": detail})
	print("[%s] %s —— %s" % ["PASS" if ok else "FAIL", name, detail])


func _finish(t0: int) -> void:
	var ms: int = Time.get_ticks_msec() - t0
	var report := {
		"通过": _pass, "失败": _fail, "耗时毫秒": ms,
		"结果": "通过" if _fail == 0 else "失败",
		"检查": _detail,
		"需引擎未测": _engine_only,
	}
	print("CONFIG-REGRESSION %s" % JSON.stringify(report))
	quit(0 if _fail == 0 else 1)
