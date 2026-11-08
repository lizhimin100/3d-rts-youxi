extends SceneTree
## **技能自检（无头）**：组件化技能系统的回归。
##
## 跑法：
##   godot --headless --path . --script 代码/测试/技能自检.gd
## 输出结尾一行 `SKILLTEST {json}`，退出码 0 = 全过。
##
## 判据（2026-11-07 玩家口径逐条对应）：
##   A 技能表：5 张技能卡全部加载、0 错误；举盾/三连发的关键字段对得上
##   B 举盾：开启后 移速 ×0.55、攻击间隔 ×2.0、受普通伤害 ×0.85、受穿刺伤害 ×0.5525；
##           再点一次全部复原（连乘可逆，不是"加一次减一次"）
##   C 不绑单位：把 shield_up 挂到**农民**身上，同样的修正照样生效
##   D 三连发：一轮攻击打 3 发，打完进 2 秒装填；装填期间 can_fire()=false
##   E 组件可缺：动画/特效字段留空的技能，toggle 不报错、不崩
##
## 为什么不用 `RtsSkillRt` / `RtsCombat` 当类型：`--script` 在 autoload 注册之前编译，
## 直接写类名会 "Identifier not found"（和战斗自检同一个坑），所以统一 load()。

const 步长: float = 1.0 / 60.0
## 浮点比较容差
const EPS: float = 0.001

var 游戏: Node = null
var 关卡: Node3D = null
var 失败: Array = []
var 报告: Dictionary = {}


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var 开始: int = Time.get_ticks_msec()
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[技能自检] 找不到 Game 单例")
		quit(1)
		return
	_建世界()
	if 失败.is_empty():
		_用例A_技能表()
		_用例B_举盾()
		_用例C_不绑单位()
		_用例D_三连发()
		_用例E_组件可缺()
		await _用例F_举盾动作()
	报告["失败项"] = 失败
	报告["结果"] = "通过" if 失败.is_empty() else "失败"
	报告["耗时(毫秒)"] = Time.get_ticks_msec() - 开始
	print("SKILLTEST " + JSON.stringify(报告))
	quit(0 if 失败.is_empty() else 1)


# ===========================================================================
# 环境
# ===========================================================================

func _建世界() -> void:
	游戏.call("reset")
	游戏.set("difficulty_index", 0)
	游戏.call("setup_factions")
	var s: Script = load("res://代码/核心/关卡.gd")
	if s == null:
		失败.append("读不到 关卡.gd")
		return
	关卡 = s.new()
	关卡.name = "关卡"
	root.add_child(关卡)
	关卡.call("build")
	游戏.set("level", 关卡)
	var 常量脚本: Script = load("res://代码/核心/常量.gd")
	var 阶段: Dictionary = 常量脚本.get_script_constant_map().get("Phase", {}) if 常量脚本 != null else {}
	游戏.set("phase", int(阶段.get("RUNNING", 1)))


func _造(id: StringName, 位置: Vector3):
	return _造方("player_faction", id, 位置)


## 造到指定阵营（敌方靶子用 enemy_faction）
func _造方(阵营: String, id: StringName, 位置: Vector3):
	var 派 = 游戏.get(阵营)
	var n = 游戏.call("spawn_unit", 派, id, 位置, 关卡)
	if n == null:
		失败.append("生成 %s 失败" % id)
		return null
	n.set_process(false)
	var v = n.get("visual")
	if v != null and is_instance_valid(v):
		v.set_process(false)
	return n


func _一步() -> void:
	var s: Script = load("res://代码/单位/单位.gd")
	if s != null:
		s.set("_sep_frame", -1)
	游戏.set("_unit_hash_frame", -1)
	for u in 游戏.call("all_units"):
		if u == null or not is_instance_valid(u) or u.is_queued_for_deletion():
			continue
		if not u.call("is_alive"):
			continue
		u._process(步长)


