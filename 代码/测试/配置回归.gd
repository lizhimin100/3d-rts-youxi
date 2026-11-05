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
## ★ 不能用 preload 引 战斗模型.gd：--script 模式下 autoload(Cfg) 尚未注册，
##   编译期预加载会拉起 RtsCombat -> Cfg 依赖链并报 "Identifier not found: Cfg"。
##   与本文其它 _case_* 一样，一律运行时 load()。

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
	# 2C-7：固定修理工位 / 军队目标人口约束 / 农场 >90% 急建 / damage_ratio 归一化矩阵
	_case_2c7()
	# 2C-8：动态工位 / 三段时间军队目标 / 农场与训练归因 / 守门
	_case_2c8()
	# 2C-9：三条线部门化 / 诉求结构 / 动作级仲裁 / 兵力预留 / 判定表分布
	_case_2c9()
	# 2C-10：副官双重扣减 / 70% 动态系数 / 可被征用消费 / 判定表诊断 / POP90
	_case_2c10()
	# 2C-11：储蓄 G(t) / 同时做事数 / 紧急白名单 / 工地停滞 / 仲裁接线
	_case_2c11()
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
	_record("2C4/2C8：农民工位 采金8 + 采木2 + 工位2 = 12（总数不变，工位动态）",
			sa_src.contains("PEASANT_GOLD_SOFT_CAP: int = 8")
			and sa_src.contains("PEASANT_WOOD_TARGET: int = 2")
			and sa_src.contains("PEASANT_BUILDER_SLOT: int = 2")
			and sa_src.contains(
				"PEASANT_TOTAL_CAP: int = PEASANT_GOLD_SOFT_CAP + PEASANT_WOOD_TARGET + PEASANT_BUILDER_SLOT"),
			"8 + 2 + 2 = 12")

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
	# 2C-7 P1 覆盖：不传人口时仍是 2C-6 口径（420 s 解除），传人口则取人口上限
	_record("2C5/2C7：军队目标 420 s：不传人口→解除(-1)；人口 24→11（÷2−1）",
			int(_model.call("army_target_of", 1, 1, 419.9, 8)) == 16
			and int(_model.call("army_target_of", 1, 1, 420.0, 8)) == -1
			and int(_model.call("army_target_of", 1, 1, 420.0, 8, 24)) == 11,
			"419.9s=%d / 420s(pop=0)=%d / 420s(pop=24)=%d" % [
				int(_model.call("army_target_of", 1, 1, 419.9, 8)),
				int(_model.call("army_target_of", 1, 1, 420.0, 8)),
				int(_model.call("army_target_of", 1, 1, 420.0, 8, 24))])
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
# P 2C-7：修理工位 / 军队目标人口约束 / 农场 >90% / damage_ratio 归一化矩阵
# ===========================================================================
func _case_2c7() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var bm = load("res://代码/ai/战斗模型.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")

	# --- P0 修理工位（3 条）---
	# ① 工位是**持久状态**（数组），不是每 tick 现算（靠 order 分不清"待命砍树的工位"和"普通伐木工"）
	_record("2C7/2C8：工位持久（_builder_uids 数组、只在空缺/阵亡时补位、默认动态）",
			sa_src.contains("var _builder_uids: Array[int] = []")
			and sa_src.contains("func _builder_units() -> Array:")
			and sa_src.contains("_builder_uids.append(u.get_instance_id())")
			and sa_src.contains("func _builder_count_target() -> int:")
			and bool(AIV.DEFAULT_BUILDER_SLOT) and bool(AIV.builder_slot()),
			"数组持久 + 缺口才补（默认 = %s）" % str(AIV.builder_mode()))
	# ② 工位不被采集抢占：assign 强制采木、rebalance 排除工位
	_record("2C8：工位不被采集/配比抢占（uid 集合排除 + assign 强制采木 + rebalance 排除）",
			sa_src.contains("工位没活就砍树")
			and sa_src.contains("工位不计入金木配比")
			and sa_src.contains("工位永远不在候选池里")
			and sa_src.contains("var slot_uids: Dictionary = {}")
			and sa_src.count("if slot_uids.has(w.get_instance_id()):") >= 2,
			"命中 %d 处 uid 排除" % sa_src.count("if slot_uids.has(w.get_instance_id()):"))
	# ③ 修理归因三分：无工位 / 工位在建造 / 木材不够（2C-6 只有前两类，混在一起看不出根因）
	_record("2C7：修理归因分三类（blocked_no_builder / blocked_builder_busy / blocked_wood）+ 工位角色落盘",
			sa_src.contains("\"blocked_builder_busy\"")
			and sa_src.contains("repair_stats[\"blocked_builder_busy\"]")
			and sa_src.contains("repair_stats[\"builder_role\"]")
			and sa_src.contains("func _builder_role_name() -> String:"),
			"三类计数 + builder_role/builder_swaps")

	# --- P1 军队目标与人口（2 条）---
	# 人口 24（1 大本营）= 24/2−1 = 11；人口 40（+2 农场）= 19，但公式 16 更小 → 取 16
	_record("2C7：军队目标 = min(公式, 人口÷2−1)：pop24→11 / pop40→16（公式优先）",
			int(_model.call("army_target_of", 1, 1, 0.0, 8, 24)) == 11
			and int(_model.call("army_target_of", 1, 1, 0.0, 8, 40)) == 16
			and int(bm.army_pop_limit(24)) == 11
			and int(bm.army_pop_limit(40)) == 19,
			"pop24=%d pop40=%d（上限函数 11/19）" % [
				int(_model.call("army_target_of", 1, 1, 0.0, 8, 24)),
				int(_model.call("army_target_of", 1, 1, 0.0, 8, 40))])
	_record("2C7：420 s 后不解除，改取人口允许值（pop24→11 / pop40→19；不传人口才 -1）",
			int(_model.call("army_target_of", 1, 1, 420.0, 8, 24)) == 11
			and int(_model.call("army_target_of", 1, 1, 420.0, 8, 40)) == 19
			and int(_model.call("army_target_of", 1, 1, 420.0, 8, 0)) == -1,
			"420s: pop24=%d pop40=%d pop0=%d" % [
				int(_model.call("army_target_of", 1, 1, 420.0, 8, 24)),
				int(_model.call("army_target_of", 1, 1, 420.0, 8, 40)),
				int(_model.call("army_target_of", 1, 1, 420.0, 8, 0))])

	# --- P1 农场 >90% 急建（1 条）---
	_record("2C7：人口 >90% 走农场急建（22/24=91.7% 触发 / 21/24=87.5% 不触发）",
			bool(_model.call("pop_occupied_over", 22, 24, 0.9))
			and not bool(_model.call("pop_occupied_over", 21, 24, 0.9))
			and sa_src.contains("const POP_CRITICAL_RATIO: float = 0.9")
			and sa_src.contains("func _pop_critical() -> bool:")
			and sa_src.contains("if headroom >= 4 and not _pop_critical():"),
			"22/24=%s 21/24=%s" % [
				str(bool(_model.call("pop_occupied_over", 22, 24, 0.9))),
				str(bool(_model.call("pop_occupied_over", 21, 24, 0.9)))])

	# --- P5 damage_ratio 归一化（2 条）---
	_record("2C7：raw_damage_all = 承伤 ÷ 全员有效生命（300/900=0.333）；波次记录三字段齐全",
			_near(float(_model.call("raw_damage_ratio", 300.0, 900.0)), 1.0 / 3.0, 0.001)
			and _near(float(_model.call("raw_damage_ratio", 300.0, 300.0)), 1.0, 0.0001)
			and sa_src.contains("rec[\"hp_all_out\"]")
			and sa_src.contains("rec[\"raw_damage_all\"]")
			and sa_src.contains("rec[\"raw_damage_ps\"]"),
			"raw=%.4f（targeted 同数据=1.0）" % float(_model.call("raw_damage_ratio", 300.0, 900.0)))
	var vals: Array = [0.5, 0.95, 0.3, 0.82]
	_record("2C7：窗口命中率 [0.4,0.9] = 2/4；lo↑ 命中率不增、hi↑ 命中率不减（4×4 矩阵可用）",
			_near(float(_model.call("window_hit_ratio", vals, 0.4, 0.9)), 0.5, 0.0001)
			and float(_model.call("window_hit_ratio", vals, 0.5, 0.9))
				<= float(_model.call("window_hit_ratio", vals, 0.4, 0.9))
			and float(_model.call("window_hit_ratio", vals, 0.4, 1.0))
				>= float(_model.call("window_hit_ratio", vals, 0.4, 0.9)),
			"[0.4,0.9]=%.2f [0.5,0.9]=%.2f [0.4,1.0]=%.2f" % [
				float(_model.call("window_hit_ratio", vals, 0.4, 0.9)),
				float(_model.call("window_hit_ratio", vals, 0.5, 0.9)),
				float(_model.call("window_hit_ratio", vals, 0.4, 1.0))])

	# --- 禁止项守门（1 条）：判定表窗口一个字不动 ---
	_record("2C7：判定表窗口未动（时间 0.8/0.5、输出 0.7~1.3、承伤 0.4~0.9）",
			_near(float(bm.VD_TIME_GOOD), 0.8, 0.0001)
			and _near(float(bm.VD_TIME_HALF), 0.5, 0.0001)
			and _near(float(bm.VD_OUT_LOW), 0.7, 0.0001)
			and _near(float(bm.VD_OUT_HIGH), 1.3, 0.0001)
			and _near(float(bm.VD_DMG_LOW), 0.4, 0.0001)
			and _near(float(bm.VD_DMG_HIGH), 0.9, 0.0001),
			"%.1f/%.1f %.1f~%.1f %.1f~%.1f" % [
				float(bm.VD_TIME_GOOD), float(bm.VD_TIME_HALF),
				float(bm.VD_OUT_LOW), float(bm.VD_OUT_HIGH),
				float(bm.VD_DMG_LOW), float(bm.VD_DMG_HIGH)])

	# --- 审计选人守门（1 条）：这一条是踩出来的 ---
	# 第一版把 `find_builder` 指向 `_pick_builder`，结果副官自检 E 组连红 3 条：
	# "停滞工地正好是工位自己盖的 → 工位在建造 → 审计拿不到人 → 立案失败"。
	_record("2C7：审计选人允许工位在建造（find_builder 指向 _pick_sanity_builder）",
			sa_src.contains("\"find_builder\": Callable(self, \"_pick_sanity_builder\")")
			and sa_src.contains("func _pick_sanity_builder() -> RtsUnit:"),
			"副官 E 组：停滞工地能拿到人（救火不受建造状态阻挡）")


