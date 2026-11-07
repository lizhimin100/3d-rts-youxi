class_name RtsHarvestable
extends Node3D
## **可采集物**：金矿 / 树木。
##
## 枯竭表现（任务书要求）：
##   · 金矿：变暗（留在原地当场景残骸），从资源注册表里注销
##   · 树木：倒下 → 沉没 → 消失，并把它占的寻路格子放出来（别留隐形墙）
##
## 注意：可采集物的 faction 是 **null**（Game.spawn_unit(null, ...)），
## 所以这里任何地方都不能假设 faction 非空。

## 树倒下 / 沉没耗时（秒）
const FALL_TIME: float = 0.75
const SINK_TIME: float = 0.5
## 金矿枯竭后的明度系数
const DEPLETED_DARKEN: float = 0.32
## 表现层随机流（倒向哪边）。玩法随机仍走全局 randf，见 表现随机.gd
const Fx := preload("res://代码/美术/表现随机.gd")

var def: UnitDef = null
var remaining: int = 0
var harvest_kind: int = RtsConst.Harvest.GOLD
var faction: RtsFaction = null

## 外观（复用 UnitVisual：建模型 + 挂动画）
var visual: UnitVisual = null
## 程序化外观参数（树用）：{"season", "seed", "yaw"}。
## 存在节点上而不是塞回 UnitDef —— UnitDef 是全局共享的一整份表，见不得"每棵树不一样"。
var proc: Dictionary = {}
var _depleting: bool = false
var _visual_built: bool = false


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	if def != null:
		_ensure_visual()


## 装配（Game.spawn_unit 在 add_child 之后调）
## p_proc：程序化外观参数（树）。留空 = 由落点反推种子（程序化地图走这条）。
func setup(p_faction: RtsFaction, p_def: UnitDef, p_proc: Dictionary = {}) -> void:
	faction = p_faction
	def = p_def
	if def == null:
		return
	remaining = maxi(def.resource_amount, 1)
	harvest_kind = def.harvest_kind
	proc = p_proc.duplicate(true)
	if TreeLibrary.is_tree(def.id):
		# ★ 缺什么补什么：编辑器摆的树只存了 seed/season/yaw，
		#   缩放/倾斜/下沉要按落点补出来 —— 否则手摆的林子会是"同一个尺寸的复制粘贴"，
		#   而程序化地图的林子高低错落，两种来源一混就露馅。
		var auto: Dictionary = TreeLibrary.proc_at(position)
		for k in auto:
			if not proc.has(k):
				proc[k] = auto[k]
	_ensure_visual()


func _ensure_visual() -> void:
	if _visual_built or def == null:
		return
	_visual_built = true
	visual = UnitVisual.new()
	visual.name = "外观"
	add_child(visual)
	var cfg: GameConfig = Cfg.game
	var col: Color = cfg.gold_color if harvest_kind == RtsConst.Harvest.GOLD \
			else Color(0.45, 0.72, 0.36)
	visual.build(def, col, proc)


# ===========================================================================
# 查询
# ===========================================================================

## 是否采空
func is_depleted() -> bool:
	return remaining <= 0


## 还有没有（统一 is_alive 接口，农民/关卡都会问）
func is_alive() -> bool:
	return remaining > 0


## 碰撞/站位半径
func get_radius() -> float:
	return def.body_radius if def != null else 1.0


## 头顶位置
func selection_point() -> Vector3:
	var h: float = def.height if def != null else 3.0
	return global_position + Vector3.UP * h


