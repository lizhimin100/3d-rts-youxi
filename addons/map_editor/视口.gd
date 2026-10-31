@tool
extends SubViewportContainer
## **地图编辑视口**：主屏上的那块 3D 面板。
##
## 独立世界：SubViewport.own_world_3d = true —— 自己的 World3D / 相机 / 灯光 / 网格，
## 和当前编辑的场景**完全隔离**，不会污染、不会被编辑器的 3D gizmo 碰到。
##
## 地形直接复用游戏里的 RtsTerrain（同一份网格算法 + 同一份材质），
## 所以"编辑器里刷出来的"和"游戏里跑出来的"是同一张图。

signal ground_changed(pos: Vector3, valid: bool)

## 网格叠加线间距（米）
const GRID_STEP: float = 4.0
## 屏幕点选半径（像素）：越大越"吸"。30px 在 1080p 上够点小单位，又不会误吸邻居
const PICK_PIXELS: float = 30.0
## 建筑网格唯一实现（@tool 纯函数）
const GRID := preload("res://代码/单位/建筑网格.gd")
## 编辑模式（与 编辑会话.Mode 对应；写成本地常量，避免跨脚本取枚举）
const MODE_TERRAIN: int = 0
const MODE_OBJECT: int = 1
const MODE_REGION: int = 2
const MODE_SELECT: int = 3

var session = null

var vp: SubViewport
var cam: Camera3D
var world_env: WorldEnvironment
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var terrain: RtsTerrain
var objects_root: Node3D
var regions_root: Node3D
var sel_root: Node3D
var helper_root: Node3D
var grid_mi: MeshInstance3D
var brush_mi: MeshInstance3D
## 地表层（splatmap）覆盖网格：和游戏里 MapLoader 用的是同一个生成函数
var splat_mi: MeshInstance3D
var sel_box: Panel
## 建筑放置预览（幽灵盒 + 1m 占格线框）
var _place_ghost: MeshInstance3D = null
var _place_grid: MeshInstance3D = null
var _place_mat: StandardMaterial3D = null
var _place_key: String = ""

var _yaw: float = deg_to_rad(32.0)
var _pitch: float = deg_to_rad(-54.0)
var _dist: float = 130.0
var _target: Vector3 = Vector3.ZERO

var _dirty_terrain: bool = true
var _dirty_objects: bool = true
var _dirty_regions: bool = true
var _dirty_helpers: bool = true
var _dirty_splat: bool = true
var _clock: float = 0.0

var _orbiting: bool = false
## 左键发起的轨道旋转（手型状态）：松左键时要自己收尾，
## 不能跟中键的 _orbiting 互相踩。
var _left_orbit: bool = false
var _panning: bool = false
var _rmb_moved: float = 0.0
var _painting: bool = false
var _dragging: bool = false
var _drag_last: Vector3 = Vector3.ZERO
var _boxing: bool = false
var _box_start: Vector2 = Vector2.ZERO
var _ground: Vector3 = Vector3.INF
var _previews: Dictionary = {}
var _poly: PackedVector2Array = PackedVector2Array()
var _region_start: Vector2 = Vector2.INF
var _region_dragging: bool = false
## 视图开关（菜单「显示网格 / 显示区域」）
var _grid_visible: bool = true
var _regions_visible: bool = true
## setup() 可能早于 _ready()（插件建节点时还没入树），这里记一笔，进树后补建
var _pending_build: bool = false
## 首次真正可见时才建网格（页签没开就别烧 CPU/显存）
var _built_once: bool = false


func _ready() -> void:
	name = "编辑视口"
	# stretch = true 时容器会接管 SubViewport 尺寸，但隐藏时会被设成 0；
	# 这里改成自己管尺寸（stretch = false + resized 里同步），既不警告也不出 0×0。
	stretch = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	_build_viewport()
	_build_world()
	# 页签没选中时容器尺寸是 0，SubViewport 会跟着变 0 → 渲染器刷一堆
	# "compute threads (0)" / "uniform_set is null" 的报错。隐藏时直接停渲染。
	visibility_changed.connect(_on_visibility_changed)
	resized.connect(_on_resized)
	_on_visibility_changed()
	if _pending_build:
		_pending_build = false
	if session != null and session.def != null and is_visible_in_tree():
		_build_now()


# ===========================================================================
# 搭建
# ===========================================================================

func _build_viewport() -> void:
	vp = SubViewport.new()
	vp.name = "地图编辑子视口"
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_2X
	vp.size = Vector2i(1280, 720)
	add_child(vp)
	cam = Camera3D.new()
	cam.name = "编辑相机"
	cam.fov = 45.0
	cam.near = 0.1
	cam.far = 1200.0
	vp.add_child(cam)
	cam.current = true
	# 框选矩形（画在子视口的 2D 层，坐标就是视口像素）
	var layer := CanvasLayer.new()
	layer.name = "覆盖层"
	vp.add_child(layer)
	sel_box = Panel.new()
	sel_box.name = "框选"
	sel_box.visible = false
	sel_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.35, 0.72, 1.0, 0.12)
	sb.border_color = Color(0.45, 0.82, 1.0, 0.95)
	sb.set_border_width_all(1)
	sel_box.add_theme_stylebox_override("panel", sb)
	layer.add_child(sel_box)


func _build_world() -> void:
	world_env = WorldEnvironment.new()
	world_env.name = "环境"
	var env_res: Resource = null
	if ResourceLoader.exists("res://美术/环境/战斗环境.tres"):
		env_res = load("res://美术/环境/战斗环境.tres")
	if env_res is Environment:
		world_env.environment = env_res
	else:
		world_env.environment = _fallback_env()
	vp.add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "主光"
	sun.rotation_degrees = Vector3(-48, -66, 0)
	sun.light_color = Color(1.0, 0.94, 0.83)
	sun.light_energy = 2.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	sun.shadow_bias = 0.085
	sun.shadow_normal_bias = 1.85
	vp.add_child(sun)

	fill = DirectionalLight3D.new()
	fill.name = "补光"
	fill.rotation_degrees = Vector3(-22, 118, 0)
	fill.light_color = Color(0.46, 0.61, 0.95)
	fill.light_energy = 0.30
	vp.add_child(fill)

	terrain = RtsTerrain.new()
	terrain.name = "地形"
	vp.add_child(terrain)

	objects_root = Node3D.new()
	objects_root.name = "对象"
	vp.add_child(objects_root)
	regions_root = Node3D.new()
	regions_root.name = "区域"
	vp.add_child(regions_root)
	sel_root = Node3D.new()
	sel_root.name = "选中"
	vp.add_child(sel_root)
	helper_root = Node3D.new()
	helper_root.name = "辅助"
	vp.add_child(helper_root)

	# 建筑放置预览：先建好，后面只改 transform / mesh，不每帧 new
	_place_ghost = MeshInstance3D.new()
	_place_ghost.name = "建筑放置预览"
	_place_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_place_mat = StandardMaterial3D.new()
	_place_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_place_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_place_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.30)
	_place_ghost.material_override = _place_mat
	_place_ghost.visible = false
	vp.add_child(_place_ghost)

	splat_mi = MeshInstance3D.new()
	splat_mi.name = "地表层"
	splat_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	vp.add_child(splat_mi)

	grid_mi = MeshInstance3D.new()
	grid_mi.name = "网格"
	grid_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	helper_root.add_child(grid_mi)
	brush_mi = MeshInstance3D.new()
	brush_mi.name = "笔刷"
	brush_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	helper_root.add_child(brush_mi)