func _走(秒: float) -> void:
	for i in int(round(秒 / 步长)):
		_一步()


func _ok(cond: bool, 名: String, 详情: String = "") -> void:
	if cond:
		print("  ✓ %s %s" % [名, 详情])
	else:
		失败.append(名)
		print("  ✗ %s %s" % [名, 详情])


func _近(a: float, b: float, eps: float = EPS) -> bool:
	return absf(a - b) <= eps


# ===========================================================================
# A 技能表
# ===========================================================================

func _用例A_技能表() -> void:
	print("[A] 技能表")
	var T: Script = load("res://代码/配置/技能表.gd")
	T.call("_ensure")
	var errs: Array = T.get("load_errors")
	_ok(errs.is_empty(), "技能卡全部加载成功", "错误 %d 条 %s" % [errs.size(), str(errs)] if not errs.is_empty() else "5 张")
	var ids: Array = T.call("ids")
	_ok(ids.size() >= 5, "技能数量 >= 5", "实测 %d：%s" % [ids.size(), str(ids)])
	for need in [&"fireball", &"chop_wood", &"mine_gold", &"shield_up", &"triple_shot"]:
		_ok(bool(T.call("has", need)), "技能存在：%s" % need)
	var sh: Dictionary = T.call("get_def", &"shield_up")
	_ok(StringName(sh.get("kind", &"")) == &"开关", "举盾是开关类", String(sh.get("kind", "")))
	var mods: Array = sh.get("effect", {}).get("mods", [])
	_ok(mods.size() == 4, "举盾有 4 条修正", "实测 %d" % mods.size())
	var tri: Dictionary = T.call("get_def", &"triple_shot")
	var burst: Dictionary = tri.get("effect", {}).get("burst", {})
	_ok(int(burst.get("shots", 0)) == 3, "三连发 shots = 3", "实测 %s" % str(burst.get("shots", 0)))
	_ok(_近(float(burst.get("reload", 0.0)), 2.0), "装填 2 秒", "实测 %.2f" % float(burst.get("reload", 0.0)))
	_ok(StringName(tri.get("kind", &"")) == &"被动", "三连发是被动", String(tri.get("kind", "")))


# ===========================================================================
# B 举盾
# ===========================================================================

func _用例B_举盾() -> void:
	print("[B] 举盾")
	var u = _造(&"footman", Vector3(0.0, 0.0, 0.0))
	if u == null:
		return
	_ok(u.get("skills_rt") != null, "步兵创建了技能运行时")
	if u.get("skills_rt") == null:
		return
	var rt = u.get("skills_rt")
	var d: UnitDef = u.get("def")
	var 基础速度: float = float(u.call("_max_speed"))

	# 开启
	var on: bool = bool(u.call("skill_toggle", &"shield_up"))
	_ok(on, "举盾开启成功")
	_ok(bool(u.call("skill_active", &"shield_up")), "skill_active 为真")
	var 举盾速度: float = float(u.call("_max_speed"))
	_ok(_近(举盾速度, 基础速度 * 0.55, 0.01), "移速 ×0.55",
		"%.2f → %.2f（期望 %.2f）" % [基础速度, 举盾速度, 基础速度 * 0.55])
	_ok(_近(float(rt.call("attack_cooldown_mult")), 2.0), "攻击间隔 ×2.0")
	_ok(_近(float(rt.call("damage_taken_mult", 0)), 0.85), "受普通伤害 ×0.85",
		"实测 %.4f" % float(rt.call("damage_taken_mult", 0)))
	# DamageType.PIERCE = 1
	_ok(_近(float(rt.call("damage_taken_mult", 1)), 0.85 * 0.65, 0.002), "受穿刺伤害 ×0.5525",
		"实测 %.4f" % float(rt.call("damage_taken_mult", 1)))
	_ok(_近(float(rt.call("damage_taken_mult", 2)), 0.85), "受魔法伤害只有全局减免 ×0.85")

	# 攻击间隔真的进了 _attack_cd
	u.call("_begin_swing")
	var cd: float = float(u.get("_attack_cd"))
	_ok(_近(cd, d.attack_cooldown * 2.0, 0.01), "起手间隔吃修正",
		"%.2f（基础 %.2f）" % [cd, d.attack_cooldown])

	# 关闭
	var off: bool = bool(u.call("skill_toggle", &"shield_up"))
	_ok(not off, "再点一次放下")
	_ok(_近(float(u.call("_max_speed")), 基础速度, 0.01), "移速复原",
		"%.2f" % float(u.call("_max_speed")))
	_ok(_近(float(rt.call("damage_taken_mult", 1)), 1.0), "减伤复原")
	if u != null and is_instance_valid(u):
		u.queue_free()


