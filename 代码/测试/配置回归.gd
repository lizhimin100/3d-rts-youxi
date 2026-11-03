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
		"why": "依赖 RtsBuilding.can_train、_can_spend(Cfg+Game)、_faction.count_units()、_enemy_army() 场景扫描；"
			+ "权重公式本身是 worth_per_cost × 设计权重 × 过载惩罚，前两项已在 B/C 里断言。",
		"可拆": "把 weight 抽成 static 纯函数后即可脱引擎",
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