func _fallback_env() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.16, 0.24, 0.36)
	sm.sky_horizon_color = Color(0.55, 0.60, 0.66)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	return env


func setup(p_session) -> void:
	session = p_session
	if session == null:
		return
	if not session.def_changed.is_connected(_on_def_changed):
		session.def_changed.connect(_on_def_changed)
	if not session.selection_changed.is_connected(_on_selection_changed):
		session.selection_changed.connect(_on_selection_changed)
	if session.has_signal("tool_changed") and not session.tool_changed.is_connected(_on_tool_changed):
		session.tool_changed.connect(_on_tool_changed)
	if session.has_signal("map_loaded") and not session.map_loaded.is_connected(_on_map_loaded):
		session.map_loaded.connect(_on_map_loaded)
	if not is_node_ready():
		_pending_build = session.def != null
		return
	if session.def != null:
		reset_camera()
		rebuild_all()


# ===========================================================================
# 重建
# ===========================================================================

func _on_def_changed(reason: String) -> void:
	match reason:
		"terrain_live":
			_dirty_terrain = true
			_dirty_helpers = true
			if int(session.tool) >= 4:
				_dirty_splat = true
		"terrain":
			_dirty_terrain = true
			_dirty_helpers = true
			_dirty_regions = true
			_dirty_splat = true
			# 地形变了，对象要重新贴地（diff 重建，只更新变换，不重建节点）
			_dirty_objects = true
		"objects":
			_dirty_objects = true
			_dirty_helpers = true
		"objects_owner":
			# 归属变了：**不重建模型**，只重画选中环（环的颜色 = 归属色）
			_dirty_helpers = true
			rebuild_selection()
		"objects_move":
			_update_preview_positions()
			_dirty_helpers = true
		"regions":
			_dirty_regions = true
			_dirty_helpers = true
		"splat":
			# 换了生态：地表色块重铺 + 地形材质换色参数跟着改（不重建网格）
			_dirty_splat = true
			if terrain != null and session != null and session.def != null:
				terrain.biome = session.def.biome
				terrain.refresh_biome_tint()
		_:
			_dirty_terrain = true
			_dirty_objects = true
			_dirty_regions = true
			_dirty_helpers = true
			_dirty_splat = true


func _on_selection_changed() -> void:
	_dirty_helpers = true
	rebuild_selection()


## 工具变了（拿起/收起/换笔刷）：只刷辅助层，不动地形数据
func _on_tool_changed() -> void:
	_update_brush_cursor()
	_dirty_helpers = true


## 重建地图前把交互状态清干净（否则新建地图会带着上一张图的半截笔画/框选）
func reset_interaction_state() -> void:
	_painting = false
	_dragging = false
	_boxing = false
	_orbiting = false
	_left_orbit = false
	_panning = false
	_region_dragging = false
	_region_start = Vector2.INF
	_poly.clear()
	_ground = Vector3.INF
	_previews.clear()
	if sel_box != null:
		sel_box.visible = false
	if brush_mi != null:
		brush_mi.mesh = null
	_clear_place_preview()


## 一局地图装载完成（新建 / 打开 / 切换）：先把交互状态清零，再整张重建。
## 之前新建地图会"闪一下就没"、残留上一张图的笔画与框选，就是缺这一步。
func _on_map_loaded() -> void:
	reset_interaction_state()
	_built_once = true
	if not is_node_ready():
		_pending_build = session != null and session.def != null
		return
	if session == null or session.def == null:
		rebuild_terrain_clear()
		return
	reset_camera()
	rebuild_all()


## 没有地图时清空画面（别让旧地形挂在视口里当幽灵）
func rebuild_terrain_clear() -> void:
	if terrain != null:
		terrain.visible = false
	_previews.clear()
	if objects_root != null:
		for c in objects_root.get_children():
			objects_root.remove_child(c)
			c.free()
	if regions_root != null:
		for c in regions_root.get_children():
			regions_root.remove_child(c)
			c.free()
	if sel_root != null:
		for c in sel_root.get_children():
			sel_root.remove_child(c)
			c.free()
	if grid_mi != null:
		grid_mi.mesh = null
	if splat_mi != null:
		splat_mi.mesh = null


## 第一次显形时统一建一遍（地形/对象/区域/网格/相机）
func _build_now() -> void:
	_built_once = true
	reset_camera()
	rebuild_all()


func rebuild_all() -> void:
	_dirty_terrain = true
	_dirty_objects = true
	_dirty_regions = true
	_dirty_helpers = true
	_dirty_splat = true
	_previews.clear()
	rebuild_terrain()
	rebuild_objects()
	rebuild_regions()
	rebuild_selection()
	rebuild_grid()
	_update_camera()


func rebuild_terrain() -> void:
	if session == null or session.def == null:
		return
	var d: MapDef = session.def
	terrain.visible = true
	# 笔刷拖动中：放粗精度换帧率（解析求值不受影响，height_at 始终精确）；
	# 松手后 end_stroke 会发 "terrain" 让这里按精细值重建一次。
	var tol: float = 0.55 if _painting else RtsTerrain.SURFACE_TOL
	# ★ 地块数据 + 生态必须和游戏侧一模一样地喂进去（关卡._build_world 也是这两行）。
	#   以前漏了 → 游戏里地形材质有泥路、编辑器里却是整片草地，同一个 .tres 看着像两张图。
	terrain.mat_cells = d.mat_cells
	terrain.mat_nodes = d.mat_nodes
	terrain.biome = d.biome
	# 营地地标：地形着色会把基地半径内的地面压暗一点（"踩实的营地"），
	# 游戏里由 关卡._build_world 从 MapData.base_points 喂进来，这里用槽位坐标对齐。
	var bases := PackedVector2Array()
	for p in d.players:
		if p != null:
			bases.append(p.start_pos)
	terrain.base_points = bases
	terrain.build(float(d.size), d.height_resolution, d.heightmap, false, tol)
	var spots: Array = d.water_spots()
	if not spots.is_empty() and bool(d.water.get("enabled", false)):
		var s: Dictionary = spots[0]
		terrain.build_water(s["center"], float(s["radius"]), float(s["level"]))
	_dirty_terrain = false
	if _dirty_splat:
		_rebuild_splat()


