class_name RtsFog
extends Node3D
## **战争迷雾（War Fog）**
##
## 观察方 = 「玩家阵营 + 它的盟友」（is_ally_of）。每个己方单位/建筑按 def.sight_range
## 点亮世界网格；见过的格子进「已探索」（压暗但保留记忆），从没见过的格子全黑。
##
## 表现分三层，**三层共用同一张 fog 贴图**：
##   1) **3D 全屏雾**：贴在相机前的一块四边形，按屏幕深度重建世界坐标，
##      再按世界 XZ 采样迷雾贴图 —— 地面 / 树 / 单位 / 建筑一起被压黑（不是"地上铺灰布"）；
##   2) **实体隐藏**：雾中敌方**单位**隐藏；敌方**建筑**只要探索过一次就保留（魔兽口径：
##      侦察过的房子不会凭空消失）；中立资源探索过才显示；
##   3) **小地图遮罩**：同一张贴图喂给小地图，雾区同样压黑（见 小地图.gd）。
##
## 性能纪律：
##   · 重算 8Hz（UPDATE_INTERVAL），一次 ~1.6 万格 + 几十个视野圆，CPU 忽略不计；
##   · 迷雾贴图**只有真的变了才 upload**（explored 只增不减，绝大多数帧是空转）；
##   · 3D 侧只有 1 个 QuadMesh + 1 张 64KB 贴图，没有额外的 draw call 爆炸。
##
## 关掉：启动参数 `--no-fog`，或 设置菜单里的「战争迷雾 · 开/关」。

## 全屏雾着色器
const SHADER_PATH := "res://美术/着色器/战场迷雾.gdshader"
## 迷雾网格分辨率（每轴格数）。224m / 128 ≈ 1.75m 一格。
const GRID: int = 128
## 重算间隔（秒）
const UPDATE_INTERVAL: float = 0.10
## 未探索 / 已探索（但当前不可见）的压黑比例
const ALPHA_UNSEEN: float = 1.0
const ALPHA_EXPLORED: float = 0.55
## 最小视野半径（米）：农民 9m，但万一某个 def 没配视野，也别让它脚下全黑
const MIN_SIGHT: float = 6.0

## 观察方（玩家阵营）
var observer: RtsFaction = null
## 地形（取世界坐标 → 地面高度用；雾网格本身不需要地形）
var terrain: RtsTerrain = null
## 世界边长（米）
var world_size: float = 224.0
## 迷雾贴图：RGB 黑 + A = 压黑比例（1 = 全黑）。小地图也吃它。
var fog_texture: ImageTexture = null

var _image: Image = null
var _visible: PackedByteArray = PackedByteArray()
var _explored: PackedByteArray = PackedByteArray()
## 当前已上传的 alpha（避免每帧 update 贴图）
var _uploaded: PackedByteArray = PackedByteArray()
var _half: float = 0.0
var _cell: float = 1.0
var _built: bool = false
var _enabled: bool = true
var _acc: float = 0.0
var _overlay: MeshInstance3D = null
var _mat: ShaderMaterial = null
var _cam: Camera3D = null


# ===========================================================================
# 生命周期
# ===========================================================================

## 由 主场景 调用（关卡建完之后）
func setup(p_terrain: RtsTerrain, p_observer: RtsFaction, p_world_size: float) -> void:
	if p_terrain == null or p_observer == null:
		return
	terrain = p_terrain
	observer = p_observer
	world_size = p_world_size if p_world_size > 1.0 else p_terrain.size
	_half = world_size * 0.5
	_cell = world_size / float(GRID)
	var n: int = GRID * GRID
	_visible.resize(n)
	_visible.fill(0)
	_explored.resize(n)
	_explored.fill(0)
	_uploaded.resize(n)
	_uploaded.fill(int(ALPHA_UNSEEN * 255.0))
	_image = Image.create(GRID, GRID, false, Image.FORMAT_RGBA8)
	_image.fill(Color(0.0, 0.0, 0.0, ALPHA_UNSEEN))
	fog_texture = ImageTexture.create_from_image(_image)
	if "--no-fog" in OS.get_cmdline_user_args():
		_enabled = false
	add_to_group("fog_system")
	_built = true
	# 开局先算一遍，避免"整片黑"闪一下
	if _enabled:
		_compute_visibility()
		print("[迷雾] 已就绪：网格 %d²（一格 %.2fm），观察方 %s"
			% [GRID, _cell, observer.display_name])
	else:
		print("[迷雾] 已关闭（--no-fog）")


