extends RefCounted
## **技能特效注册表**：技能卡里的 `vfx_on / vfx_off` 存的是 id，这里负责"id → 真的冒一个东西"。
##
## 为什么单独一层（玩家口径 2026-11-07）：技能和特效要**分开**做。
##   · 技能卡只写 `vfx_on = &"weapon_glint"`，不关心它长什么样；
##   · 特效自己知道挂在哪（武器 / 胸口 / 脚下）、多大、多亮；
##   · 缺特效时**不许报错**，退到一个"占位微光"就行 —— 后续玩家补上真特效，
##     只要在 match 里加一行，技能卡不用动。
##
## 加一个特效：
##   1. 在 `代码/美术/特效生成.gd` 里写实现（或者复用已有的）；
##   2. 在下面 `match` 里加一个 case；
##   3. 技能卡的 `vfx_on` 填这个 id。

const VFX := preload("res://代码/美术/特效生成.gd")
## 未注册 id 只警告一次（同一局里几百个单位切技能，不刷屏）
static var _warned: Dictionary = {}


## 播一次技能特效。`id` 为空直接返回。
static func play(unit: Node3D, id: StringName) -> void:
	if unit == null or not is_instance_valid(unit) or id == &"":
		return
	match id:
		&"weapon_glint":
			_weapon_glint(unit)
		&"none":
			pass
		_:
			if not _warned.has(id):
				_warned[id] = true
				push_warning("[技能特效] 未注册的 id：%s（先用占位微光顶替，去 代码/系统/技能特效.gd 补一个 case）" % id)
			_placeholder(unit)


## **切换武器特效**：只在手中武器上闪一下，不整只人变白。
static func _weapon_glint(unit: Node3D) -> void:
	var pos: Vector3 = _weapon_pos(unit)
	VFX.weapon_glint(pos)


## 占位：胸口一点极淡的白光。用来证明"技能触发了"，但不假装自己有真特效。
static func _placeholder(unit: Node3D) -> void:
	var h: float = 1.0
	var d: UnitDef = unit.get("def") as UnitDef
	if d != null:
		h = maxf(d.height * 0.55, 0.4)
	var pos: Vector3 = unit.global_position + Vector3.UP * h
	VFX.weapon_glint(pos, Color(0.78, 0.84, 0.92), 0.22)


## 武器位置：优先找模型里的 `weapon_R` / `weapon_L` 骨骼，找不到退回"右手大概位置"。
##
## 为什么不缓存：单位可能换模型（建筑改造那种），而且这个查询每次切技能才走一次
## （不是每帧），一次 find_child 的代价远小于出错的风险。
static func _weapon_pos(unit: Node3D) -> Vector3:
	var v: Variant = unit.get("visual")
	if v != null and is_instance_valid(v):
		var m: Variant = v.get("_model")
		if m is Node:
			var w: Node = (m as Node).find_child("weapon_R", true, false)
			if w == null:
				w = (m as Node).find_child("weapon_L", true, false)
			if w is Node3D:
				return (w as Node3D).global_position
	# 兜底：胸口高度 + 前方 0.45 + 右侧 0.28（方块人的持械手就在这附近）
	var fwd: Vector3 = -unit.global_transform.basis.z
	var right: Vector3 = unit.global_transform.basis.x
	return unit.global_position + Vector3.UP * 1.0 + fwd * 0.45 + right * 0.28