## 地表层覆盖网格：直接复用 MapLoader 的生成函数，和游戏里一模一样。
## 拖动中降到 4 格一色块（约 20ms/次，配合 75ms 节流不会拖慢笔刷），
## 松手立刻按 1 格精细重建 —— 手感优先，别为了拖动中的精度把笔刷卡死。
func _rebuild_splat() -> void:
	_dirty_splat = false
	if session == null or session.def == null or splat_mi == null:
		return
	var ov: MeshInstance3D = MapLoader.build_splat_overlay(session.def, 4 if _painting else 1)
	if ov == null:
		splat_mi.mesh = null
		return
	splat_mi.mesh = ov.mesh
	splat_mi.material_override = ov.material_override
	ov.free()


## 对象层增量同步：只增删差集、只刷变换。
## 为什么不做"清空重建"：放一个木桶就重建 60 个 GLB，手感直接废掉。
func rebuild_objects() -> void:
	if session == null or session.def == null:
		for c in objects_root.get_children():
			objects_root.remove_child(c)
			c.free()
		_previews.clear()
		return
	var want: Dictionary = {}
	for o in session.def.objects:
		if o != null:
			want[o.get_instance_id()] = o
	var stale: Array = []
	for key in _previews.keys():
		if not want.has(key):
			stale.append(key)
	for key in stale:
		var old: Node = _previews.get(key, null)
		if old != null and is_instance_valid(old):
			old.free()
		_previews.erase(key)
	for key in want:
		if _previews.has(key):
			continue
		var o: MapObject = want[key]
		var n: Node3D = MapPreviewFactory.build(o)
		if n == null:
			continue
		objects_root.add_child(n)
		_previews[key] = n
	_update_preview_positions()
	_dirty_objects = false


## 拖动过程中只挪节点，不重建（一帧重建 200 个 GLB = 卡成幻灯片）
func _update_preview_positions() -> void:
	if session == null or session.def == null:
		return
	for o in session.def.objects:
		if o == null:
			continue
		var n: Node3D = _previews.get(o.get_instance_id(), null)
		if n == null or not is_instance_valid(n):
			continue
		n.position = Vector3(o.position.x, session.def.height_at(o.position.x, o.position.z), o.position.z)
		n.rotation.y = o.rotation
		n.scale = Vector3.ONE * maxf(0.02, _model_scale(o) * maxf(0.05, o.scale))


func _model_scale(o: MapObject) -> float:
	var info: Dictionary = MapAssets.find(o.type_id)
	if info.is_empty():
		return 1.0
	return float(info.get("scale", 1.0))


func rebuild_selection() -> void:
	for c in sel_root.get_children():
		sel_root.remove_child(c)
		c.free()
	if session == null or session.def == null:
		return
	for o in session.selection:
		if o == null:
			continue
		var mi := MeshInstance3D.new()
		var torus := TorusMesh.new()
		var r: float = 1.2
		if int(o.category) == MapObject.Category.BUILDING:
			r = 3.4
		elif int(o.category) == MapObject.Category.RESOURCE and o.type_id == &"goldmine":
			r = 2.6
		torus.inner_radius = r
		torus.outer_radius = r + 0.18
		torus.rings = 24
		torus.ring_segments = 6
		mi.mesh = torus
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.86, 0.25)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.72, 0.15)
		mat.emission_energy_multiplier = 2.2
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(o.position.x,
			session.def.height_at(o.position.x, o.position.z) + 0.16, o.position.z)
		sel_root.add_child(mi)
		# 归属色外环：切归属时只重画这一层，所以**点了立刻变色**，不重建模型
		var ocol: Color = session.owner_color(o.owner)
		var t2 := TorusMesh.new()
		t2.inner_radius = r + 0.36
		t2.outer_radius = r + 0.62
		t2.rings = 28
		t2.ring_segments = 6
		var om := MeshInstance3D.new()
		om.mesh = t2
		var omat := StandardMaterial3D.new()
		omat.albedo_color = ocol
		omat.emission_enabled = true
		omat.emission = ocol
		omat.emission_energy_multiplier = 2.6
		omat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		om.material_override = omat
		om.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		om.position = mi.position
		sel_root.add_child(om)
		# 建筑：把占用的 1m 格整格画出来（和建造预览/寻路同一套格），
		# 一眼能看出"这栋房压住了哪几格、有没有骑格"。
		if int(o.category) == MapObject.Category.BUILDING:
			var fp: Vector2i = session.building_footprint(o.type_id)
			var d: MapDef = session.def
			var grid: MeshInstance3D = GRID.make_grid_preview_custom(o.position, fp, true,
				d.half_size(), GRID.CELL,
				func(p: Vector3) -> Vector3: return Vector3(p.x, d.height_at(p.x, p.z), p.z))
			grid.material_override = _line_material(Color(1.0, 0.86, 0.25, 0.95))
			sel_root.add_child(grid)
	# 选中的区域：再套一圈亮边
	if session.selected_region != null:
		var rg: RegionDef = session.selected_region
		var mk := MeshInstance3D.new()
		mk.mesh = _region_outline_mesh(rg, 2.0)
		mk.material_override = _line_material(Color(1.0, 0.95, 0.45))
		mk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mk.position.y = 0.02
		sel_root.add_child(mk)


