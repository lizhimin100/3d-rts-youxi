class_name RtsCreeps
extends Node
## **中立野怪阵营** —— 只做两件事：建阵营、把编辑器摆的中立单位收编进去。
##
## ★ 2026-11-01 玩家最终口径（本文件按这个重写）：
##   "野怪系统也先别弄错……重点是编辑器能看到野怪（是不是野怪是代码刷新？
##    是的话就删除，我自己来放置）。"
##
## 所以**代码刷新野怪的那一整套已经整块删掉**：
##   ✗ 自动撒营地（`_place_camps` / 最远点采样）
##   ✗ 定时补怪（`SPAWN_INTERVAL` / `PER_CAMP_CAP`）
##   ✗ 入夜成批扑家（`NIGHT_WAVE` / `night_started` 钩子）
##   ✗ 桥接地牢的 `_adopt_editor_lairs`（地牢本身也删了）
##
## 现在野怪**只有一个来源：玩家在地图编辑器里摆**。
## 这个脚本只剩两件必要的活：
##   1. 建一个 team 0 的**中立阵营**（`Game.neutral_faction`）——
##      没有它，编辑器摆的中立单位就是"没有阵营的死单位"：打不到人、不还手、
##      小地图不显示、AI 也不把它当敌人；
##   2. **收编**：把 `faction == null` 的野怪补进中立阵营（兜底）。
##      正常路径下地图加载器已经直接给了中立阵营（见 地图加载器.spawn_map_objects），
##      这里只是防止旧图 / 别的生成路径漏掉 —— 幂等，重复调用无害。
##
## ⚠ 营地已于 2026-11-06 接入：由 `代码/系统/野怪营地.gd` 负责，
##   **仍然没有**"入夜总攻 / 定时补怪 / 自动撒营地" —— 营地必须是玩家在地图编辑器里
##   摆下的锚点建筑（owner = -1）。代码只认建筑，不自己造营地。

## 中立阵营的 id / 显示名（`Game.neutral_faction` 就是它）
const NEUTRAL_ID := 99
const NEUTRAL_NAME := "豺狼人"
const NEUTRAL_COLOR := Color(0.72, 0.28, 0.18)
## 哪些 id 属于"野怪"（收编时以此为准；和编辑器的 CREEP_IDS 保持一致）
const CREEP_IDS: Array[String] = ["gnoll_warrior", "gnoll_scout"]

## 可配置营地系统（`代码/系统/野怪营地.gd`）。
## 为什么预加载而不是 class_name：同 RtsCreeps 的理由 —— 别碰全局类缓存（AGENTS.md §二）。
const CAMP_SCRIPT := preload("res://代码/系统/野怪营地.gd")

var faction: RtsFaction = null
var _level: Node3D = null
## 营地系统节点（实际类型 = CAMP_SCRIPT）。只在这里挂一次，外部一律 `.call("…")`。
var camp_system: Node3D = null


# ===========================================================================
# 建阵营（必须在关卡/地图对象生成**之前**调，否则中立单位会先落地成"无阵营"）
# ===========================================================================

## 建中立阵营。幂等：已经有就直接用。
func ensure_faction() -> RtsFaction:
	if faction != null and is_instance_valid(faction):
		return faction
	if Game.neutral_faction != null and is_instance_valid(Game.neutral_faction):
		faction = Game.neutral_faction
		return faction
	faction = RtsFaction.new()
	faction.setup(NEUTRAL_ID, false, NEUTRAL_NAME, NEUTRAL_COLOR, 0, 0)
	faction.team = 0          # team 0 = 对任何队伍都敌对
	faction.slot = -1         # 不占玩家槽位 → 不参与胜负判定
	faction.is_ai = false     # 没有经济、没有大脑（野怪不会自己造东西）
	Game.neutral_faction = faction
	return faction


## 主场景在关卡建好之后调用。`day` 参数保留但不再使用（夜袭已删除），
## 只是为了不改主场景的调用签名。
func setup(level: Node3D, _day: Node = null) -> void:
	_level = level
	ensure_faction()
	_adopt_orphans()
	# 营地在**收编之后**挂：收编只管"已经躺在地上的散兵"，
	# 营地负责"按配置新刷出来的兵"，两件事不重叠（重复刷同一只也不会发生）。
	_mount_camps()
	var n: int = alive_count()
	if n > 0:
		print("[野怪] 中立阵营「%s」就绪：地图上共 %d 只野怪" % [NEUTRAL_NAME, n])
	else:
		print("[野怪] 中立阵营「%s」就绪（地图上还没有野怪 —— 在编辑器里摆即可）"
			% NEUTRAL_NAME)


## 挂营地系统（幂等：重复 setup 只重建识别结果，不叠第二个节点）
func _mount_camps() -> void:
	if camp_system == null or not is_instance_valid(camp_system):
		camp_system = CAMP_SCRIPT.new()
		camp_system.name = "野怪营地"
		add_child(camp_system)
	camp_system.call("setup", faction)


## 兜底收编：把"有野怪 id 但没有阵营"的单位挂到中立阵营上。
##
## 什么时候会走到这里：地图加载器在 `Game.neutral_faction` 还不存在时就需要落单位，
## 或者旧版本地图文件里 owner 是 -1 而当时没有阵营。幂等。
func _adopt_orphans() -> void:
	if faction == null:
		return
	for n in Game.all_units():
		if n == null or not is_instance_valid(n):
			continue
		var u := n as RtsUnit
		if u == null or u.def == null:
			continue
		if not CREEP_IDS.has(String(u.def.id)):
			continue
		if u.faction != null:
			continue
		u.faction = faction
		if not faction.units.has(u):
			faction.units.append(u)
		print("[野怪] 收编无阵营野怪 %s @ (%.0f, %.0f)" % [
			String(u.def.id), u.global_position.x, u.global_position.z])


# ===========================================================================
# 查询（给自检 / 小地图 / AI 用）
# ===========================================================================

## 当前活着的野怪数量
func alive_count() -> int:
	if faction == null:
		return 0
	var n: int = 0
	for u in faction.units:
		if u != null and is_instance_valid(u) and u.is_alive():
			n += 1
	return n


## 这个 id 是不是野怪（编辑器与运行时共用一套判据）
static func is_creep_id(id: StringName) -> bool:
	return CREEP_IDS.has(String(id))
