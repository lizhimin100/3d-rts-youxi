extends Node3D
## **地图据点 + 资源箱**（2026-11-08 玩家口径）
##
## 规则（原话）：
##   「开局 3 分钟后，在地图中心的据点处刷新资源箱；占据据点并持续待 15 秒，
##     资源归占据据点的玩家；此后每 2 分钟刷新一次资源箱。」
##
## 口径细节（都在这份文件里，别在别处再写一份）：
##   · **谁算"占据"**：据点半径内**只有一个阵营**的活兵（建筑不算，农民算 —— 农民也是人）；
##     两个以上阵营同时在圈里 = 争夺中，计时清零；
##   · **计时**：同一个阵营连续待满 `HOLD_TIME` 秒才算拿到；中途换人/被打断就重来；
##   · **奖励**：金 `CRATE_GOLD` + 木 `CRATE_WOOD`，直接进阵营资源（和采集同一条通道）；
##   · **刷新**：开局 `FIRST_DELAY` 秒后第一次，之后每次结算完再等 `INTERVAL` 秒；
##   · 资源箱是个视觉体（美术/模型/木箱.glb），据点圈是贴地环 —— 两者都不挡寻路。
##
## AI 侧：`简单AI._manage_strongpoint()` 读 `value_score()` 判断值不值得派人。

## 第一次刷新的延迟（秒）：开局 3 分钟
const FIRST_DELAY: float = 180.0
## 之后每次刷新的间隔（秒）：2 分钟
const INTERVAL: float = 120.0
## 占据需要的持续秒数
const HOLD_TIME: float = 15.0
## 据点半径（米）
const CAPTURE_RADIUS: float = 8.0
## 一箱的资源
const CRATE_GOLD: int = 200
const CRATE_WOOD: int = 80
## 资源箱模型
const CRATE_MODEL := "res://美术/模型/木箱.glb"

## 据点中心（世界坐标）
var center: Vector3 = Vector3.ZERO
## 资源箱是否在场
var crate_active: bool = false
## 当前计时中的占据者（null = 没人 / 争夺中）
var holder: RtsFaction = null
## 已连续占据的秒数
var hold_time: float = 0.0

var _countdown: float = FIRST_DELAY
var _crate: Node3D = null
var _ring: MeshInstance3D = null
var _tick: float = 0.0
var _ring_mat: StandardMaterial3D = null


func _ready() -> void:
	name = "据点"
	add_to_group("strongpoint")


## 由主场景装配：地图中心
func setup(p_center: Vector3) -> void:
	center = p_center
	global_position = p_center
	_build_ring()
	# 圈一直画着（不然开局没人知道"据点在哪"），箱子上场时再亮
	_set_ring_color(Color(0.82, 0.72, 0.42))


## 每 0.2 秒判定一次就够（15 秒的计时不需要每帧）
func _process(delta: float) -> void:
	if not crate_active:
		_countdown -= delta
		if _countdown <= 0.0:
			_spawn_crate()
		return
	_tick += delta
	if _tick < 0.2:
		return
	_tick = 0.0
	_tick_capture(delta)


# ===========================================================================
# 对外查询（AI / 自检 / 头顶界面读这些）
# ===========================================================================

## 资源箱位置（没箱子时返回据点中心）
func crate_pos() -> Vector3:
	return center


## 距离下次刷新还有多少秒（没箱子时有效）
func countdown() -> float:
	return maxf(_countdown, 0.0)


## 占用进度 0~1
func hold_ratio() -> float:
	return clampf(hold_time / HOLD_TIME, 0.0, 1.0)


## 现在圈里有几个阵营（争夺判断/Debug）
func factions_in_zone() -> Array:
	var out: Array = []
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit) or not (u as RtsUnit).is_alive():
			continue
		if (u as RtsUnit).def != null and (u as RtsUnit).def.is_building():
			continue
		if _flat(u.global_position).length() > CAPTURE_RADIUS:
			continue
		var f: RtsFaction = (u as RtsUnit).faction
		if f == null or f.passive or int(f.team) == 0:
			continue
		if not out.has(f):
			out.append(f)
	return out


## **值多少分**（给 AI 判断"这箱子值不值得派人"）。
## 0 = 不值得去（没箱子 / 已经是我们稳拿 / 家里在挨打）；
## 越高越急：我们正在计时 > 没人占 > 敌人在占。
func value_score(faction: RtsFaction) -> float:
	if not crate_active or faction == null:
		return 0.0
	var who: Array = factions_in_zone()
	if who.size() == 1 and who[0] == faction:
		# 我们已经在圈里：值 = 守着（很小，交给现有驻防逻辑）
		return 0.25
	if who.is_empty():
		return 1.0
	if who.size() == 1:
		# 只有一家（不是我们）= 敌人在占，最急
		return 1.6
	# 混战：去抢也有价值
	return 1.2