func rebuild_regions() -> void:
	for c in regions_root.get_children():
		regions_root.remove_child(c)
		c.free()
	if session == null or session.def == null:
		return
	regions_root.visible = _regions_visible
	for r in session.def.regions:
		if r == null or r.points.is_empty():
			continue
		var is_spawn: bool = int(r.purpose) == RegionDef.Purpose.SPAWN
		var col: Color = _region_color_for(r)
		var fill_mi := MeshInstance3D.new()
		fill_mi.mesh = _region_fill_mesh(r, col)
		# 出生区铺得更实一点：这是"这块地是谁的"，不能像氛围区那样淡
		fill_mi.material_override = _surface_material(col.lightened(0.06) if is_spawn else col,
			0.24 if is_spawn else 0.16)
		fill_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		regions_root.add_child(fill_mi)
		var line_mi := MeshInstance3D.new()
		line_mi.mesh = _region_outline_mesh(r, 1.0)
		line_mi.material_override = _line_material(col)
		line_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		line_mi.position.y = 0.03
		regions_root.add_child(line_mi)
		# 出生区再加一圈**贴地实心色环**：远看就是"这家在这里"，一眼扫过去分得清
		if is_spawn and r.shape == RegionDef.Shape.CIRCLE and r.radius() > 0.5:
			var ring := MeshInstance3D.new()
			ring.mesh = _ring_mesh(r.center(), r.radius(), 72, 2.8)
			ring.material_override = _line_material(Color(col.r, col.g, col.b, 1.0))
			ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			regions_root.add_child(ring)
		var lbl := Label3D.new()
		if is_spawn:
			lbl.text = session.owner_display_name(r.owner) if r.owner >= 0 \
				else "%s · 出生" % r.id
		else:
			lbl.text = "%s · %s" % [r.id, r.purpose_name()]
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = false
		lbl.font_size = 64 if is_spawn else 48
		lbl.pixel_size = 0.034 if is_spawn else 0.030
		lbl.modulate = col
		lbl.outline_size = 14 if is_spawn else 12
		lbl.outline_modulate = Color(0, 0, 0, 0.92)
		lbl.position = Vector3(r.center().x, _h(r.center().x, r.center().y)
			+ (9.0 if is_spawn else 3.0), r.center().y)
		regions_root.add_child(lbl)
	_dirty_regions = false


## 区域颜色：**有归属就用那家的颜色**（出生区/进攻区都跟着玩家走），否则按用途
func _region_color_for(r: RegionDef) -> Color:
	if r.owner >= 0 and session != null and session.def != null:
		var p: PlayerSlot = session.def.player_slot(r.owner)
		if p != null:
			return Color(p.color.r, p.color.g, p.color.b).lightened(0.10)
	return _region_color(r.purpose)


## 贴地实心色环（三角形带，比 LINES 粗、比 LINES 稳）
func _ring_mesh(center: Vector2, radius: float, seg: int, thick: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y: float = 0.09
	for i in range(seg):
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var p0: Vector2 = center + d0 * (radius - thick * 0.5)
		var p1: Vector2 = center + d0 * (radius + thick * 0.5)
		var p2: Vector2 = center + d1 * (radius - thick * 0.5)
		var p3: Vector2 = center + d1 * (radius + thick * 0.5)
		var v0 := Vector3(p0.x, _h(p0.x, p0.y) + y, p0.y)
		var v1 := Vector3(p1.x, _h(p1.x, p1.y) + y, p1.y)
		var v2 := Vector3(p2.x, _h(p2.x, p2.y) + y, p2.y)
		var v3 := Vector3(p3.x, _h(p3.x, p3.y) + y, p3.y)
		_tri(st, v0, v2, v3, Color.WHITE)
		_tri(st, v0, v3, v1, Color.WHITE)
	return st.commit()


## 显示/隐藏网格线（地图边界始终显示）
func set_grid_visible(on: bool) -> void:
	_grid_visible = on
	rebuild_grid()


## 显示/隐藏区域可视化
func set_regions_visible(on: bool) -> void:
	_regions_visible = on
	if regions_root != null:
		regions_root.visible = on


func rebuild_grid() -> void:
	if session == null or session.def == null:
		grid_mi.mesh = null
		return
	var d: MapDef = session.def
	var half: float = d.half_size()
	if _grid_visible:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_LINES)
		var step: float = GRID_STEP
		var x: float = -half
		while x <= half + 0.01:
			var prev := Vector3(x, _h(x, -half) + 0.10, -half)
			var z: float = -half
			while z < half:
				var nz: float = minf(z + step, half)
				var p := Vector3(x, _h(x, nz) + 0.10, nz)
				_line(st, prev, p)
				prev = p
				z = nz
			x += step
		var z2: float = -half
		while z2 <= half + 0.01:
			var prev2 := Vector3(-half, _h(-half, z2) + 0.10, z2)
			var xx: float = -half
			while xx < half:
				var nx: float = minf(xx + step, half)
				var p2 := Vector3(nx, _h(nx, z2) + 0.10, z2)
				_line(st, prev2, p2)
				prev2 = p2
				xx = nx
			z2 += step
		grid_mi.mesh = st.commit()
		grid_mi.material_override = _line_material(Color(0.85, 0.92, 1.0, 0.16))
	else:
		grid_mi.mesh = null
	_build_border(half)
	_dirty_helpers = false


## 地图边界框（始终显示，跟网格开关无关）
func _build_border(half: float) -> void:
	var bst := SurfaceTool.new()
	bst.begin(Mesh.PRIMITIVE_LINES)
	var corners: Array[Vector2] = [
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half),
	]
	for i in range(4):
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var seg: int = 32
		var prev3 := Vector3(a.x, _h(a.x, a.y) + 0.12, a.y)
		for k in range(1, seg + 1):
			var t: float = float(k) / float(seg)
			var p3: Vector2 = a.lerp(b, t)
			var cur := Vector3(p3.x, _h(p3.x, p3.y) + 0.12, p3.y)
			_line(bst, prev3, cur)
			prev3 = cur
	var border: MeshInstance3D = null
	for c in helper_root.get_children():
		if c.name == "边界" and c is MeshInstance3D:
			border = c as MeshInstance3D
			break
	if border == null:
		border = MeshInstance3D.new()
		border.name = "边界"
		border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		helper_root.add_child(border)
	border.mesh = bst.commit()
	border.material_override = _line_material(Color(1.0, 0.85, 0.35, 0.9))


func _on_visibility_changed() -> void:
	if vp == null:
		return
	var vis: bool = is_visible_in_tree()

	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if vis else SubViewport.UPDATE_DISABLED
	if vis:
		_on_resized()
		if not _built_once and session != null and session.def != null:
			_build_now()


func _on_resized() -> void:
	if vp == null:
		return
	var w: int = maxi(2, int(size.x))
	var h: int = maxi(2, int(size.y))
	if vp.size.x != w or vp.size.y != h:
		vp.size = Vector2i(w, h)


func _h(x: float, z: float) -> float:
	if session == null or session.def == null:
		return 0.0
	return session.def.height_at(x, z)