## "走进矿洞"的落点（世界坐标）。只有 goldmine 用；树没有这个函数，调用方用 has_method 探测。
##
## 为什么不用模型上那个真实洞口（glb 里局部 z=-1.30 的 M_cavity 暗板）：
##   · 关卡把矿转了 180°（关卡.gd 的 `rotation.y = PI`），洞口落在**背对玩家**的那一面；
##   · 玩家还可能在地图编辑器里把矿摆成任意朝向。
##   写死一个局部坐标，总有一半矿是"人往石头背面飘"。
##
## 现在按**来访方向**取最近的岩壁：人朝矿走，1.35m 就进到岩石轮廓里
## （矿体外包半宽约 1.95m），被不透明的岩石挡住 → 读起来就是"钻进矿洞"。
## y 只抬 0.55m：洞口本身就在地表附近，不需要爬升。
func mouth_point(from_pos: Vector3) -> Vector3:
	var d: Vector3 = from_pos - global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		d = Vector3(0.0, 0.0, 1.0)
	d = d.normalized()
	return global_position + d * 1.35 + Vector3.UP * 0.55


# ===========================================================================
# 载位（魔兽口径：一个矿/一棵树能同时站几个农民）
# ===========================================================================
## 采集者 id → 载位号。载位不是"排队名额"，而是**站桩位置**：
## 三个人站矿的三个方向，不会叠在同一个点上互相推。
var _slots: Dictionary = {}


## 这个资源点有几个载位（金矿 3、树 2）。改数量改这里，技能表的 slots 只是说明。
func max_slots() -> int:
	return 3 if harvest_kind == RtsConst.Harvest.GOLD else 2


## 占一个载位，返回编号（0..n-1）。满了返回 -1（调用方退回通用站位）。
func claim_slot(unit: Node) -> int:
	if unit == null or not is_instance_valid(unit):
		return -1
	var id: int = unit.get_instance_id()
	if _slots.has(id):
		return int(_slots[id])
	var used: Dictionary = {}
	for k in _slots:
		used[int(_slots[k])] = true
	for i in max_slots():
		if not used.has(i):
			_slots[id] = i
			return i
	return -1