# ===========================================================================
# 内部
# ===========================================================================

func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x - center.x, p.z - center.z)


func _spawn_crate() -> void:
	crate_active = true
	hold_time = 0.0
	holder = null
	_crate = _make_crate()
	add_child(_crate)
	_set_ring_color(Color(1.0, 0.84, 0.36))
	Game.toast("据点刷新资源箱：占领 %d 秒得 %d 金 %d 木" % [
		int(HOLD_TIME), CRATE_GOLD, CRATE_WOOD], Color(1.0, 0.86, 0.44))


func _make_crate() -> Node3D:
	var root := Node3D.new()
	root.name = "资源箱"
	if ResourceLoader.exists(CRATE_MODEL):
		var ps: PackedScene = load(CRATE_MODEL)
		if ps != null:
			var inst: Node = ps.instantiate()
			if inst is Node3D:
				var n := inst as Node3D
				# 木箱模型按米建；抬一点离开地面，别插进土里
				n.position.y = 0.45
				n.scale = Vector3.ONE * 1.6
				root.add_child(n)
				# ★ 木箱的 albedo 是**纯灰度**（228,230,232）—— 美术资产是给
				#   "材质族染色"用的（和 自然材质.gd 同一套口径）。直接实例化会是个白箱子，
				#   所以这里按木材色染一遍；只染 albedo，不碰贴图本身。
				_tint_wood(n)
				return root
	# 兜底：一个金色的方箱（模型没 import 也能看见）
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 1.0, 1.2)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.44, 0.18)
	mat.metallic = 0.2
	mat.roughness = 0.6
	mi.material_override = mat
	mi.position.y = 0.5
	root.add_child(mi)
	return root


func _tick_capture(delta: float) -> void:
	var who: Array = factions_in_zone()
	if who.size() != 1:
		# 争夺 / 没人：计时清零（"持续待 15 秒"的语义）
		if hold_time > 0.0:
			hold_time = 0.0
			holder = null
			_set_ring_color(Color(0.86, 0.42, 0.30))
		return
	var f: RtsFaction = who[0]
	if f != holder:
		holder = f
		hold_time = 0.0
	hold_time += delta
	_set_ring_color(Color(0.98, 0.62, 0.24).lerp(Color(0.42, 1.0, 0.55),
			hold_ratio()))
	if hold_time >= HOLD_TIME:
		_claim(f)


func _claim(f: RtsFaction) -> void:
	Game.add_resource(f, CRATE_GOLD, CRATE_WOOD)
	if f == Game.player_faction:
		Game.toast("占领据点：＋%d 金　＋%d 木" % [CRATE_GOLD, CRATE_WOOD],
				Color(1.0, 0.88, 0.46))
	else:
		Game.toast("%s 占领了据点（+%d 金 +%d 木）" % [f.display_name, CRATE_GOLD, CRATE_WOOD],
				Color(0.98, 0.62, 0.42))
	crate_active = false
	hold_time = 0.0
	holder = null
	_countdown = INTERVAL
	if _crate != null and is_instance_valid(_crate):
		_crate.queue_free()
	_crate = null
	_set_ring_color(Color(0.82, 0.72, 0.42))


## 给木箱染色（见 _make_crate 里的注释）。只复制材质，不改共享资源。
func _tint_wood(n: Node) -> void:
	var tint := Color(0.78, 0.56, 0.30)
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for c in cur.get_children():
			stack.append(c)
		var mi := cur as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.mesh.surface_get_material(i)
			if src == null:
				continue
			var mat := src.duplicate() as StandardMaterial3D
			if mat == null:
				continue
			mat.albedo_color = mat.albedo_color * tint
			mi.set_surface_override_material(i, mat)


# ===========================================================================
# 贴地圈（据点范围）
# ===========================================================================

func _build_ring() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var segs: int = 96
	var w: float = 0.35
	for i in range(segs + 1):
		var a: float = TAU * float(i) / float(segs)
		var d := Vector3(cos(a), 0.0, sin(a))
		im.surface_set_color(Color(1, 1, 1, 0.55))
		im.surface_add_vertex(d * CAPTURE_RADIUS)
		im.surface_set_color(Color(1, 1, 1, 0.18))
		im.surface_add_vertex(d * (CAPTURE_RADIUS - w))
	im.surface_end()
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.vertex_color_use_as_albedo = true
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mat.no_depth_test = false
	_ring = MeshInstance3D.new()
	_ring.name = "据点圈"
	_ring.mesh = im
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.position.y = 0.10
	add_child(_ring)


func _set_ring_color(c: Color) -> void:
	if _ring == null or _ring_mat == null:
		return
	_ring_mat.albedo_color = c