# ===========================================================================
# Q 2C-8：动态工位 / 三段时间军队目标 / 农场与训练归因 / 守门
# ===========================================================================
func _case_2c8() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var bm = load("res://代码/ai/战斗模型.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var bench_src: String = FileAccess.get_file_as_string("res://代码/测试/AI基准.gd")

	# --- P0 工位动态（4 条）---
	var bc: Array = [0, 1, 6, 12, 13, 18, 19].map(func(n): return int(bm.builder_count_for(int(n))))
	_record("2C8：工位数 max(2, ceil(N/6))：0→0 / 6→2 / 12→2 / 13→3 / 18→3 / 19→4",
			bc == [0, 2, 2, 2, 3, 3, 4], "%s（N=0/1/6/12/13/18/19）" % str(bc))
	_record("2C8：同时建造上限 = 工位数−1（2→1 / 3→2 / 1→0 / 0→0）",
			int(bm.builder_build_limit(2)) == 1 and int(bm.builder_build_limit(3)) == 2
			and int(bm.builder_build_limit(1)) == 0 and int(bm.builder_build_limit(0)) == 0,
			"2→%d 3→%d 1→%d" % [int(bm.builder_build_limit(2)),
				int(bm.builder_build_limit(3)), int(bm.builder_build_limit(1))])
	_record("2C8：接线 _pick_builder 用**目标工位数**算上限（不按实际指派数，开局 1 人也能盖）",
			sa_src.contains("var limit: int = int(_model_call(\"builder_build_limit\", [_builder_count_target()]))")
			and sa_src.contains("if n_build >= limit:")
			and sa_src.contains("func _builder_count_target() -> int:"),
			"limit = builder_build_limit(目标) / n_build >= limit → null")
	_record("2C8：工位补位顺序 正在建造 → 采木 → 任意（同一 tick 不重复挑人）",
			sa_src.contains("for pool in [building_now, wood_pick, any_pick]:")
			and sa_src.contains("if seen.has(uid3):")
			and sa_src.contains("var _builder_uids: Array[int] = []"),
			"三池顺序补位 + seen 去重")

	# --- 配比（2 条）---
	var w1: int = int(bm.peasant_gold_want_dynamic(12, 2, 8))
	var w2: int = int(bm.peasant_gold_want_dynamic(15, 3, 8))
	var w3: int = int(bm.peasant_gold_want_dynamic(6, 2, 8))
	var w4: int = int(bm.peasant_gold_want_dynamic(2, 2, 8))
	_record("2C8：采金 min(8, N−工位)：12/2→8、15/3→8、6/2→4、2/2→0",
			w1 == 8 and w2 == 8 and w3 == 4 and w4 == 0,
			"12/2=%d 15/3=%d 6/2=%d 2/2=%d" % [w1, w2, w3, w4])
	_record("2C8：配比守恒 gold + wood = N − 工位（采木 = 余量，不封顶）",
			(w1 + (12 - 2 - w1)) == 10 and (w2 + (15 - 3 - w2)) == 12
			and (w3 + (6 - 2 - w3)) == 4,
			"wood: 12/2→%d 15/3→%d 6/2→%d" % [12 - 2 - w1, 15 - 3 - w2, 6 - 2 - w3])

	# --- 军队目标（5 条；10/12/14/16 分钟各一条 + 两段边界）---
	_record("2C8：第 1 段 <480s：12+3B+P（0/479s，1B1P=16）",
			int(bm.army_target_2c8(1, 1, 0.0)) == 16
			and int(bm.army_target_2c8(1, 1, 479.9)) == 16,
			"0s=%d 479.9s=%d" % [int(bm.army_target_2c8(1, 1, 0.0)),
				int(bm.army_target_2c8(1, 1, 479.9))])
	_record("2C8：第 2 段 480~599s：13+4B+2P（480/599.9s，1B1P=19）",
			int(bm.army_target_2c8(1, 1, 480.0)) == 19
			and int(bm.army_target_2c8(1, 1, 599.9)) == 19,
			"480s=%d 599.9s=%d" % [int(bm.army_target_2c8(1, 1, 480.0)),
				int(bm.army_target_2c8(1, 1, 599.9))])
	_record("2C8：第 3 段 10 min（600s）：14+5B+3P，1B2P=25",
			int(bm.army_target_2c8(1, 2, 600.0)) == 25
			and int(bm.army_target_2c8(1, 2, 719.9)) == 25,
			"600s=%d 719.9s=%d" % [int(bm.army_target_2c8(1, 2, 600.0)),
				int(bm.army_target_2c8(1, 2, 719.9))])
	_record("2C8：每 2 分钟全项 +1：12min=29 / 14min=33 / 16min=37（1B2P，步长 1+B+P=4）",
			int(bm.army_target_2c8(1, 2, 720.0)) == 29
			and int(bm.army_target_2c8(1, 2, 840.0)) == 33
			and int(bm.army_target_2c8(1, 2, 960.0)) == 37,
			"720=%d 840=%d 960=%d" % [int(bm.army_target_2c8(1, 2, 720.0)),
				int(bm.army_target_2c8(1, 2, 840.0)), int(bm.army_target_2c8(1, 2, 960.0))])
	_record("2C8：目标不与人口挂钩（无基地 12/13/14）+ 接线保留防守下限 + 开关默认 new",
			int(bm.army_target_2c8(0, 0, 0.0)) == 12
			and int(bm.army_target_2c8(0, 0, 480.0)) == 13
			and int(bm.army_target_2c8(0, 0, 600.0)) == 14
			and sa_src.contains("t = maxi(t, _defense_floor())")
			and sa_src.contains("if AIV.army_target_formula() == \"new\":")
			and String(AIV.DEFAULT_ARMY_TARGET_FORMULA) == "new"
			and String(AIV.army_target_formula()) == "new",
			"0/480/600s = 12/13/14，默认公式 %s" % String(AIV.army_target_formula()))

	# --- 诊断（3 条；只读）---
	_record("2C8：农场归因四因（no_builder / no_wood / no_spot / lost）+ lost 工地快照结算",
			sa_src.contains("\"no_builder\": 0, \"no_wood\": 0, \"no_gold\": 0, \"no_spot\": 0, \"lost\": 0")
			and sa_src.contains("func _note_farm_fail(reason: String)")
			and sa_src.contains("_note_farm_fail(\"no_builder\")")
			and sa_src.contains("_note_farm_fail(\"no_spot\")")
			and sa_src.contains("_note_farm_fail(\"no_wood\")")
			and sa_src.contains("func _tick_build_diag() -> void:")
			and sa_src.contains("farm_fail_stats[\"lost\"]"),
			"四因计数 + _farm_sites 快照")
	_record("2C8：训练阻塞每 60 s 采样（no_gold/no_wood/no_pop/queue_full/no_producer/ok）",
			sa_src.contains("const TRAIN_DIAG_SEC: float = 60.0")
			and sa_src.contains("func _sample_train_block(diff: DifficultyDef) -> void:")
			and sa_src.contains("_sample_train_block(diff)")
			and sa_src.contains("\"no_gold\": 0, \"no_wood\": 0, \"no_pop\": 0, \"queue_full\": 0, \"no_producer\": 0")
			and sa_src.contains("func _classify_train_block(diff: DifficultyDef) -> String:"),
			"60 s 采样 + 六类归因")
	_record("2C8：bench 落盘 labor / farm_fail / train_block + 曲线含 builders/gather/busy",
			bench_src.contains("n.get(\"labor_stats\")")
			and bench_src.contains("n.get(\"farm_fail_stats\")")
			and bench_src.contains("n.get(\"train_stats\")")
			and bench_src.contains("\"builders\": slots_target")
			and bench_src.contains("\"gather_gold\": gold_w")
			and bench_src.contains("\"builder_busy\": busy_w")
			and bench_src.contains("\"concurrent_repair_samples\""),
			"labor+两归因+三条曲线")

	# --- 守门（1 条）：本轮禁止改的判定参数一个都不许动 ---
	_record("2C8：不变式守门（窗口 0.8/0.5、0.7~1.3、0.4~0.9；系数 0.4；修理 200；gap 3.0）",
			_near(float(bm.VD_TIME_GOOD), 0.8, 0.0001)
			and _near(float(bm.VD_TIME_HALF), 0.5, 0.0001)
			and _near(float(bm.VD_OUT_LOW), 0.7, 0.0001)
			and _near(float(bm.VD_OUT_HIGH), 1.3, 0.0001)
			and _near(float(bm.VD_DMG_LOW), 0.4, 0.0001)
			and _near(float(bm.VD_DMG_HIGH), 0.9, 0.0001)
			and _near(float(bm.THEORY_OUTPUT_COEF), 0.4, 0.0001)
			and _near(float(AIV.repair_hp_deficit()), 200.0, 0.0001)
			and _near(float(AIV.combat_gap_sec()), 3.0, 0.0001),
			"判定窗口/系数/修理线/断档全部未动")


# ===========================================================================
# R 2C-9：三条线部门化 / 诉求结构 / 动作级仲裁 / 兵力预留 / 判定表分布
# ===========================================================================
func _case_2c9() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var bm = load("res://代码/ai/战斗模型.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var bench_src: String = FileAccess.get_file_as_string("res://代码/测试/AI基准.gd")

	# ---------- 诉求结构字段完整性（8 条）----------
	var want_fields: Array = ["来源线", "动作类型", "目标", "金币成本", "木材成本",
		"兵力占用", "可被征用", "诉求分", "依据", "驳回原因"]
	_record("2C9：诉求结构恰好 10 个必带字段（与任务书 §3.1 逐字一致）",
			Array(bm.DEMAND_FIELDS) == want_fields,
			"%d 项：%s" % [Array(bm.DEMAND_FIELDS).size(), str(bm.DEMAND_FIELDS)])
	var d0: Dictionary = bm.demand_make("运营线", "训练", "步兵", 125, 0, 0, false,
			3.5, "军队缺口=3", true)
	var missing: Array = []
	for f in want_fields:
		if not d0.has(f):
			missing.append(f)
	_record("2C9：demand_make 产出的字典一个字段都不少",
			missing.is_empty(), "缺 %d 个：%s" % [missing.size(), str(missing)])
	_record("2C9：三条线枚举齐全（运营线/战斗线/扩展线）",
			Array(bm.DEP_SOURCES) == ["运营线", "战斗线", "扩展线"],
			str(bm.DEP_SOURCES))
	_record("2C9：九个动作类型齐全（训练/建造/修理/出击/防守/侦查/巡逻/建塔/建分基地）",
			Array(bm.ACT_TYPES) == ["训练", "建造", "修理", "出击", "防守",
				"侦查", "巡逻", "建塔", "建分基地"],
			"%d 项" % Array(bm.ACT_TYPES).size())
	_record("2C9/2C11：八个驳回原因枚举齐全（原 6 + 储备不足 / 并发上限）",
			Array(bm.RJ_REASONS) == ["金币不足", "木材不足", "兵力不足",
				"被更高分压后", "条件不满足", "本周期已执行",
				"储备不足", "并发上限"],
			"%d 项" % Array(bm.RJ_REASONS).size())
	_record("2C9：demand_valid 合法诉求 → true（十个字段齐全 + 枚举合法 + 成本非负）",
			bool(bm.demand_valid(d0)), "训练/步兵/125 金")
	var d_bad: Dictionary = d0.duplicate(true)
	d_bad.erase("依据")
	_record("2C9：demand_valid 缺字段 → false",
			not bool(bm.demand_valid(d_bad)), "删掉「依据」")
	var d_bad2: Dictionary = d0.duplicate(true)
	d_bad2["来源线"] = "后勤线"
	_record("2C9：demand_valid 非法来源线 / 负成本 → false",
			not bool(bm.demand_valid(d_bad2))
			and not bool(bm.demand_valid(_demand_gold(d0, -1))),
			"来源线「后勤线」/ 金币 −1")

	# ---------- 仲裁：排序 + 金币/木材/兵力扣减（6 条）----------
	var a1: Dictionary = bm.demand_make("运营线", "建造", "农场", 120, 25, 0, false, 1.0, "农场缺口=1")
	var a2: Dictionary = bm.demand_make("运营线", "训练", "步兵", 125, 0, 0, false, 5.0, "军队缺口=5")
	var a3: Dictionary = bm.demand_make("扩展线", "巡逻", "基地外圈", 0, 0, 2, true, 1.0, "巡逻 2 人")
	var p1: Dictionary = bm.arbitrate([a1, a2, a3], 400, 100, 8)
	var exec_names: Array = []
	for d in (p1["执行"] as Array):
		exec_names.append(String((d as Dictionary)["动作类型"]))
	_record("2C9：仲裁按诉求分降序（训练5.0 → 农场1.0 → 巡逻1.0，同分按提交顺序）",
			exec_names == ["训练", "建造", "巡逻"],
			"执行顺序 %s" % str(exec_names))
	_record("2C9：金币/木材/兵力都够 → 同周期**都执行**（不是只做一个）",
			(p1["执行"] as Array).size() == 3
			and int(p1["金币余"]) == 400 - 125 - 120
			and int(p1["木材余"]) == 100 - 25
			and int(p1["兵力余"]) == 8 - 2,
			"执行3条，余金%d/木%d/兵%d" % [int(p1["金币余"]), int(p1["木材余"]), int(p1["兵力余"])])
	var p2: Dictionary = bm.arbitrate([a1, a2], 200, 100, 8)
	var exec2: Array = p2["执行"] as Array
	_record("2C9：金币只够一个 → 高分先执行，低分驳回（不是随机/不分次序）",
			exec2.size() == 1 and String((exec2[0] as Dictionary)["动作类型"]) == "训练"
			and String((p2["驳回"] as Array)[0]["驳回原因"]) in ["被更高分压后", "金币不足"],
			"执行=%s 驳回=%s" % [
				String((exec2[0] as Dictionary)["动作类型"]),
				String((p2["驳回"] as Array)[0]["驳回原因"])])
	var a_wood: Dictionary = bm.demand_make("运营线", "建造", "农场", 0, 90, 0, false, 2.0, "木材贵")
	var p3: Dictionary = bm.arbitrate([a_wood], 500, 40, 8)
	_record("2C9：木材独立扣减（金够木不够 → 木材不足，不动金币余额）",
			(p3["执行"] as Array).is_empty()
			and String((p3["驳回"] as Array)[0]["驳回原因"]) == "木材不足"
			and int(p3["金币余"]) == 500,
			"驳回=%s 金余%d" % [String((p3["驳回"] as Array)[0]["驳回原因"]), int(p3["金币余"])])
	var t1: Dictionary = bm.demand_make("战斗线", "出击", "AI·2队", 0, 0, 5, false, 9.0, "出击5人")
	var t2: Dictionary = bm.demand_make("扩展线", "巡逻", "外围", 0, 0, 3, true, 1.0, "巡逻3人")
	var p4: Dictionary = bm.arbitrate([t1, t2], 0, 0, 6)
	_record("2C9：兵力扣减（6 个兵：出击 5 → 巡逻 3 兵力不足）",
			(p4["执行"] as Array).size() == 1 and int(p4["兵力余"]) == 1
			and String((p4["驳回"] as Array)[0]["驳回原因"]) in ["被更高分压后", "兵力不足"],
			"兵余%d 驳回=%s" % [int(p4["兵力余"]),
				String((p4["驳回"] as Array)[0]["驳回原因"])])
	var dup1: Dictionary = bm.demand_make("运营线", "训练", "步兵", 0, 0, 0, false, 2.0, "同一座兵营")
	var dup2: Dictionary = bm.demand_make("运营线", "训练", "步兵", 0, 0, 0, false, 1.0, "同一座兵营")
	var p5: Dictionary = bm.arbitrate([dup1, dup2], 500, 500, 8)
	_record("2C9：同 (线,动作,目标) 在一次周期里只执行一次 → 后来者「本周期已执行」",
			(p5["执行"] as Array).size() == 1
			and String((p5["驳回"] as Array)[0]["驳回原因"]) == "本周期已执行",
			"执行1 驳回=%s" % String((p5["驳回"] as Array)[0]["驳回原因"]))

	# ---------- 兵力预留制（5 条）----------
	var al1: Dictionary = bm.troop_allocate(3, 8, 2, 4)
	_record("2C9：兵力扣减顺序 防守锁定 > 临时防守可征用 > 空闲（3=临时2+空闲1）",
			bool(al1["够"]) and int(al1["临时防守"]) == 2 and int(al1["空闲"]) == 1
			and int(al1["防守锁定"]) == 8,
			"临时%d 空闲%d 锁定%d" % [int(al1["临时防守"]), int(al1["空闲"]), int(al1["防守锁定"])])
	var al2: Dictionary = bm.troop_allocate(9, 8, 2, 4)
	_record("2C9：可用兵力不足 → 够=false（不预扣、不超发）",
			not bool(al2["够"]) and int(al2["可用"]) == 6,
			"可用%d < 需要 9" % int(al2["可用"]))
	var al3: Dictionary = bm.troop_allocate(0, 8, 2, 4)
	_record("2C9：不占兵力的诉求（修建/训练）永远够，且不消耗临时防守",
			bool(al3["够"]) and int(al3["临时防守"]) == 0 and int(al3["空闲"]) == 0,
			"需要 0")
	_record("2C9：接线 锁定/解锁/到期清扫 + 可用兵力 = 现役 − 防守锁定 − 已锁",
			sa_src.contains("func _troop_lock(")
			and sa_src.contains("func _troop_unlock(")
			and sa_src.contains("func _troop_lock_tick(")
			and sa_src.contains("_troop_unlock(\"wave:%d\" % int(rec.get(\"wave_id\", 0)), true)")
			and sa_src.contains("func _troop_available() -> int:")
			and sa_src.contains("func _defense_reserved(army_n: int) -> int:"),
			"wave 锁在 _close_wave 里显式解锁")
	_record("2C9：锁定泄漏口径（wave 锁超时 = 泄漏信号；巡逻/侦查是短租约不算）",
			sa_src.contains("lock_wave_released")
			and sa_src.contains("lock_wave_timeout")
			and sa_src.contains("if kind == \"wave\":")
			and bench_src.contains("泄漏%d"),
			"lock_wave_held - released - timeout = 泄漏")

	# ---------- 驳回原因（3 条）----------
	var b1: Dictionary = bm.demand_make("运营线", "建造", "农场", 300, 0, 0, false, 1.0, "没钱")
	var pb1: Dictionary = bm.arbitrate([b1], 100, 0, 0)
	_record("2C9：驳回原因 周期开始就不够 → 金币不足（不是「被更高分压后」）",
			String((pb1["驳回"] as Array)[0]["驳回原因"]) == "金币不足",
			"金 100 需要 300")
	var pb2: Dictionary = bm.arbitrate([a2, a1], 130, 100, 8)
	_record("2C9：驳回原因 周期开始够、被更高分吃掉 → 被更高分压后",
			String((pb2["驳回"] as Array)[0]["驳回原因"]) == "被更高分压后",
			"金 130：训练 125 先走 → 农场 120 被压后")
	var b3: Dictionary = bm.demand_make("运营线", "建造", "农场", 0, 0, 0, false, 9.0, "没有位置", false)
	var pb3: Dictionary = bm.arbitrate([b3], 999, 999, 8)
	_record("2C9：驳回原因 部门自己判「做不了」→ 条件不满足（且不扣资源）",
			String((pb3["驳回"] as Array)[0]["驳回原因"]) == "条件不满足"
			and int(pb3["金币余"]) == 999,
			"可执行=false，金余 999")

	# ---------- 上下文 L0~L3（4 条）----------
	_record("2C9：L0 快照字段齐全（金/木/人口上限/人口占用/兵力/阶段/威胁）",
			sa_src.contains("\"pop_cap\": _faction.food_cap()")
			and sa_src.contains("\"pop_used\": _faction.food_used()")
			and sa_src.contains("\"阶段\": \"夜晚\" if Game.is_night() else \"白天\"")
			and sa_src.contains("\"threat\": int(metrics.get(\"base_threat\", 0.0))"),
			"ctx0 每 tick 覆盖写")
	_record("2C9：L1 是固定长度环形槽（受伤 30 s / 收支 60 s / 最近 3 波），不存事件列表",
			sa_src.contains("const L1_DMG_SEC: int = 30")
			and sa_src.contains("const L1_INCOME_SEC: int = 60")
			and sa_src.contains("const L1_VERDICT_N: int = 3")
			and sa_src.contains("_l1_dmg[sec % L1_DMG_SEC] = 0.0")
			and sa_src.contains("\"dmg_30s\": dmg30"),
			"槽位覆盖 + O(1)")
	_record("2C9：L2 每 2 s 全量重建（不跨周期累积）",
			sa_src.contains("const DEPT_CYCLE: float = 2.0")
			and sa_src.contains("demands_l2 = _ops_demands(diff)")
			and sa_src.contains("demands_l2.append_array(_combat_demands(diff))")
			and _near(float(bm.DEPT_CYCLE_SEC), 2.0, 0.0001),
			"赋值 = 重建，不是 append")
	_record("2C9：L3 决策日志只落盘不进决策（_dept_log 在仲裁之后调用）",
			sa_src.contains("func _dept_log(now: float, plan: Dictionary) -> void:")
			and sa_src.contains("_dept_execute(plan)\n\t_dept_log(now, plan)")
			and sa_src.contains("fa.store_line(JSON.stringify(row))"),
			"--dept-log 落 jsonl")

	# ---------- 判定表分布落盘（3 条）----------
	var rec_ach: Dictionary = {"goal_achieved": true, "combat_time": 0.0,
		"theory_time": 40.0, "output_eff": 0.0, "damage_ratio": 0.0,
		"survivors": 0, "strength": 10}
	var bins_ach: Dictionary = bm.judge_bins(rec_ach)
	_record("2C9：判据分布 目标达成 → 四样判据全部记「达成」",
			String(bins_ach["判据1"]) == "达成" and String(bins_ach["判据2"]) == "达成"
			and String(bins_ach["判据3"]) == "达成" and String(bins_ach["判据4"]) == "达成",
			str(bins_ach))
	var rec_bad: Dictionary = {"goal_achieved": false, "combat_time": 10.0,
		"theory_time": 40.0, "output_eff": 0.5, "damage_ratio": 0.2,
		"survivors": 2, "strength": 10}
	var rec_und: Dictionary = {"goal_achieved": false, "combat_time": 10.0,
		"theory_time": 40.0, "output_eff": 0.5, "damage_ratio": 0.2,
		"survivors": 8, "strength": 10}
	var bins_bad: Dictionary = bm.judge_bins(rec_bad)
	var bins_und: Dictionary = bm.judge_bins(rec_und)
	_record("2C9：判据1（战斗时间）<0.5：崩→差 / 没崩→未判（沿用 2C-4 放宽规则）",
			String(bins_bad["判据1"]) == "差" and String(bins_und["判据1"]) == "未判",
			"存活2/10→%s，存活8/10→%s" % [String(bins_bad["判据1"]), String(bins_und["判据1"])])
	var counts: Dictionary = bm.judge_bin_counts([{"判据": bins_bad}, {"判据": bins_ach}], "判据1")
	_record("2C9：judge_bin_counts 五档齐全（达成/好/一般/差/未判，缺省 0）",
			counts.has("达成") and counts.has("好") and counts.has("一般")
			and counts.has("差") and counts.has("未判")
			and int(counts["差"]) == 1 and int(counts["达成"]) == 1,
			str(counts))
	_record("2C9：bench 落盘 JUDGE-DIST（每局每阵营一行 + 合计一行）+ 每波含四样判据",
			bench_src.contains("print(\"JUDGE-DIST %s\"")
			and bench_src.contains("c[\"判据\"] = _bench_model.judge_bins(c)")
			and bench_src.contains("\"judge_dist\": judge_dist")
			and bench_src.contains("c[\"零伤害\"]"),
			"JUDGE-DIST + 判据 + 零伤害")

	# ---------- 并发修理探针转正（2 条）----------
	_record("2C9：并发修理探针入库（简单AI.qa_repair_probe 断言 2/2/2/2）",
			sa_src.contains("func qa_repair_probe() -> Dictionary:")
			and sa_src.contains("maxf(float(rb2.def.max_hp) - 250.0, 1.0)")
			and sa_src.contains("list.size() == 2 and repairing == 2")
			and sa_src.contains("and distinct.size() == 2 and issued == 2"),
			"两栋各掉 250 → targets/repairing/distinct/issued 全 2")
	_record("2C9：探针由 `--qa-repair-probe[=秒]` 定点触发并打印 PROBE-2C9-REPAIR",
			bench_src.contains("--qa-repair-probe")
			and bench_src.contains("PROBE-2C9-REPAIR")
			and bench_src.contains("n.call(\"qa_repair_probe\")"),
			"定点 + 一行 JSON")

	# ---------- 系数卡 + 开关 + 守门（4 条）----------
	var coef_card: Resource = load("res://代码/配置/卡/AI诉求系数.tres")
	var coef_ok: bool = coef_card != null
	var coef_names: Array = ["训练_威胁系数", "训练_缺口系数", "建造_农场缺口系数",
		"建造_农场紧迫系数", "建造_兵营缺口系数", "建造_兵营紧迫系数", "修理_掉血系数",
		"出击_兵力比系数", "防守_威胁系数", "侦查_固定分", "巡逻_固定分", "建塔_固定分",
		"分基地_固定分"]
	var coef_bad: Array = []
	if coef_card != null:
		for nm in coef_names:
			var v = coef_card.get(nm)
			# 2C-10：13 个系数已标定一轮，不再要求 =1.0；只要求"在卡里且为有限正数"
			if v == null or not is_finite(float(v)) or float(v) <= 0.0:
				coef_bad.append(nm)
	_record("2C9/2C10：诉求分系数卡 13 个系数齐备且为有限正数（2C-10 已标定，不再要求 =1.0）",
			coef_ok and coef_bad.is_empty(),
			"缺/非正数：%s" % str(coef_bad))
	_record("2C9/2C11：demand_coef 读代码 defaults()（缺键回落，不再读 .tres）",
			_near(float(bm.demand_coef("训练_威胁系数")), 0.8, 0.000001)
			and _near(float(bm.demand_coef("不存在的键", 0.7)), 0.7, 0.000001),
			"训练_威胁系数=0.8；未知键回落 0.7")
	_record("2C9：dept 开关 on/off（默认 on；非法值回落 on）",
			String(AIV.DEFAULT_DEPT_MODE) == "on"
			and String(AIV.dept_mode()) == "on"
			and bool(AIV.dept_on())
			and String(AIV.set_dept_mode("乱写")) == "on",
			"默认 %s" % String(AIV.dept_mode()))
	_record("2C9：不变式守门（判定表窗口/系数/分母/修理线/gap 一个字没动）",
			_near(float(bm.VD_TIME_GOOD), 0.8, 0.0001)
			and _near(float(bm.VD_TIME_HALF), 0.5, 0.0001)
			and _near(float(bm.VD_OUT_LOW), 0.7, 0.0001)
			and _near(float(bm.VD_OUT_HIGH), 1.3, 0.0001)
			and _near(float(bm.VD_DMG_LOW), 0.4, 0.0001)
			and _near(float(bm.VD_DMG_HIGH), 0.9, 0.0001)
			and _near(float(bm.THEORY_OUTPUT_COEF), 0.4, 0.0001)
			and _near(float(AIV.repair_hp_deficit()), 200.0, 0.0001)
			and _near(float(AIV.combat_gap_sec()), 3.0, 0.0001)
			and _near(float(AIV.output_coef()), 0.4, 0.0001)
			and String(AIV.damage_theory_mode()) == "targeted"
			and String(AIV.output_theory_mode()) == "recent"
			and sa_src.contains("func can_build_townhall() -> bool:\n\treturn false"),
			"窗口 0.8/0.5、0.7~1.3、0.4~0.9；系数 0.4；targeted/recent；修理 200；gap 3.0；大本营仍 false")


# ===========================================================================
# 2C-10：P0-A 双重扣减 / P0-B 70% 动态系数 / 可被征用消费 / B 诊断 / POP90
# ===========================================================================
func _case_2c10() -> void:
	var AIV = load("res://代码/配置/AI判定模式.gd")
	var bm = load("res://代码/ai/战斗模型.gd")
	var sa_src: String = FileAccess.get_file_as_string("res://代码/ai/简单AI.gd")
	var bench_src: String = FileAccess.get_file_as_string("res://代码/测试/AI基准.gd")
	var card: Resource = load("res://代码/配置/卡/AI诉求系数.tres")

	# ---------- P0-A：防守下限只扣一次（3 条）----------
	var pa0: int = int(bm.troop_available(8, 8, 0))
	var pa1: int = int(bm.troop_available(12, 8, 0))
	var pa2: int = int(bm.troop_available(12, 8, 2))
	_record("2C10 P0-A：可用兵力只扣一次下限（=下限→0 不为负 / >下限→现役−下限 / 再扣已锁）",
			pa0 == 0 and pa0 >= 0 and pa1 == 4 and pa2 == 2,
			"8/8=%d，12/8=%d，12/8/锁2=%d" % [pa0, pa1, pa2])
	_record("2C10 P0-A：接线 仲裁池改用 _troop_available_raw()（不扣下限）",
			sa_src.contains("func _troop_available_raw() -> int:")
			and sa_src.contains("return maxi(army_n - locks, 0)")
			and sa_src.contains("var t_avail: int = _troop_available_raw()")
			and sa_src.contains("func _troop_available() -> int:"),
			"下限只由 normal_push_n / bank_push_n 在出击规模里扣")
	var d_patrol: Dictionary = bm.demand_make("扩展线", "巡逻", "基地外圈",
			0, 0, 1, true, 0.6, "回归用例")
	var p_patrol: Dictionary = bm.arbitrate([d_patrol], 0, 0, 8)
	_record("2C10 P0-A：现役=下限(8) 时 raw 池=8 → 巡逻能出击（旧双重扣减恒判「兵力不足」）",
			(p_patrol["执行"] as Array).size() == 1,
			"执行%d 驳回%d" % [(p_patrol["执行"] as Array).size(),
				(p_patrol["驳回"] as Array).size()])

	# ---------- P0-B：70% 人口压力动态系数（5 条）----------
	var f70: float = float(bm.farm_pressure_factor(0.70))
	var f85: float = float(bm.farm_pressure_factor(0.85))
	var f100: float = float(bm.farm_pressure_factor(1.00))
	var f50: float = float(bm.farm_pressure_factor(0.50))
	var f120: float = float(bm.farm_pressure_factor(1.20))
	_record("2C10 P0-B：系数四点 70%→1.0 / 85%→2.0 / 100%→3.0 / 50%→1.0 / 120% 截断 3.0",
			_near(f70, 1.0, 0.0001) and _near(f85, 2.0, 0.0001)
			and _near(f100, 3.0, 0.0001) and _near(f50, 1.0, 0.0001)
			and _near(f120, 3.0, 0.0001),
			"%.2f / %.2f / %.2f / %.2f / %.2f" % [f70, f85, f100, f50, f120])
	var r68: float = float(bm.pop_pressure(68, 0, 100))
	var r72: float = float(bm.pop_pressure(68, 4, 100))
	var r0: float = float(bm.pop_pressure(10, 2, 0))
	_record("2C10 P0-B：占用率含在训人口（68%→1.0；在训 2 人×2 →72%→>1.0；cap=0 不除零）",
			_near(r68, 0.68, 0.0001) and _near(r72, 0.72, 0.0001)
			and _near(float(bm.farm_pressure_factor(r68)), 1.0, 0.0001)
			and float(bm.farm_pressure_factor(r72)) > 1.0 and _near(r0, 0.0, 0.0001),
			"68%%=%.2f / 72%%=%.2f / cap0=%.2f" % [r68, r72, r0])
	var thr_v: float = float(card.get("人口压力_阈值")) if card != null else -1.0
	var k_v: float = float(card.get("人口压力_k")) if card != null else -1.0
	_record("2C10 P0-B：第 18 张卡新增第 14/15 项（阈值 0.70 / k=2.0）可调",
			_near(thr_v, 0.70, 0.0001) and _near(k_v, 2.0, 0.0001),
			"阈值=%.2f k=%.2f" % [thr_v, k_v])
	_record("2C10 P0-B：系数**只**乘农场建造诉求分（兵营/哨塔/修理/训练不动）",
			sa_src.find("farm_pressure_factor") == sa_src.rfind("farm_pressure_factor")
			and sa_src.contains("float(_model_call(\"demand_score_build\", [1, fs, 0, 1.0])) * pf"),
			"代码里只有 1 处 farm_pressure_factor；农场诉求分 = 原分 × pf")
	_record("2C10 P0-B：不改农场预判/人口逻辑（_farm_urgent 仍只读 food_used，未掺在训）",
			sa_src.contains("var headroom: int = _faction.food_cap() - _faction.food_used()")
			and sa_src.contains("func _farm_urgent() -> bool:"),
			"90% 响应测试是纯观测，不为凑触发改预判")

	# ---------- §6：可被征用消费（3 条）----------
	var lk: Dictionary = {
		"wave:1": {"n": 5, "k": "wave", "t": 999.0},
		"temp_defense": {"n": 2, "k": "temp_defense", "t": 999.0},
		"patrol": {"n": 1, "k": "patrol", "t": 999.0},
	}
	var q: Dictionary = bm.requisition_quota(lk)
	_record("2C10 §6：征用配额（临时防守2+巡逻1=3；wave 锁不可自征）",
			int(q["可征用"]) == 3 and (q["释放键"] as Array).size() == 2
			and not (q["释放键"] as Array).has("wave:1"),
			"可征用=%d 释放键=%s" % [int(q["可征用"]), str(q["释放键"])])
	_record("2C10 §6：接线 征用→出击兵力+N→转 wave 锁→波次收尾显式解锁",
			sa_src.contains("func _requisition_temp_defense() -> int:")
			and sa_src.contains("req_n = _requisition_temp_defense()")
			and sa_src.contains("p[\"push_n\"] = int(p.get(\"push_n\", 0)) + _pending_requisition")
			and sa_src.contains("var t: int = int(dd.get(\"兵力占用\", 0)) + req_n")
			and sa_src.contains("_troop_unlock(\"wave:%d\" % int(rec.get(\"wave_id\", 0)), true)"),
			"释放短租约锁 → +N 出击 → 锁随波次收尾")
	_record("2C10 §6：临时防守锁由回防动作创建（固定 key 不累积）",
			sa_src.contains("_troop_lock(\"temp_defense\", int(p.get(\"n\", 0)), DEPT_CYCLE * 3.0, \"temp_defense\")")
			and sa_src.contains("\"requisition_times\": 0, \"requisitioned_units\": 0,"),
			"可被征用 从「只写不消费」变成有计数")

	# ---------- B 诊断 + POP90 字段（3 条）----------
	var drec: Dictionary = {"goal_achieved": false, "combat_time": 20.0,
		"theory_time": 40.0, "output_eff": 0.9, "damage_ratio": 0.5,
		"survivors": 6, "strength": 10}
	var jd: Dictionary = bm.judge_diag(drec)
	var d1: Dictionary = jd["判据1"]
	_record("2C10 B：judge_diag 给原始值+档位边界+边界距离+落档（不改窗口）",
			jd.has("判据1") and jd.has("判据2") and jd.has("判据3") and jd.has("判据4")
			and _near(float(d1["值"]), 0.5, 0.0001)
			and _near(float((d1["边界"] as Array)[0]), 0.5, 0.0001)
			and _near(float((d1["边界"] as Array)[1]), 0.8, 0.0001)
			and _near(float(d1["边界距离"]), 0.0, 0.0001),
			"判据1 值=%.2f 边界=%s 距离=%.3f 档=%s" % [
				float(d1["值"]), str(d1["边界"]), float(d1["边界距离"]), String(d1["档"])])
	_record("2C10 B：bench 每波落 判据诊断 + JUDGE-DIAG 汇总（原始输入/边界距离）",
			bench_src.contains("c[\"判据诊断\"] = _bench_model.judge_diag(c)")
			and bench_src.contains("print(\"JUDGE-DIAG %s\"")
			and bench_src.contains("\"judge_diag\": diag_all"),
			"只诊断，不写「建议改成 X」")
	_record("2C10 §7.2：每局落盘 POP90（触发/成功/失败明细/峰值/农场开工）",
			sa_src.contains("func _pop90_tick(now: float) -> void:")
			and sa_src.contains("and rate > 0.90")
			and sa_src.contains("now - _pop90_trigger_t > 20.0")
			and sa_src.contains("_pop90_cooldown_until = now + 15.0")
			and bench_src.contains("print(\"POP90 %s\"")
			and bench_src.contains("\"pop90\": pop90_all"),
			"含在训 / 20s 响应窗 / 15s 冷却 / 失败明细带驳回原因·金币·工位")

	# ---------- 系数标定 + 不变式守门（2 条）----------
	_record("2C10 A：13 个系数标定一轮已进卡（抽查 巡逻0.6 / 出击1.3 / 农场紧迫1.2）",
			card != null and _near(float(card.get("巡逻_固定分")), 0.6, 0.0001)
			and _near(float(card.get("出击_兵力比系数")), 1.3, 0.0001)
			and _near(float(card.get("建造_农场紧迫系数")), 1.2, 0.0001)
			and _near(float(card.get("分基地_固定分")), 1.0, 0.0001),
			"只标一轮，不收敛")
	_record("2C10：不变式守门（判定表窗口/系数/分母/修理线/gap/大本营 一个字没动）",
			_near(float(bm.VD_TIME_GOOD), 0.8, 0.0001)
			and _near(float(bm.VD_TIME_HALF), 0.5, 0.0001)
			and _near(float(bm.VD_OUT_LOW), 0.7, 0.0001)
			and _near(float(bm.VD_OUT_HIGH), 1.3, 0.0001)
			and _near(float(bm.VD_DMG_LOW), 0.4, 0.0001)
			and _near(float(bm.VD_DMG_HIGH), 0.9, 0.0001)
			and _near(float(bm.THEORY_OUTPUT_COEF), 0.4, 0.0001)
			and _near(float(AIV.repair_hp_deficit()), 200.0, 0.0001)
			and _near(float(AIV.combat_gap_sec()), 3.0, 0.0001)
			and _near(float(AIV.output_coef()), 0.4, 0.0001)
			and String(AIV.damage_theory_mode()) == "targeted"
			and String(AIV.output_theory_mode()) == "recent"
			and sa_src.contains("func can_build_townhall() -> bool:\n\treturn false"),
			"机器断言守门：0.4 / targeted / recent / 200 / 3.0 / townhall=false 全冻结")


# ===========================================================================
# 2C-11 · 储蓄 / 同时做事数 / 紧急白名单 / 工地停滞（纯函数机器断言）
#
# ★ 口径说明：任务书 §2.3 定义 G(t)=min(550, 固定值+上限×成本×0.15)，
#   §2.6 却写「G(t) 在 1.5/3/5/10/12 min = 70/100/200/350/530」——
#   前四个数其实是**固定值表**，与公式项的 530 混在一行。这里把
#   `saving_base`（固定值曲线）与 `saving_target`（G(t)）分开断言，
#   两套口径都留实测值，报告 §2 照实记录这处不一致。
# ===========================================================================
func _case_2c11() -> void:
	var b = load("res://代码/ai/战斗模型.gd")
	# ---------- 固定值曲线 ----------
	var ts: Array = [90.0, 180.0, 300.0, 600.0, 720.0]
	var want_base: Array = [70.0, 100.0, 200.0, 350.0, 350.0]
	var got_base: Array = []
	for t in ts:
		got_base.append(snappedf(float(b.saving_base(float(t))), 0.01))
	_record("2C11：储备固定值表 1.5/3/5/10/12 min = 70/100/200/350/350",
			got_base == want_base, "实测 %s（表外 clamp 到 350）" % str(got_base))
	_record("2C11：固定值表中间线性插值（2.25 min=85 / 4 min=150）",
			_near(float(b.saving_base(135.0)), 85.0, 0.0001)
			and _near(float(b.saving_base(240.0)), 150.0, 0.0001),
			"2.25min=%.2f 4min=%.2f" % [
				float(b.saving_base(135.0)), float(b.saving_base(240.0))])
	_record("2C11：固定值表 t<=0 不外推成负数（clamp 70）",
			_near(float(b.saving_base(0.0)), 70.0, 0.0001)
			and _near(float(b.saving_base(-10.0)), 70.0, 0.0001),
			"0s=%.1f -10s=%.1f" % [
				float(b.saving_base(0.0)), float(b.saving_base(-10.0))])

	# ---------- 同时做事数上限（七个点逐项）----------
	var mins: Array = [2.0, 3.0, 5.0, 8.0, 10.0, 12.0, 14.0]
	var want_total: Array = [2, 4, 4, 8, 8, 9, 10]
	var want_dept: Array = [1, 2, 2, 3, 3, 3, 4]
	var got_total: Array = []
	var got_dept: Array = []
	for m in mins:
		var c: Dictionary = b.concurrency_caps(float(m) * 60.0)
		got_total.append(int(c["总上限"]))
		got_dept.append(int(c["同部门上限"]))
	_record("2C11：同时做事数总上限 2/3/5/8/10/12/14 min = 2/4/4/8/8/9/10",
			got_total == want_total, "实测 %s" % str(got_total))
	_record("2C11：同时做事数同部门上限七个点 = 1/2/2/3/3/3/4",
			got_dept == want_dept, "实测 %s" % str(got_dept))
	var cap18: Dictionary = b.concurrency_caps(18.0 * 60.0)
	var cap30: Dictionary = b.concurrency_caps(30.0 * 60.0)
	_record("2C11：总上限封顶 12 / 同部门封顶 4（18 min 后不再涨）",
			int(cap18["总上限"]) == 12 and int(cap30["总上限"]) == 12
			and int(cap30["同部门上限"]) == 4,
			"18min=%s 30min=%s" % [str(cap18), str(cap30)])
	var mono: bool = true
	var prev_total: int = -1
	for i in range(13):
		var c2: Dictionary = b.concurrency_caps(300.0 + float(i) * 15.0)
		if int(c2["总上限"]) < prev_total:
			mono = false
		prev_total = int(c2["总上限"])
	_record("2C11：5~8 min 线性攀升段单调不减（每 15 s 采样）", mono,
			"单调=%s" % str(mono))

	# ---------- G(t) ----------
	var g_zero: Array = []
	for t in ts:
		g_zero.append(snappedf(float(b.saving_target(float(t), 0.0, 0.15)), 0.01))
	_record("2C11：G(t) 公式项=0 时退化为固定值表（同一个储备，不分池）",
			g_zero == want_base, "实测 %s" % str(g_zero))
	_record("2C11：10 min 对照预期 350 + 8x150x0.15 = 530",
			_near(float(b.saving_target(600.0, 150.0, 0.15)), 530.0, 0.0001),
			"G(10min,cost150)=%.2f" % float(b.saving_target(600.0, 150.0, 0.15)))
	_record("2C11：12 件时 350+270=620 封顶 550（固定值+公式一起封）",
			_near(float(b.saving_target(1080.0, 150.0, 0.15)), 550.0, 0.0001),
			"G(18min,cost150)=%.2f" % float(b.saving_target(1080.0, 150.0, 0.15)))
	_record("2C11：16 min G=550 且 20/30 min 不继续涨",
			_near(float(b.saving_target(960.0, 150.0, 0.15)), 550.0, 0.0001)
			and _near(float(b.saving_target(1200.0, 150.0, 0.15)), 550.0, 0.0001)
			and _near(float(b.saving_target(1800.0, 150.0, 0.15)), 550.0, 0.0001),
			"16/20/30min 全 550")
	_record("2C11：安全系数 0.15 进卡且被 saving_target 读到",
			_near(float(b.demand_coef("储蓄_安全系数", 0.0)), 0.15, 0.0001)
			and _near(float(b.saving_target(600.0, 150.0)), 530.0, 0.0001),
			"卡值=%.3f G(默认系数)=%.2f" % [
				float(b.demand_coef("储蓄_安全系数", 0.0)),
				float(b.saving_target(600.0, 150.0))])

	# ---------- 单件典型成本 ----------
	var ds: Array = [{"金币成本": 80}, {"金币成本": 150}, {"金币成本": 40}]
	_record("2C11：单件典型成本 = 最贵待办动作（80/150/40 -> 150）",
			_near(float(b.typical_unit_cost(ds, 80.0)), 150.0, 0.0001),
			"=%.1f" % float(b.typical_unit_cost(ds, 80.0)))
	_record("2C11：无待办时取最近一次的值（空列表 / 全 0 -> 上次 150）",
			_near(float(b.typical_unit_cost([], 150.0)), 150.0, 0.0001)
			and _near(float(b.typical_unit_cost([{"金币成本": 0}], 150.0)), 150.0, 0.0001),
			"空=%.1f 全0=%.1f" % [
				float(b.typical_unit_cost([], 150.0)),
				float(b.typical_unit_cost([{"金币成本": 0}], 150.0))])

	# ---------- 储备击穿 / 并发上限击穿 ----------
	_record("2C11：储备不足驳回（金币=G-1 非紧急驳回 / 紧急通过）",
			bool(b.saving_breach(529, 0, 530.0, false))
			and not bool(b.saving_breach(529, 0, 530.0, true))
			and not bool(b.saving_breach(530, 0, 530.0, false)),
			"G=530：金529非紧急驳回、紧急通过、金530通过")
	_record("2C11：按「当前金币 - 本诉求金币成本」判击穿（金 G+79 买 80）",
			bool(b.saving_breach(609, 80, 530.0, false))
			and not bool(b.saving_breach(610, 80, 530.0, false)),
			"609-80=529<530 驳回；610-80=530 通过")
	_record("2C11：并发上限击穿（总/同部门任一到顶即驳回）",
			bool(b.concurrency_breach(2, 0, {"总上限": 2, "同部门上限": 1}))
			and bool(b.concurrency_breach(0, 1, {"总上限": 8, "同部门上限": 1}))
			and not bool(b.concurrency_breach(1, 0, {"总上限": 8, "同部门上限": 1})),
			"总到顶 / 部门到顶 / 都没到顶")

	# ---------- 紧急白名单三条边界 ----------
	_record("2C11：紧急_防卡人口 边界（95% 不触发 / 95.1%+无工地触发 / 有工地不触发）",
			(b.urgent_reasons(0.95, false, 20, 8, 0, false) as Array).is_empty()
			and (b.urgent_reasons(0.951, false, 20, 8, 0, false) as Array).has(b.URG_POP_BLOCK)
			and (b.urgent_reasons(0.99, true, 20, 8, 0, false) as Array).is_empty(),
			"严格 >95% 且农场无工地")
	_record("2C11：紧急_兵力严重不足 边界（下限8：现役4触发 / 5不触发）",
			(b.urgent_reasons(0.5, false, 4, 8, 0, false) as Array).has(b.URG_ARMY_LOW)
			and (b.urgent_reasons(0.5, false, 5, 8, 0, false) as Array).is_empty(),
			"现役 < 8x0.6=4.8")
	_record("2C11：紧急_建筑被拆 边界（60s 内 >=2 栋且仍被攻击才触发）",
			(b.urgent_reasons(0.5, false, 20, 8, 2, true) as Array).has(b.URG_BUILDING_LOST)
			and (b.urgent_reasons(0.5, false, 20, 8, 1, true) as Array).is_empty()
			and (b.urgent_reasons(0.5, false, 20, 8, 2, false) as Array).is_empty(),
			">=2 栋 + 仍被攻击，缺一不可")
	_record("2C11：3 个紧急枚举齐全且 URG_REASONS 恰好 3 项",
			int((b.URG_REASONS as Array).size()) == 3
			and String(b.URG_POP_BLOCK) == "紧急_防卡人口"
			and String(b.URG_ARMY_LOW) == "紧急_兵力严重不足"
			and String(b.URG_BUILDING_LOST) == "紧急_建筑被拆",
			"%s" % str(b.URG_REASONS))

	# ---------- 工地停滞 ----------
	_record("2C11：工地 19s 不判停滞 / 21s 判停滞 / 派工后计时清零",
			not bool(b.site_is_stalled(19.0, 0.0))
			and bool(b.site_is_stalled(21.0, 0.0))
			and not bool(b.site_is_stalled(21.0, 21.0))
			and not bool(b.site_is_stalled(100.0, -1.0)),
			"20 s 阈值，last_work<0 不误判")

	# ---------- C2：仲裁接入（policy）----------
	var mkA: Dictionary = b.demand_make("运营线", "训练", "步兵", 80, 0, 0, false, 5.0, "x")
	var mkB: Dictionary = b.demand_make("扩展线", "建塔", "哨塔", 80, 0, 0, false, 4.0, "x")
	var mkC: Dictionary = b.demand_make("运营线", "巡逻", "巡逻", 0, 0, 1, false, 3.0, "x")
	var pol_save: Dictionary = {"reserve": 530.0, "caps": {}, "urgent": false}
	var r_save: Dictionary = b.arbitrate([mkA, mkB, mkC], 529, 1000, 10, pol_save)
	var all_saving: bool = true
	for d in (r_save["驳回"] as Array):
		if String((d as Dictionary).get("驳回原因", "")) != String(b.RJ_SAVING):
			all_saving = false
	_record("2C11：仲裁 储备不足驳回（金=G-1，非紧急 3 条全驳回且原因统一）",
			int((r_save["执行"] as Array).size()) == 0
			and int((r_save["驳回"] as Array).size()) == 3 and all_saving,
			"执行=%d 驳回=%d 原因统一=%s" % [
				int((r_save["执行"] as Array).size()),
				int((r_save["驳回"] as Array).size()), str(all_saving)])
	var pol_urg: Dictionary = {"reserve": 530.0, "caps": {}, "urgent": true}
	var r_urg: Dictionary = b.arbitrate([mkA, mkB, mkC], 529, 1000, 10, pol_urg)
	_record("2C11：仲裁 紧急诉求不受储备线约束（同金币下 3 条照常执行）",
			int((r_urg["执行"] as Array).size()) == 3,
			"紧急执行=%d" % int((r_urg["执行"] as Array).size()))
	var r_mix: Dictionary = b.arbitrate([mkA, mkB], 529, 1000, 10, pol_save)
	_record("2C11：全局一个储备（运营线/扩展线读同一个 G(t)，不分池）",
			_near(float(r_save["储备"]), 530.0, 0.0001)
			and int((r_mix["驳回"] as Array).size()) == 2,
			"policy 只有一个 reserve，两条线同时被它驳回")
	var r_old: Dictionary = b.arbitrate([mkA, mkB, mkC], 1000, 1000, 10)
	_record("2C11：空 policy 完全保留 2C-9 仲裁行为（3 条都执行）",
			int((r_old["执行"] as Array).size()) == 3
			and int((r_old["驳回"] as Array).size()) == 0,
			"执行=%d 驳回=%d" % [
				int((r_old["执行"] as Array).size()),
				int((r_old["驳回"] as Array).size())])
	var pol_cap: Dictionary = {"reserve": -1.0,
			"caps": {"总上限": 2, "同部门上限": 1}, "urgent": false}
	var r_cap: Dictionary = b.arbitrate([mkA, mkB, mkC], 1000, 1000, 10, pol_cap)
	_record("2C11：仲裁 并发上限（总上限 2 → 执行 2、第 3 条驳回并发上限）",
			int((r_cap["执行"] as Array).size()) == 2
			and String(((r_cap["驳回"] as Array)[0] as Dictionary).get("驳回原因", "")) == String(b.RJ_CONCURRENT),
			"执行=%d 驳回原因=%s" % [
				int((r_cap["执行"] as Array).size()),
				String(((r_cap["驳回"] as Array)[0] as Dictionary).get("驳回原因", ""))])
	var pol_dept: Dictionary = {"reserve": -1.0,
			"caps": {"总上限": 8, "同部门上限": 1}, "urgent": false}
	var r_dept: Dictionary = b.arbitrate([mkA, mkB, mkC], 1000, 1000, 10, pol_dept)
	_record("2C11：仲裁 同部门上限（运营线第 2 条被驳回，扩展线不受影响）",
			int((r_dept["执行"] as Array).size()) == 2
			and String(((r_dept["驳回"] as Array)[0] as Dictionary).get("驳回原因", "")) == String(b.RJ_CONCURRENT)
			and String(((r_dept["驳回"] as Array)[0] as Dictionary).get("来源线", "")) == "运营线",
			"同部门上限=1")
	var mkBad: Dictionary = b.demand_make("运营线", "巡逻", "巡逻2", 0, 0, 1,
			false, 0.1, "x", false)
	var r_low: Dictionary = b.arbitrate([mkBad], 1000, 1000, 10,
			{"reserve": -1.0, "caps": {"总上限": 2, "同部门上限": 1}, "urgent": false})
	_record("2C11：不设下限（低分/不可执行动作不因「至少做 N 件」被强行放行）",
			int((r_low["执行"] as Array).size()) == 0
			and String(((r_low["驳回"] as Array)[0] as Dictionary).get("驳回原因", "")) == String(b.RJ_COND),
			"条件不满足，不凑数")

	# ---------- C2：接线（源码文本守门）----------
	var sa11: String = ""
	var f11 := FileAccess.open("res://代码/ai/简单AI.gd", FileAccess.READ)
	if f11 != null:
		sa11 = f11.get_as_text()
		f11.close()
	_record("2C11：接线 _dept_tick 每周期算 G(t)/上限/单件成本并作为单个 policy 传入",
			sa11.contains("var policy: Dictionary = {\"reserve\": reserve, \"caps\": caps, \"urgent\": urgent}")
			and sa11.contains("\"saving_target\", [t_sec, unit_cost]")
			and sa11.contains("\"concurrency_caps\", [t_sec]")
			and sa11.contains("\"typical_unit_cost\",")
			and sa11.contains("t_avail, policy]"),
			"储备目标只算一次，运营/扩展共用")
	_record("2C11：POP90 修正口径（触发时已有农场工地算成功）",
			sa11.contains("if _has_site_of(fid):")
			and sa11.contains("\"pop90_site_already\"")
			and sa11.contains("2C-11 §7 修正口径"),
			"只改观测判定，不改农场预判/人口逻辑")

	# ---------- C3：紧急白名单接线 ----------
	_record("2C11：接线 紧急白名单 3 枚举由 _saving_urgency 取 6 个场景状态",
			sa11.contains("func _saving_urgency() -> Array:")
			and sa11.contains("var hits: Array = _saving_urgency()")
			and sa11.contains("\"urgent_reasons\",")
			and sa11.contains("var urgent: bool = not hits.is_empty()")
			and sa11.contains("_under_attack()")
			and sa11.contains("_has_site_of(fid)"),
			"命中任一即紧急，接入 policy.urgent")
	_record("2C11：接线 最近 60s 被拆账本（首次只建基线 / 窗口外清掉）",
			sa11.contains("func _track_building_losses(now: float) -> void:")
			and sa11.contains("_track_building_losses(now)")
			and sa11.contains("URG_LOST_WINDOW_SEC: float = 60.0")
			and sa11.contains("if not _known_buildings.is_empty():")
			and _near(float(b.URG_LOST_WINDOW), 60.0, 0.0001),
			"60 s 窗口，与纯函数 URG_LOST_WINDOW 一致")
	_record("2C11：紧急态不受储备线约束 / 不紧急被驳回（policy 只差 urgent）",
			int((r_urg["执行"] as Array).size()) == 3
			and int((r_save["执行"] as Array).size()) == 0
			and bool(r_urg["紧急"]) and not bool(r_save["紧急"]),
			"紧急执行 3 / 非紧急执行 0")

	# ---------- C4：建造停滞恢复接线 ----------
	_record("2C11：接线 每 5s 扫工地（不是每帧）且优先于仲裁/新工地",
			sa11.contains("SITE_SCAN_SEC_2C11: float = 5.0")
			and sa11.contains("if now >= _site_scan_next_t:")
			and sa11.contains("_site_recovery_tick(now)")
			and sa11.contains("func _site_recovery_tick(now: float) -> void:")
			and _near(float(b.SITE_SCAN_SEC), 5.0, 0.0001),
			"5 s 节拍，_think_once 里跑在 _dept_tick 之前")
	_record("2C11：接线 20s 停滞判据 + 派工接续 + 计时清零 + 复用 blocked_builder_busy",
			sa11.contains("\"site_is_stalled\", [now, last_t]")
			and sa11.contains("builder.call(\"order_build_site\", s2)")
			and sa11.contains("_site_last_work[sid2] = now")
			and sa11.contains("repair_stats[\"blocked_builder_busy\"]")
			and _near(float(b.SITE_STALL_SEC), 20.0, 0.0001),
			"20 s 停滞 / 只接活不新建 / 归因不新增结构")
	_record("2C11：P2 监控 停滞工地数 / 成功接续数 都有落盘计数",
			sa11.contains("\"site_stall_detected\"")
			and sa11.contains("\"site_recovery_issued\""),
			"建造停滞恢复率 = issued / detected")

	# ---------- C5.1：副官自检测试场景 / normal_push_n 零改动 ----------
	_record("2C11：normal_push_n 行为不变（现役=下限 -> 0 / 下限+2 -> >0）",
			int(b.normal_push_n(8, 8)) == 0
			and int(b.normal_push_n(10, 8)) > 0,
			"8/8=%d 10/8=%d" % [int(b.normal_push_n(8, 8)), int(b.normal_push_n(10, 8))])
	var adj_src: String = ""
	var fadj := FileAccess.open("res://代码/测试/副官自检.gd", FileAccess.READ)
	if fadj != null:
		adj_src = fadj.get_as_text()
		fadj.close()
	_record("2C11：副官自检只改测试场景兵力（>=下限+2），不改产品逻辑",
			adj_src.contains("var need_army: int = floor_v + 2")
			and adj_src.contains("Game.spawn_unit(Game.player_faction, &\"footman\", spawn_pos)")
			and adj_src.contains("normal_push_n 源码未改")
			and not adj_src.contains("func normal_push_n"),
			"负对照场景补兵，28 条口径不变")

	# ---------- C5.2：系数卡代码显式注入 ----------
	var cgd = load("res://代码/配置/AI诉求系数.gd")
	var defs: Dictionary = cgd.defaults()
	var keys24: Array = [
		"训练_威胁系数", "训练_缺口系数", "建造_农场缺口系数", "建造_农场紧迫系数",
		"建造_兵营缺口系数", "建造_兵营紧迫系数", "修理_掉血系数", "出击_兵力比系数",
		"防守_威胁系数", "侦查_固定分", "巡逻_固定分", "建塔_固定分", "分基地_固定分",
		"人口压力_阈值", "人口压力_k", "储蓄_安全系数",
		"刻度_修理", "刻度_出击", "刻度_防守", "刻度_农场急建", "刻度_农场不急",
		"刻度_兵营无产能", "刻度_兵营扩建", "周期秒",
	]
	var same: bool = true
	for k in keys24:
		if not _near(float(b.demand_coef(String(k))), float(defs[k]), 0.000001):
			same = false
	_record("2C11：加载后读到的 24 个值与 AI诉求系数.gd defaults() 逐项一致",
			same and int(defs.size()) == 24,
			"逐项 %d 键，一致=%s" % [int(defs.size()), str(same)])
	var card_obj: Resource = load("res://代码/配置/卡/AI诉求系数.tres")
	var export_same: bool = true
	for k in keys24:
		var v = card_obj.get(String(k))
		if v == null or not _near(float(v), float(defs[k]), 0.000001):
			export_same = false
	_record("2C11：.gd 的 @export 默认值与 defaults() 逐项一致（两处同步守门）",
			export_same, "24 项一致=%s" % str(export_same))
	var bm_src: String = ""
	var fbm := FileAccess.open("res://代码/ai/战斗模型.gd", FileAccess.READ)
	if fbm != null:
		bm_src = fbm.get_as_text()
		fbm.close()
	_record("2C11：demand_coef 不再读 .tres（改 .tres 不影响运行时）",
			bm_src.contains("_coef_defaults = g.defaults()")
			and not bm_src.contains("var c: Resource = demand_card()")
			and not bm_src.contains("var v = c.get(name)")
			and bm_src.contains("## 展示/校验用"),
			"唯一真相源 = AI诉求系数.gd defaults()")


## 造一条"金币成本被改成负数"的诉求（用于 demand_valid 的非法值断言）
func _demand_gold(base: Dictionary, gold: int) -> Dictionary:
	var d: Dictionary = base.duplicate(true)
	d["金币成本"] = gold
	return d


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