# ===========================================================================
# 材质 / 网格小工具
# ===========================================================================

func _line_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	return m


func _surface_material(col: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	return m


func _region_color(purpose: int) -> Color:
	match purpose:
		RegionDef.Purpose.SPAWN:
			return Color(0.35, 1.0, 0.45)
		RegionDef.Purpose.ATTACK:
			return Color(1.0, 0.36, 0.30)
		RegionDef.Purpose.CAMERA:
			return Color(0.35, 0.70, 1.0)
		RegionDef.Purpose.AMBIENT:
			return Color(0.75, 0.50, 1.0)
	return Color(1, 1, 1)


func _line(st: SurfaceTool, a: Vector3, b: Vector3) -> void:
	st.set_color(Color(1, 1, 1, 1))
	st.add_vertex(a)
	st.add_vertex(b)


## 区域填充面：贴地形，顶点色带一点高差抖动，读起来有体积
func _region_fill_mesh(r: RegionDef, col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: PackedVector2Array = _region_polygon(r)
	if pts.size() < 3:
		return st.commit()
	var center := Vector2.ZERO
	for p in pts:
		center += p
	center /= float(pts.size())
	var cy: float = _h(center.x, center.y) + 0.05
	for i in range(pts.size()):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		var v0 := Vector3(center.x, cy, center.y)
		var v1 := Vector3(a.x, _h(a.x, a.y) + 0.05, a.y)
		var v2 := Vector3(b.x, _h(b.x, b.y) + 0.05, b.y)
		_tri(st, v0, v1, v2, col)
	return st.commit()


func _region_outline_mesh(r: RegionDef, width_scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var pts: PackedVector2Array = _region_polygon(r)
	if pts.size() < 2:
		return st.commit()
	var last := Vector3(pts[0].x, _h(pts[0].x, pts[0].y) + 0.08, pts[0].y)
	for i in range(1, pts.size() + 1):
		var p: Vector2 = pts[i % pts.size()]
		var cur := Vector3(p.x, _h(p.x, p.y) + 0.08, p.y)
		_line(st, last, cur)
		# 描边加粗：同一条线错开一点点再画一次（线宽在 3D 里不通用，这样最稳）
		if width_scale > 1.0:
			var off := Vector3(0.0, 0.05, 0.0)
			_line(st, last + off, cur + off)
		last = cur
	return st.commit()


## 区域 → 多边形顶点序列（矩形/圆都展开成多边形，绘制统一走一条路）
func _region_polygon(r: RegionDef) -> PackedVector2Array:
	var out := PackedVector2Array()
	match r.shape:
		RegionDef.Shape.CIRCLE:
			if r.points.size() < 2:
				return out
			var c: Vector2 = r.points[0]
			var rad: float = maxf(0.5, r.radius())
			var seg: int = 48
			for i in range(seg):
				var a: float = TAU * float(i) / float(seg)
				out.append(c + Vector2(cos(a), sin(a)) * rad)
		RegionDef.Shape.RECT:
			if r.points.size() < 2:
				return out
			var lo: Vector2 = Vector2(minf(r.points[0].x, r.points[1].x), minf(r.points[0].y, r.points[1].y))
			var hi: Vector2 = Vector2(maxf(r.points[0].x, r.points[1].x), maxf(r.points[0].y, r.points[1].y))
			out.append(lo)
			out.append(Vector2(hi.x, lo.y))
			out.append(hi)
			out.append(Vector2(lo.x, hi.y))
		_:
			out = r.points.duplicate()
	return out


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 0.0000001:
		return
	n = n.normalized()
	if n.y < 0.0:
		n = -n
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_color(col)
		st.add_vertex(v)


# ===========================================================================
# 每帧
# ===========================================================================

func _process(delta: float) -> void:
	if session == null or session.def == null:
		return
	if not is_visible_in_tree():
		return
	# 兜底：不管页签是"切过来"还是"本来就可见"，第一次看见就建
	if not _built_once:
		_build_now()
	_clock += delta
	var interval: float = 0.075 if _painting else 0.2
	if _clock >= interval:
		_clock = 0.0
		if _dirty_terrain:
			rebuild_terrain()
			_dirty_grid()
		if _dirty_objects:
			rebuild_objects()
			rebuild_selection()
		if _dirty_regions:
			rebuild_regions()
	if _dirty_helpers and not _painting:
		rebuild_grid()
	_handle_camera_keys(delta)
	_update_camera()
	_update_brush_cursor()
	_update_place_preview()


## WASD 平移 / QE 旋转 / 1-2 缩放（只有 3D 面板拿到焦点时才吃键）
func _handle_camera_keys(delta: float) -> void:
	if not has_focus():
		return
	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move += fwd
	if Input.is_key_pressed(KEY_S):
		move -= fwd
	if Input.is_key_pressed(KEY_D):
		move += right
	if Input.is_key_pressed(KEY_A):
		move -= right
	if move.length_squared() > 0.0001:
		_target += move.normalized() * delta * maxf(18.0, _dist * 0.85)
		_clamp_target()
	if Input.is_key_pressed(KEY_Q):
		_yaw += delta * 1.6
	if Input.is_key_pressed(KEY_E):
		_yaw -= delta * 1.6


func _dirty_grid() -> void:
	_dirty_helpers = true


func _update_camera() -> void:
	if cam == null:
		return
	# _pitch 是"向下看的俯角"（负数），所以相机高度要用 -sin(_pitch)
	var cp := Vector3(cos(_pitch) * sin(_yaw), -sin(_pitch), cos(_pitch) * cos(_yaw)) * _dist
	cam.global_position = _target + cp
	cam.look_at(_target, Vector3.UP)


func _update_brush_cursor() -> void:
	if _ground == Vector3.INF or session == null or session.def == null:
		brush_mi.mesh = null
		return
	# 手型状态下不画任何工具光标：一眼就知道"现在是看地图，不是刷地图"
	if not session.armed:
		if brush_mi.mesh != null:
			brush_mi.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var col := Color(1.0, 0.95, 0.4, 0.9)
	match int(session.mode):
		MODE_TERRAIN:
			_circle_lines(st, Vector2(_ground.x, _ground.z), session.brush_radius, 40)
			if session.brush_square:
				var r: float = session.brush_radius
				var corners: Array[Vector2] = [
					Vector2(_ground.x - r, _ground.z - r), Vector2(_ground.x + r, _ground.z - r),
					Vector2(_ground.x + r, _ground.z + r), Vector2(_ground.x - r, _ground.z + r),
				]
				for i in range(4):
					_line_ground(st, corners[i], corners[(i + 1) % 4])
			col = Color(1.0, 0.95, 0.4, 0.9)
		MODE_OBJECT:
			# 建筑放置时由"体块 + 1m 占格线框"负责预览，不再叠一个没吸格的小圆圈
			if int(session.asset_category) == MapObject.Category.BUILDING:
				brush_mi.mesh = null
				return
			_circle_lines(st, Vector2(_ground.x, _ground.z), 1.2, 16)
			col = Color(0.45, 1.0, 0.55, 0.9)
		MODE_REGION:
			_circle_lines(st, Vector2(_ground.x, _ground.z), maxf(2.0, session.brush_radius), 32)
			col = Color(1.0, 0.7, 0.35, 0.9)
		_:
			_circle_lines(st, Vector2(_ground.x, _ground.z), 1.0, 12)
			col = Color(0.9, 0.95, 1.0, 0.8)
	# 多边形正在画：把已点的点连起来
	if not _poly.is_empty():
		var prev := Vector3(_poly[0].x, _h(_poly[0].x, _poly[0].y) + 0.2, _poly[0].y)
		for i in range(1, _poly.size()):
			var p := Vector3(_poly[i].x, _h(_poly[i].x, _poly[i].y) + 0.2, _poly[i].y)
			_line(st, prev, p)
			prev = p
		_line(st, prev, Vector3(_ground.x, _ground.y + 0.2, _ground.z))
	brush_mi.mesh = st.commit()
	brush_mi.material_override = _line_material(col)


func _circle_lines(st: SurfaceTool, center: Vector2, radius: float, seg: int) -> void:
	var prev := Vector2(center.x + radius, center.y)
	for i in range(1, seg + 1):
		var a: float = TAU * float(i) / float(seg)
		var cur := center + Vector2(cos(a), sin(a)) * radius
		_line_ground(st, prev, cur)
		prev = cur


func _line_ground(st: SurfaceTool, a: Vector2, b: Vector2) -> void:
	st.set_color(Color(1, 1, 1, 1))
	st.add_vertex(Vector3(a.x, _h(a.x, a.y) + 0.18, a.y))
	st.add_vertex(Vector3(b.x, _h(b.x, b.y) + 0.18, b.y))


# ===========================================================================
# 建筑放置预览
# ===========================================================================

## 按住/拿起「建筑」笔时，鼠标位置 = 严格网格锚点。画出：
##   ① 半透明体块（朝向 90° 档，跟着 R 转）
##   ② 占用的 1m 格线框（绿 = 可放 / 红 = 越界/压水/压坡/压建筑）
## 预览只读，不写数据；点击才真正 add_object()。
func _update_place_preview() -> void:
	if _place_ghost == null or session == null or session.def == null:
		return
	var show: bool = bool(session.armed) and int(session.mode) == MODE_OBJECT \
		and int(session.asset_category) == MapObject.Category.BUILDING
	if not show or _ground == Vector3.INF:
		_clear_place_preview()
		return
	var d: UnitDef = MapLoader.type_def(session.asset_id)
	if d == null:
		_clear_place_preview()
		return
	var fp := Vector2i(maxi(d.footprint.x, 1), maxi(d.footprint.y, 1))
	var pos: Vector3 = session.snap_building_pos(_ground, fp)
	var ok: bool = bool(session.can_place_building_editor(pos, fp))
	# 幽灵盒：尺寸只在建筑类型变化时重建
	var gkey: String = "%s:%d:%d:%.2f" % [String(session.asset_id), fp.x, fp.y, d.height]
	if String(_place_ghost.get_meta("box_key", "")) != gkey:
		_place_ghost.set_meta("box_key", gkey)
		var bm := BoxMesh.new()
		bm.size = Vector3(float(fp.x) * 0.92, maxf(d.height, 0.5) * 0.55, float(fp.y) * 0.92)
		_place_ghost.mesh = bm
	_place_ghost.visible = true
	_place_ghost.global_position = pos + Vector3.UP * (maxf(d.height, 0.5) * 0.275)
	_place_ghost.rotation.y = float(session.place_yaw)
	if _place_mat != null:
		_place_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.30) if ok \
			else Color(1.0, 0.36, 0.30, 0.34)
	# 占格线框：落点/尺寸/合法性变化才重建
	var key: String = "%d,%d,%d,%d,%s" % [roundi(pos.x * 100.0), roundi(pos.z * 100.0),
		fp.x, fp.y, str(ok)]
	if key == _place_key and _place_grid != null and is_instance_valid(_place_grid):
		return
	_place_key = key
	if _place_grid != null and is_instance_valid(_place_grid):
		_place_grid.queue_free()
	var dm: MapDef = session.def
	_place_grid = GRID.make_grid_preview_custom(pos, fp, ok, dm.half_size(), GRID.CELL,
		func(p: Vector3) -> Vector3: return Vector3(p.x, dm.height_at(p.x, p.z), p.z))
	vp.add_child(_place_grid)


func _clear_place_preview() -> void:
	if _place_ghost != null:
		_place_ghost.visible = false
	if _place_grid != null and is_instance_valid(_place_grid):
		_place_grid.queue_free()
	_place_grid = null
	_place_key = ""


# ===========================================================================
# 输入
# ===========================================================================

func _gui_input(event: InputEvent) -> void:
	if session == null or session.def == null:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_handle_key(event as InputEventKey)


func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				_dist = clampf(_dist * 0.88, 12.0, 520.0)
				accept_event()
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_dist = clampf(_dist * 1.14, 12.0, 520.0)
				accept_event()
		MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				grab_focus()
				_orbiting = not Input.is_key_pressed(KEY_SHIFT)
				_panning = Input.is_key_pressed(KEY_SHIFT)
			else:
				_orbiting = false
				_panning = false
			accept_event()
		MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				grab_focus()
				_panning = true
				_rmb_moved = 0.0
			else:
				_panning = false
				if _rmb_moved < 4.0:
					_on_right_click()
			accept_event()
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				if Input.is_key_pressed(KEY_ALT):
					# Alt+左键 = 转视角（和 MMB 一样，笔记本没中键也能转）
					_left_orbit = true
					_orbiting = true
				else:
					_on_left_down(mb.position)
			else:
				if _left_orbit:
					# 本次左键只用来转视角，松手收尾，不落到任何工具上
					_left_orbit = false
					_orbiting = false
				elif _orbiting:
					# 中键 / Alt 还在按着，这一下不算编辑
					pass
				else:
					_on_left_up(mb.position)
			accept_event()


## 点中对象后：Dock 如果停在「地形/区域/校验/历史」，自动跳到「对象」页。
## 为什么要这样：点了半天单位以为没选上，其实选上了、但面板停在别的页，
## 归属卡和属性都看不见，用户只会得出"选不中"的结论。
func _reveal_object_dock() -> void:
	if session == null or session.dock == null:
		return
	var dock = session.dock
	if not dock.has_method("show_tab") or not dock.has_method("get_tab_title"):
		return
	var cur: String = String(dock.get_tab_title(dock.current_tab))
	if cur == "对象" or cur == "属性":
		return
	dock.show_tab("对象")


func _on_left_down(pos: Vector2) -> void:
	var g: Vector3 = _ray_ground(pos)
	_ground = g
	# ---------------------------------------------------------------
	# 状态 1：手型（没拿工具）—— 左键按下拖动 = 转视角
	#   · 点中对象仍要能选中（这是浏览时的基本操作，不能因为没拿工具就废掉）
	#   · 点空地 → 进轨道旋转，松手不触发任何编辑
	# ---------------------------------------------------------------
	if not session.armed:
		if g != Vector3.INF:
			var hover: MapObject = _pick(pos)
			if hover != null:
				if Input.is_key_pressed(KEY_SHIFT):
					if not session.selection.has(hover):
						session.selection.append(hover)
						session.selection_changed.emit()
				else:
					session.select_only(hover)
				_reveal_object_dock()
				_dragging = true
				_drag_last = g
				session.begin_drag()
				return
		_left_orbit = true
		_orbiting = true
		return
	# ---------------------------------------------------------------
	# 状态 2：手持工具 —— 左键按下才按当前 mode 干活
	# ---------------------------------------------------------------
	if g == Vector3.INF:
		return
	match int(session.mode):
		MODE_TERRAIN:
			_painting = true
			session.begin_stroke(g)
			session.stroke_to(g, 0.06)
		MODE_OBJECT, MODE_SELECT:
			var hit: MapObject = _pick(pos)
			if hit != null:
				if Input.is_key_pressed(KEY_SHIFT):
					if not session.selection.has(hit):
						session.selection.append(hit)
						session.selection_changed.emit()
				else:
					session.select_only(hit)
				_reveal_object_dock()
				_dragging = true
				_drag_last = g
				session.begin_drag()
			else:
				if session.mode == MODE_OBJECT and session.asset_id != &"":
					session.add_object(session.asset_id, session.asset_category, g)
					_dirty_helpers = true
				else:
					session.clear_selection()
					_boxing = true
					_box_start = pos
					_set_box(pos, pos, true)
		MODE_REGION:
			if session.region_shape == RegionDef.Shape.POLYGON:
				_poly.append(Vector2(g.x, g.z))
			else:
				_region_start = Vector2(g.x, g.z)
				_region_dragging = true


func _on_left_up(pos: Vector2) -> void:
	if _painting:
		_painting = false
		session.end_stroke()
		_dirty_helpers = true
	if _dragging:
		_dragging = false
		session.end_drag()
	if _boxing:
		_boxing = false
		_set_box(pos, pos, false)
		_finish_box_select(pos)
	if _region_dragging:
		_region_dragging = false
		var g: Vector3 = _ray_ground(pos)
		if g != Vector3.INF and _region_start != Vector2.INF:
			var a: Vector2 = _region_start
			var b := Vector2(g.x, g.z)
			if a.distance_to(b) > 1.0:
				if session.region_shape == RegionDef.Shape.CIRCLE:
					session.add_region(RegionDef.Shape.CIRCLE,
						PackedVector2Array([a, a + Vector2(a.distance_to(b), 0.0)]),
						session.region_purpose)
				else:
					var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
					var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
					session.add_region(RegionDef.Shape.RECT,
						PackedVector2Array([lo, hi]), session.region_purpose)
		_region_start = Vector2.INF


func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	if _orbiting:
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.005, deg_to_rad(-88.0), deg_to_rad(-10.0))
		accept_event()
		return
	if _panning:
		_rmb_moved += mm.relative.length()
		var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
		var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var scale: float = 0.0016 * _dist
		_target -= right * mm.relative.x * scale
		_target -= fwd * -mm.relative.y * scale
		_clamp_target()
		accept_event()
		return
	if _painting:
		var g: Vector3 = _ray_ground(mm.position)
		if g != Vector3.INF:
			_ground = g
			session.stroke_to(g, get_process_delta_time())
			emit_signal("ground_changed", g, true)
		accept_event()
		return
	if _dragging:
		var g: Vector3 = _ray_ground(mm.position)
		if g != Vector3.INF:
			_drag_selection(g)
			emit_signal("ground_changed", g, true)
		accept_event()
		return
	if _boxing:
		_set_box(_box_start, mm.position, true)
		accept_event()
		return
	# 悬停：更新光标
	var gh: Vector3 = _ray_ground(mm.position)
	_ground = gh
	if gh == Vector3.INF:
		emit_signal("ground_changed", Vector3.ZERO, false)
	else:
		emit_signal("ground_changed", gh, true)


func _handle_key(k: InputEventKey) -> void:
	if not k.pressed:
		return
	match k.keycode:
		KEY_F:
			if not session.selection.is_empty():
				var o: MapObject = session.selection[0]
				_target = Vector3(o.position.x, o.position.y, o.position.z)
		KEY_DELETE:
			session.delete_selection()
			accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_finish_polygon()
			accept_event()
		KEY_ESCAPE:
			_poly.clear()
			_region_start = Vector2.INF
			_region_dragging = false
			_boxing = false
			_set_box(Vector2.ZERO, Vector2.ZERO, false)
			session.clear_selection()
			# Esc 也收起工具：一按就从"刷地形"回到"手型看地图"
			session.disarm()
			accept_event()
		KEY_H:
			# H = 手型（收起工具），跟 PS/Blender 一套习惯
			session.disarm()
			accept_event()
		KEY_R:
			# 放置建筑时旋转 90°（Shift+R 反向）。和游戏内建造共用 snap_yaw。
			if session.armed and int(session.mode) == MODE_OBJECT \
					and int(session.asset_category) == MapObject.Category.BUILDING:
				session.rotate_place_yaw(-90.0 if Input.is_key_pressed(KEY_SHIFT) else 90.0)
				_place_key = ""
				_update_place_preview()
				accept_event()
		KEY_1:
			_dist = clampf(_dist * 0.9, 12.0, 520.0)
		KEY_2:
			_dist = clampf(_dist * 1.1, 12.0, 520.0)


func _on_right_click() -> void:
	if session == null:
		return
	if not _poly.is_empty():
		_finish_polygon()
		return
	session.clear_selection()
	_poly.clear()
	# 右键空地 = 收起工具，回到手型（魔兽里就是"取消当前动作"的直觉）
	if session.armed:
		session.disarm()


func _finish_polygon() -> void:
	if _poly.size() >= 3:
		session.add_region(RegionDef.Shape.POLYGON, _poly.duplicate(), session.region_purpose)
	_poly.clear()


## 拖拽移动：多选时整组平移，贴地不穿模
func _drag_selection(g: Vector3) -> void:
	var delta: Vector3 = g - _drag_last
	if delta.length_squared() < 0.000001:
		return
	if session.snap_grid:
		delta.x = roundf(delta.x * 2.0) * 0.5
		delta.z = roundf(delta.z * 2.0) * 0.5
	for o in session.selection:
		if o == null:
			continue
		var np: Vector3 = o.position + delta
		if int(o.category) == MapObject.Category.BUILDING:
			# 建筑无论"网格吸附"开关如何都必须压 1m 寻路格
			np = session.snap_building_pos(np, session.building_footprint(o.type_id))
		else:
			if session.snap_grid:
				np.x = roundf(np.x)
				np.z = roundf(np.z)
			np.y = session.def.height_at(np.x, np.z)
		o.position = np
	_drag_last = g
	session.def_changed.emit("objects_move")


func _set_box(a: Vector2, b: Vector2, on: bool) -> void:
	if sel_box == null:
		return
	sel_box.visible = on
	if not on:
		return
	var r := Rect2(a, Vector2.ZERO).expand(b)
	sel_box.position = r.position
	sel_box.size = r.size


func _finish_box_select(pos: Vector2) -> void:
	var r := Rect2(_box_start, Vector2.ZERO).expand(pos)
	if r.size.x < 3.0 and r.size.y < 3.0:
		return
	var picked: Array[MapObject] = []
	for o in session.def.objects:
		if o == null:
			continue
		var wp := Vector3(o.position.x, session.def.height_at(o.position.x, o.position.z) + 0.8, o.position.z)
		if cam.is_position_behind(wp):
			continue
		var sp: Vector2 = cam.unproject_position(wp)
		if r.has_point(sp):
			picked.append(o)
	session.selection = picked
	session.selected_region = null
	session.selection_changed.emit()
	if not picked.is_empty():
		emit_signal("ground_changed", picked[0].position, true)


# ===========================================================================
# 拾取 / 射线
# ===========================================================================

## 屏幕点附近的对象（屏幕距离最小者；26px 内才算点到）
func _pick(pos: Vector2) -> MapObject:
	var best: MapObject = null
	var best_d: float = PICK_PIXELS
	for o in session.def.objects:
		if o == null:
			continue
		# 拾取点抬到模型"腰/胸"高度：按真实高度算，别用常数 ——
		# 农民 1.6m 和兵营 7m 用同一个 lift 时，点单位头部就会偏出吸附圈，
		# 表现就是"单位怎么点都选不中"。
		var lift: float = 1.0
		match int(o.category):
			MapObject.Category.BUILDING:
				lift = 3.0
			MapObject.Category.RESOURCE:
				lift = 1.4
			MapObject.Category.UNIT:
				var ud: UnitDef = MapLoader.type_def(o.type_id)
				lift = maxf(0.9, (ud.height if ud != null else 1.7) * 0.55)
		var wp := Vector3(o.position.x, session.def.height_at(o.position.x, o.position.z) + lift, o.position.z)
		if cam.is_position_behind(wp):
			continue
		var sp: Vector2 = cam.unproject_position(wp)
		var d: float = sp.distance_to(pos)
		if d < best_d:
			best_d = d
			best = o
	return best


## 屏幕坐标 → 地面点（步进 + 二分细化；不依赖物理引擎，编辑器里也不建碰撞体）
func _ray_ground(screen_pos: Vector2) -> Vector3:
	if cam == null or session == null or session.def == null:
		return Vector3.INF
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var dir: Vector3 = cam.project_ray_normal(screen_pos)
	var t: float = 0.0
	var max_t: float = _dist * 6.0 + 400.0
	var step: float = maxf(0.4, _dist * 0.006)
	var prev_t: float = 0.0
	while t < max_t:
		t += step
		step *= 1.035
		var p: Vector3 = from + dir * t
		var h: float = _h(p.x, p.z)
		if p.y <= h:
			var a: float = prev_t
			var b: float = t
			for i in range(12):
				var m: float = (a + b) * 0.5
				var pm: Vector3 = from + dir * m
				if pm.y <= _h(pm.x, pm.z):
					b = m
				else:
					a = m
			var hit: Vector3 = from + dir * b
			var gp := Vector3(hit.x, _h(hit.x, hit.z), hit.z)
			if not session.def.in_bounds(Vector2(gp.x, gp.z), 0.0):
				return Vector3.INF
			return gp
		prev_t = t
		if p.y < -120.0:
			break
	return Vector3.INF


# ===========================================================================
# 相机
# ===========================================================================

func reset_camera() -> void:
	if session == null or session.def == null:
		return
	_target = Vector3.ZERO
	_target.y = session.def.height_at(0.0, 0.0)
	_dist = float(session.def.size) * 0.95
	_yaw = deg_to_rad(32.0)
	_pitch = deg_to_rad(-54.0)
	_update_camera()


func set_view_top() -> void:
	_pitch = deg_to_rad(-88.0)
	_yaw = 0.0
	_update_camera()


func set_view_iso() -> void:
	_pitch = deg_to_rad(-50.0)
	_yaw = deg_to_rad(35.0)
	_update_camera()


func focus_on(world_pos: Vector3) -> void:
	_target = world_pos
	_clamp_target()
	_update_camera()


func zoom_by(factor: float) -> void:
	_dist = clampf(_dist * factor, 12.0, 520.0)
	_update_camera()


func _clamp_target() -> void:
	if session == null or session.def == null:
		return
	var b: Rect2 = session.def.camera_bounds
	if b.size.x > 0.0 and b.size.y > 0.0:
		_target.x = clampf(_target.x, b.position.x, b.position.x + b.size.x)
		_target.z = clampf(_target.z, b.position.y, b.position.y + b.size.y)
	_target.y = _h(_target.x, _target.z)


## 当前鼠标地面点（dock 的坐标/高度显示用）
func mouse_ground() -> Vector3:
	return _ground