## 让出载位（离矿/换目标/死亡时必须调，否则位置会永久漏掉）
func release_slot(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	_slots.erase(unit.get_instance_id())


## 第 idx 个载位的世界坐标（围着矿/树散开）。
func slot_point(idx: int, from_pos: Vector3) -> Vector3:
	var d: Vector3 = from_pos - global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		d = Vector3(0.0, 0.0, 1.0)
	d = d.normalized()
	var n: int = max_slots()
	var ang: float = (float(idx) - float(n - 1) * 0.5) * 0.62
	var dir := Vector3(d.x * cos(ang) - d.z * sin(ang), 0.0,
			d.x * sin(ang) + d.z * cos(ang))
	if harvest_kind == RtsConst.Harvest.GOLD:
		return global_position + dir * 1.45 + Vector3.UP * 0.55
	# 树：站到树冠外一圈，y 交给调用方贴地（树本身有 _snap_ground）
	var r: float = get_radius() + 0.95
	return global_position + dir * r


# ===========================================================================
# 采集
# ===========================================================================

## 这个资源点是「按次数」还是「按数量」计消耗。
##
## 树 = 按次数（玩家口径 2026-11-07：一棵树 20 次，采一次扣一次）；
## 金矿 = 按吨位（3200 金 / 一次搬 10）。两种口径分开，UI 也就能分别显示「剩 12 次」/「剩 43%」。
func is_charge_based() -> bool:
	return harvest_kind == RtsConst.Harvest.WOOD


## **按次采集**：扣 1 次，返回这一趟拿到的产量（per_action = 农民的载重）。
##
## 为什么要单独一个入口（而不是复用 consume）：`consume(10)` 会扣 10 次，
## 一棵 20 次的树只能采两趟 —— 玩家要的是「采 20 趟」。
func consume_charge(per_action: int) -> int:
	if remaining <= 0 or per_action <= 0:
		return 0
	remaining -= 1
	if remaining <= 0:
		remaining = 0
		_deplete()
	return per_action


## 采走 amount，返回**实际采到的数量**（不足就采完为止）
func consume(amount: int) -> int:
	if amount <= 0 or remaining <= 0:
		return 0
	var take: int = mini(amount, remaining)
	remaining -= take
	if remaining <= 0:
		remaining = 0
		_deplete()
	return take


## 被砍时晃一下（2026-11-06 玩家口径「采木头不要木渣，只需要树会摇晃」）。
##
## 只转 `visual`（UnitVisual 外壳），不动本体：
##   · 本体的 rotation.y 是关卡给的朝向，rotation.z 被 _deplete_tree 的倒下动画占着；
##   · 树的静态倾斜/下沉烘焙在 visual 内层的 root 上（树库.gd），外壳转一圈不会打架。
var _shake_tw: Tween = null

func shake(strength: float = 1.0) -> void:
	if visual == null or not is_instance_valid(visual):
		return
	if _shake_tw != null and _shake_tw.is_valid():
		_shake_tw.kill()
	var amp: float = deg_to_rad(2.6) * clampf(strength, 0.3, 2.0)
	var ax: float = 1.0 if Fx.rand() > 0.5 else -1.0
	visual.rotation = Vector3.ZERO
	_shake_tw = create_tween()
	_shake_tw.tween_property(visual, "rotation", Vector3(ax * amp, 0.0, amp * 0.6), 0.07)
	_shake_tw.tween_property(visual, "rotation", Vector3(-ax * amp * 0.6, 0.0, -amp * 0.35), 0.09)
	_shake_tw.tween_property(visual, "rotation", Vector3(ax * amp * 0.3, 0.0, amp * 0.15), 0.09)
	_shake_tw.tween_property(visual, "rotation", Vector3.ZERO, 0.11)


## 枯竭
func _deplete() -> void:
	if _depleting:
		return
	_depleting = true

	# 立刻从资源注册表注销：农民和 AI 马上就能看到"这没货了"
	Game.unregister(self)

	if harvest_kind == RtsConst.Harvest.GOLD:
		_deplete_gold()
	else:
		_deplete_tree()


## 金矿：变暗，留在原地当场景残骸
func _deplete_gold() -> void:
	_darken(self, DEPLETED_DARKEN)
	ArtKit.vfx_death(global_position, Cfg.game.gold_color)


## 树木：倒下 → 沉没 → 消失，并把占格放出来
func _deplete_tree() -> void:
	_free_footprint()
	ArtKit.vfx_death(global_position + Vector3.UP * 1.0, Color(0.42, 0.62, 0.30))

	var tw: Tween = create_tween()
	# 朝随机一侧倒下去
	var dir: float = 1.0 if Fx.rand() > 0.5 else -1.0
	tw.tween_property(self, "rotation:z", deg_to_rad(84.0) * dir, FALL_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_interval(0.15)
	tw.tween_property(self, "position:y", position.y - 2.2, SINK_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


## 递归压暗所有网格材质（金矿枯竭）
func _darken(n: Node, factor: float) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = Color(
				mat.albedo_color.r * factor,
				mat.albedo_color.g * factor,
				mat.albedo_color.b * factor,
				mat.albedo_color.a)
			mat.emission_energy_multiplier = 0.0
	for c in n.get_children():
		_darken(c, factor)


## 把树占的寻路格子放出来 —— **唯一出口**：关卡的道具占格引用计数。
##
## 旧实现（已删）：按 `def.footprint`（2×2）逐格 `mark_blocked(false)`，和挡格用的
## 0.95m 圆（5 格）根本不是一回事 ——
##   · 圆的 5 格只放了 2~4 格 → **留 2 个隐形阻挡格**（单位绕空气）；
##   · 放出来的 2×2 还可能是邻树 / 岩石 / 建筑的格子 → A* 认为能过，
##     单位真的走进旁边那棵活树的树冠，然后被净空判据顶住 = "被树卡住"。
## 现在档格和释放都走 `占格规则` 的同一份格子，并做引用计数：
## 只有"没有任何别的道具占着、也不是地形/水/边界"的格子才真正恢复可走。
func _free_footprint() -> void:
	if def == null:
		return
	RtsWorld.release_prop(self)