func _exit_tree() -> void:
	set_process(false)
	_image = null
	fog_texture = null
	_overlay = null
	_mat = null
	_cam = null


## 开关（设置菜单 / 命令行共用）
func set_enabled(on: bool) -> void:
	if _enabled == on:
		return
	_enabled = on
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.visible = on
	if on:
		_compute_visibility()
		print("[迷雾] 已开启")
	else:
		# 关掉时把被隐藏的实体全部放出来，否则"关迷雾"等于"敌人永远隐身"
		_show_all()
		print("[迷雾] 已关闭")


func is_enabled() -> bool:
	return _enabled


# ===========================================================================
# 每帧
# ===========================================================================

## 性能计时（探针读它）
static var dbg_usec: int = 0

func _process(delta: float) -> void:
	if not _built:
		return
	var _t0: int = Time.get_ticks_usec()
	_process_inner(delta)
	RtsFog.dbg_usec += Time.get_ticks_usec() - _t0


func _process_inner(delta: float) -> void:

	if _overlay == null or not is_instance_valid(_overlay):
		_ensure_overlay()
	if _overlay != null:
		_sync_overlay_size()
	if not _enabled or observer == null:
		return
	if Game.phase != RtsConst.Phase.RUNNING and Game.phase != RtsConst.Phase.PREPARE:
		return
	_acc += delta
	if _acc < UPDATE_INTERVAL:
		return
	_acc = 0.0
	_compute_visibility()


## 建全屏雾（挂在当前 3D 相机下）。相机可能比迷雾晚建/被换，所以每帧补一次。
func _ensure_overlay() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	if _mat == null:
		if not ResourceLoader.exists(SHADER_PATH):
			push_warning("[迷雾] 读不到着色器 %s" % SHADER_PATH)
			return
		var sh: Shader = load(SHADER_PATH) as Shader
		if sh == null:
			return
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mat.set_shader_parameter("fog_tex", fog_texture)
		_mat.set_shader_parameter("map_size", Vector2(world_size, world_size))
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_overlay = MeshInstance3D.new()
	_overlay.name = "战场迷雾_全屏"
	_overlay.mesh = quad
	_overlay.material_override = _mat
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_overlay.position = Vector3(0.0, 0.0, -1.0)
	# 相机在 1 米处的半高 = tan(fov/2)，半宽再乘 aspect；QuadMesh 尺寸是 2×2
	_overlay.scale = Vector3(0.6, 0.6, 1.0)
	cam.add_child(_overlay)
	_cam = cam
	_overlay.visible = _enabled
	_sync_overlay_size()


## 相机 fov / 视口比例变了就重算铺满屏幕的缩放
func _sync_overlay_size() -> void:
	if _cam == null or _overlay == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var vs: Vector2 = vp.get_visible_rect().size
	if vs.y < 1.0:
		return
	var half_h: float = tan(deg_to_rad(_cam.fov) * 0.5)
	var aspect: float = vs.x / vs.y
	_overlay.scale = Vector3(half_h * aspect, half_h, 1.0)


# ===========================================================================
# 可见性
# ===========================================================================

func _compute_visibility() -> void:
	if observer == null:
		return
	_visible.fill(0)
	for f in Game.factions:
		if f == null:
			continue
		if f != observer and not observer.is_ally_of(f):
			continue
		_mark_faction(f)
	_refresh_texture()
	_apply_visibility()


## 一个阵营（含自己）的所有眼位：单位 + 建筑，按 sight_range 点亮圆盘
func _mark_faction(f: RtsFaction) -> void:
	var stack: Array = []
	stack.append_array(f.units)
	stack.append_array(f.buildings)
	for e in stack:
		if e == null or not is_instance_valid(e):
			continue
		var n := e as Node3D
		if n == null:
			continue
		if n is RtsUnit and not (n as RtsUnit).is_alive():
			continue
		if n is RtsBuilding and not (n as RtsBuilding).is_alive():
			continue
		var def: UnitDef = n.get("def") as UnitDef
		var r: float = MIN_SIGHT
		if def != null:
			r = maxf(def.sight_range, MIN_SIGHT)
		# 世界坐标直接用：迷雾网格是"以原点为中心的正方形"，地形节点本身在原点。
		# （旧版先 to_local 再查，查询侧却没转 —— 一旦地形有位移就会整体错位。）
		var wp: Vector3 = n.global_position
		_mark_disk(wp.x, wp.z, r)