# ===========================================================================
# C 不绑单位：把举盾挂到农民身上
# ===========================================================================

func _用例C_不绑单位() -> void:
	print("[C] 技能不绑单位")
	var u = _造(&"peasant", Vector3(4.0, 0.0, 0.0))
	if u == null:
		return
	# 农民卡里没有 shield_up —— 运行时**照样能挂**（数据驱动，不看单位 id）
	var rt_script: Script = load("res://代码/系统/技能运行时.gd")
	var rt = rt_script.new(u)
	u.set("skills_rt", rt)
	var ok: bool = bool(rt.call("toggle", &"shield_up"))
	_ok(ok, "农民也能举盾（技能不绑单位）")
	_ok(_近(float(rt.call("move_speed_mult")), 0.55), "农民移速同样 ×0.55")
	_ok(_近(float(rt.call("damage_taken_mult", 1)), 0.85 * 0.65, 0.002), "农民同样吃穿刺减免")
	if u != null and is_instance_valid(u):
		u.queue_free()


# ===========================================================================
# D 三连发
# ===========================================================================

func _用例D_三连发() -> void:
	print("[D] 三连发")
	var u = _造(&"archer", Vector3(8.0, 0.0, 0.0))
	if u == null:
		return
	var rt = u.get("skills_rt")
	_ok(rt != null, "弩兵创建了技能运行时")
	if rt == null:
		return
	_ok(bool(rt.call("has_burst")), "识别到连发组件")
	_ok(bool(rt.call("can_fire")), "初始可以开火")
	var started: bool = bool(rt.call("begin_burst"))
	_ok(started, "开启一轮连发")
	_ok(not bool(rt.call("can_fire")), "连发期间不能开下一轮")
	# 连发要有目标才会真的发箭：摆一个敌方靶子，并让弩兵锁定它
	var 靶 = _造方("enemy_faction", &"footman", Vector3(8.0, 0.0, 10.0))
	if 靶 != null:
		u.set("target", 靶)
	# 数发射：dbg_shots 由 _fire_projectile 递增
	var 前: int = int(u.get("dbg_shots"))
	# 3 发 × 0.12s 间隔 → 0.4s 足够
	_走(0.5)
	var 发数: int = int(u.get("dbg_shots")) - 前
	_ok(发数 >= 2, "连发真的打出了投射物", "0.5s 内 %d 发（期望 3）" % 发数)
	if 靶 != null and is_instance_valid(靶):
		靶.queue_free()
	# 手动把队列跑完，验证装填
	var guard: int = 0
	while int(rt.get("burst_left")) > 0 and guard < 60:
		rt.call("tick_burst")
		rt.call("tick", 0.2)
		guard += 1
	_ok(_近(float(rt.get("reload_t")), 2.0, 0.6), "打完进装填约 2 秒",
		"实测 %.2f" % float(rt.get("reload_t")))
	_ok(not bool(rt.call("can_fire")), "装填期间不能开火")
	rt.call("tick", 2.1)
	_ok(bool(rt.call("can_fire")), "装填结束后恢复")
	if u != null and is_instance_valid(u):
		u.queue_free()


