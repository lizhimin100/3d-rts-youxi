extends SceneTree
## **动画验收（引擎内）**：证明兵真的在动，而不是靠肉眼猜。
##
## 跑法：godot --headless --path . --script 代码/测试/动画验收.gd
## 结尾一行 ANIMTEST {json}，退出码 0 = 全过。
##
## 判据（2026-11-07 玩家口径逐条对应）：
##   A 资产：步兵模型里必须有 idle / walk / attack / shield_hold
##   B 待机随机：以 idle 开头的 clip >= 2 个（待机可以多个不同动画）
##   C 单一动作：move -> walk、attack -> attack、举盾 anim_hold -> shield_hold
##   D 真在动：走 / 攻 / 举盾三种动作各采两帧比骨骼世界坐标，必须有位移
##   E 一刀：attack 播完后回 idle，不会自己接着再播一遍
##
## 为什么不用类名当类型：--script 在 autoload 注册之前编译，写 RtsUnit 会 Identifier not found。

var 游戏: Node = null
var 关卡: Node3D = null
var 失败: Array = []
var 明细: Array = []


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var 开始: int = Time.get_ticks_msec()
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[动画验收] 找不到 Game 单例")
		quit(1)
		return
	_建世界()
	if 失败.is_empty():
		_用例A_资产等待()
		await _用例B_待机随机()
		await _用例C_单一动作()
		await _用例D_真在动()
		await _用例E_一刀()
	var 报告 := {
		"失败项": 失败,
		"明细": 明细,
		"结果": "通过" if 失败.is_empty() else "失败",
		"耗时毫秒": Time.get_ticks_msec() - 开始,
	}
	print("ANIMTEST " + JSON.stringify(报告))
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
	var 派 = 游戏.get("player_faction")
	var n = 游戏.call("spawn_unit", 派, id, 位置, 关卡)
	if n == null:
		失败.append("生成 %s 失败" % id)
	return n


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var s := _find_skel(c)
		if s != null:
			return s
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


## 让单位不再被主循环驱动（本项目自检的通用做法），只留动画节点自己跑
func _静默(u) -> void:
	if u == null:
		return
	u.set_process(false)
	var v = u.get("visual")
	if v != null and is_instance_valid(v):
		v.set_process(false)


func _anim_of(unit) -> Node:
	var v = unit.get("visual")
	if v == null:
		return null
	return v.get("_anim")


func _resolved(unit, state: String) -> String:
	var a := _anim_of(unit)
	if a == null:
		return ""
	return String(a.call("_resolve", StringName(state)))


func _bones(sk: Skeleton3D) -> Array:
	var out: Array = []
	for i in sk.get_bone_count():
		var t: Transform3D = sk.global_transform * sk.get_bone_global_pose(i)
		out.append(t.origin)
	return out


func _max_delta(a: Array, b: Array) -> float:
	var m := 0.0
	for i in mini(a.size(), b.size()):
		m = maxf(m, (a[i] as Vector3).distance_to(b[i] as Vector3))
	return m


## ⚠ 不能用"帧数 × 1/60"，也不能用墙钟：引擎可能跑 fixed-fps（每帧进 1/60 秒游戏时间，
## 但真实耗时只有 1ms），墙钟 0.2 秒能跑掉 3 秒动画。只有 SceneTreeTimer 走的是**游戏时间**。
func _wait(sec: float) -> void:
	await create_timer(sec).timeout


# ===========================================================================
# 用例
# ===========================================================================

func _用例A_资产等待() -> void:
	var u = _造(&"footman", Vector3(0.0, 0.0, 0.0))
	if u == null:
		return
	var ap := _find_ap(u)
	if ap == null:
		失败.append("步兵模型里没有 AnimationPlayer")
		return
	明细.append({"case": "A", "clips": ap.get_animation_list()})
	for want in ["idle", "walk", "attack", "shield_hold"]:
		if not ap.has_animation(want):
			失败.append("步兵资产缺动作：%s" % want)


func _用例B_待机随机() -> void:
	var u = _造(&"footman", Vector3(2.0, 0.0, 0.0))
	if u == null:
		return
	var a := _anim_of(u)
	if a == null:
		失败.append("拿不到动画节点")
		return
	var pool: Array = a.get("_idle_pool")
	明细.append({"case": "B", "idle_pool": pool})
	if pool.size() < 2:
		失败.append("待机池只有 %d 个（要求 >= 2）" % pool.size())


func _用例C_单一动作() -> void:
	var u = _造(&"footman", Vector3(4.0, 0.0, 0.0))
	if u == null:
		return
	var 实得 := {}
	for k in ["move", "attack"]:
		实得[k] = _resolved(u, k)
	var T: Script = load("res://代码/配置/技能表.gd")
	T.call("_ensure")
	var d: Dictionary = T.call("get_def", &"shield_up")
	实得["shield_hold"] = String(d.get("anim", {}).get("hold", &""))
	明细.append({"case": "C", "resolved": 实得})
	if String(实得.get("move", "")) != "walk":
		失败.append("move 没解析到 walk（得到 %s）" % String(实得.get("move", "")))
	if String(实得.get("attack", "")) != "attack":
		失败.append("attack 没解析到 attack（得到 %s）" % String(实得.get("attack", "")))
	if String(实得.get("shield_hold", "")) != "shield_hold":
		失败.append("举盾 anim_hold 不是 shield_hold（得到 %s）" % String(实得.get("shield_hold", "")))


func _用例D_真在动() -> void:
	var u = _造(&"footman", Vector3(6.0, 0.0, 0.0))
	if u == null:
		return
	# 关掉单位自己的 _process：否则 _update_anim 每帧把动画推回 idle，
	# 手动 set_state 的这一段活不过一帧（实测会随机假红）。
	_静默(u)
	var sk := _find_skel(u)
	var a := _anim_of(u)
	if sk == null or a == null:
		失败.append("步兵里没有 Skeleton3D 或动画节点")
		return
	await _wait(0.2)
	for state in ["walk", "attack", "shield_hold"]:
		a.call("set_state", state, 1.0, true)
		await _wait(0.10)
		var s1 := _bones(sk)
		await _wait(0.18)
		var s2 := _bones(sk)
		var d := _max_delta(s1, s2)
		明细.append({"case": "D", "state": state, "delta": snappedf(d, 0.0001)})
		if d < 0.008:
			失败.append("%s 播了但骨骼没动（最大位移 %.4fm）" % [state, d])


func _用例E_一刀() -> void:
	var u = _造(&"footman", Vector3(8.0, 0.0, 0.0))
	if u == null:
		return
	_静默(u)
	var a := _anim_of(u)
	if a == null:
		return
	a.call("set_state", "attack", 1.0, true)
	await _wait(0.2)
	var 早 := String(a.call("current_state"))
	var 早相 := float(a.call("phase"))
	await _wait(1.0)
	var 晚 := String(a.call("current_state"))
	var 晚相 := float(a.call("phase"))
	明细.append({"case": "E", "early": [早, snappedf(早相, 0.01)],
		"late": [晚, snappedf(晚相, 0.01)]})
	if 早 != "attack":
		失败.append("attack 没有从 attack 开始播（得到 %s）" % 早)
	if 晚 == "attack":
		失败.append("attack 播完后还停在 attack（会读成连砍）phase=%.2f" % 晚相)