func _mark_disk(cx: float, cz: float, r: float) -> void:
	var minx: int = maxi(0, int(floor((cx - r + _half) / _cell)))
	var maxx: int = mini(GRID - 1, int(floor((cx + r + _half) / _cell)))
	var minz: int = maxi(0, int(floor((cz - r + _half) / _cell)))
	var maxz: int = mini(GRID - 1, int(floor((cz + r + _half) / _cell)))
	var r2: float = r * r
	for gz in range(minz, maxz + 1):
		var wz: float = -_half + (float(gz) + 0.5) * _cell
		var dz: float = wz - cz
		var row: int = gz * GRID
		for gx in range(minx, maxx + 1):
			var wx: float = -_half + (float(gx) + 0.5) * _cell
			var dx: float = wx - cx
			if dx * dx + dz * dz <= r2:
				_visible[row + gx] = 1


## 可见格 → explored 记忆 → 贴图 alpha。**只有变了才上传**。
func _refresh_texture() -> void:
	if _image == null or fog_texture == null:
		return
	var n: int = GRID * GRID
	var data := PackedByteArray()
	data.resize(n * 4)
	var changed: bool = false
	for i in range(n):
		var a: int
		if _visible[i] == 1:
			a = 0
			_explored[i] = 1
		elif _explored[i] == 1:
			a = int(ALPHA_EXPLORED * 255.0)
		else:
			a = int(ALPHA_UNSEEN * 255.0)
		var p: int = i * 4
		data[p] = 0
		data[p + 1] = 2
		data[p + 2] = 4
		data[p + 3] = a
		if _uploaded[i] != a:
			_uploaded[i] = a
			changed = true
	if not changed:
		return
	_image.set_data(GRID, GRID, false, Image.FORMAT_RGBA8, data)
	fog_texture.update(_image)


## 实体显隐：敌方单位只在当前可见时出现；敌方建筑探索过就留着；资源探索过才出现。
func _apply_visibility() -> void:
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null:
			continue
		var f: RtsFaction = n.get("faction")
		if f != null and (f == observer or observer.is_ally_of(f)):
			if not n.visible:
				n.visible = true
			continue
		if f == null:
			continue
		var show: bool
		if n is RtsBuilding:
			show = is_world_explored_pos(n.global_position)
		else:
			show = is_world_visible_pos(n.global_position)
		if n.visible != show:
			n.visible = show
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		var hn := h as Node3D
		if hn == null:
			continue
		var expl: bool = is_world_explored_pos(hn.global_position)
		if hn.visible != expl:
			hn.visible = expl


## 关迷雾时把所有被藏起来的实体放出来
func _show_all() -> void:
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n != null and not n.visible:
			n.visible = true
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		var hn := h as Node3D
		if hn != null and not hn.visible:
			hn.visible = true


# ===========================================================================
# 查询（小地图 / 单位可见性共用）
# ===========================================================================

func is_world_visible(wx: float, wz: float) -> bool:
	return is_world_visible_pos(Vector3(wx, 0.0, wz))


func is_world_visible_pos(p_world: Vector3) -> bool:
	var gx: int = int(floor((p_world.x + _half) / _cell))
	var gz: int = int(floor((p_world.z + _half) / _cell))
	if gx < 0 or gx >= GRID or gz < 0 or gz >= GRID:
		return false
	return _visible[gz * GRID + gx] == 1


func is_world_explored(wx: float, wz: float) -> bool:
	return is_world_explored_pos(Vector3(wx, 0.0, wz))


func is_world_explored_pos(p_world: Vector3) -> bool:
	var gx: int = int(floor((p_world.x + _half) / _cell))
	var gz: int = int(floor((p_world.z + _half) / _cell))
	if gx < 0 or gx >= GRID or gz < 0 or gz >= GRID:
		return false
	return _explored[gz * GRID + gx] == 1