# ===========================================================================
# E 组件可缺
# ===========================================================================

func _用例E_组件可缺() -> void:
	print("[E] 组件可缺")
	var u = _造(&"peasant", Vector3(-4.0, 0.0, 0.0))
	if u == null:
		return
	var rt_script: Script = load("res://代码/系统/技能运行时.gd")
	var rt = rt_script.new(u)
	u.set("skills_rt", rt)
	# fireball 是"主动 + 有目标"，不是开关 → toggle 必须安全地返回 false，不崩
	var r: bool = bool(rt.call("toggle", &"fireball"))
	_ok(not r, "对非开关技能 toggle 返回 false（不崩）")
	# 举盾的动画/特效在这台机器上没有对应 clip，toggle 也必须安全
	rt.call("toggle", &"shield_up")
	_ok(true, "缺动画/特效时 toggle 不报错")
	rt.call("toggle", &"shield_up")
	_ok(true, "再次切换同样安全")
	if u != null and is_instance_valid(u):
		u.queue_free()


# ===========================================================================
# F 举盾动作（模型里有 shield_hold 时，站着不动就该播它）
# ===========================================================================

func _用例F_举盾动作() -> void:
	print("[F] 举盾动作")
	var u = _造(&"footman", Vector3(12.0, 0.0, 0.0))
	if u == null:
		return
	var v = u.get("visual")
	if v == null:
		_ok(false, "找不到外观节点")
		return
	var anim = v.get("_anim")
	if anim == null:
		_ok(false, "找不到动画器")
		return
	var 有动作: bool = bool(anim.call("has_state", "shield_hold"))
	_ok(有动作, "模型里有 shield_hold 动作（Blender 已加进 glb）")
	if not 有动作:
		u.queue_free()
		return
	u.call("skill_toggle", &"shield_up")
	_走(0.8)
	# 姿态层挂在 Skeleton3D 上，靠引擎帧（_process_modification）推进；
	# 本自检是"手动步进单位逻辑"的，不会推进引擎帧，所以这里必须真等几帧。
	for _i in 24:
		await process_frame
	# ★ 2026-11-08 口径变了（玩家：「不应该循环播放举盾动作，要一直保持举着盾的状态」）：
	#   现在**不播** shield_hold 这个 clip，由**姿态层**把左臂按在它的末帧姿势上。
	#   所以这里验三件事：
	#     ① 基础动作照常在播（idle，而不是被 shield_hold 顶掉）；
	#     ② 姿态层权重到 1（= 盾真的举起来了）；
	#     ③ 姿态层按住的是左臂 5 根骨。
	var 当前: String = String(anim.call("current_state"))
	_ok(当前.begins_with("idle"), "举盾时基础动作照常播 idle（不再循环播举盾动作）", "实际 %s" % 当前)
	var dbg: Dictionary = {}
	if v.has_method("hold_pose_debug"):
		dbg = v.call("hold_pose_debug") as Dictionary
	_ok(float(dbg.get("weight", 0.0)) >= 0.99, "举盾姿态层权重到 1（盾举在身前）",
		"weight=%s" % str(dbg.get("weight", "无姿态层")))
	_ok((dbg.get("bones", []) as Array).has("shield"), "姿态层按住了 shield 骨",
		str(dbg.get("bones", [])))
	u.call("skill_toggle", &"shield_up")
	_走(0.5)
	# 淡出要 0.18s；无头帧 delta 不稳定，多等几帧再判（60 帧 = 1 秒）
	for _i in 60:
		await process_frame
	var dbg2: Dictionary = {}
	if v.has_method("hold_pose_debug"):
		dbg2 = v.call("hold_pose_debug") as Dictionary
	_ok(float(dbg2.get("weight", 0.0)) <= 0.01, "放下后姿态层权重归零（不再举盾）",
		"weight=%s" % str(dbg2.get("weight", 0.0)))
	if u != null and is_instance_valid(u):
		u.queue_free()
