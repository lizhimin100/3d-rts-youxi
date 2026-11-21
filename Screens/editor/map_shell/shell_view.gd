@tool
extends Node3D
## 3D 地图底壳编辑器 · 世界与编辑核心
## 属于：Screens/editor/map_shell（开发工具，不进发行版）
##
## 四件事：
##   1 地形与地表笔刷（起伏雕刻 / 地表材质涂抹 / 环境光 / 水面高度）
##   2 纯视觉装饰（**只实例化 asset_manifest 里已登记的现有场景/GLB**，不现拼占位网格）
##   3 弯曲行军脊线（通道宽度与走向；赛道圆环式分区已下线）
##   4 战术地形格子（TacticalTile：建筑位 = 左上角、出兵位 = 正中心）
##
## 另外两块编辑器交互：
##   · 点选 / 拖框多选 / 脚下的 3D 选中高亮圈（复用 Content/art/特效/选中圈.tscn）
##   · 势力区域多边形绘制（玩家 / 中立 / 敌方），判定与校验在 Model（C#）
##
## 数据：直接读写 shell_store 的结构；写盘由外层 map_shell_editor.gd 调 dev_data。

signal brushed()
signal picked(kind: String, index: int)
signal changed()
signal region_changed(kind: String)
## 框选矩形变化（编辑器拿去画 2D 覆盖层；坐标是视口局部坐标）
signal box_changed(from: Vector2, to: Vector2)
signal box_cleared()
## 区域绘制结算（errors 空 = 成功）
signal region_finished(errors: Array)
signal region_cancelled()

const ShellStore := preload("res://Screens/editor/shell_store.gd")
const ShellText := preload("res://Screens/editor/map_shell/shell_text.gd")
## 树 / 岩石 / 草 / 碎石 / 金矿 / 水面：走装饰库的既有场景（场景里写着阴影与可见距离）
## 选中圈：编辑器与局内**同一个**资产（不给编辑器单独做一套圈）
##
## 两条路径都含中文目录：用 \u 转义拼出来 + 运行时 load（preload 的字面量会被
## "硬路径体检"当成人手写死的 res:// 路径，而源码里写中文又会撞 i18n 预算）。
const DECOR_LIB_PATH := "res://Screens/world/art/" + "\u88c5\u9970\u5e93.gd"
const SEL_RING_PATH := "res://Content/art/" + "\u7279\u6548/\u9009\u4e2d\u5708.tscn"
var _decor_lib: Script = null
var _sel_ring: PackedScene = null

const TOOL_TERRAIN := "terrain"
const TOOL_DECOR := "decor"
const TOOL_SPINE := "spine"
const TOOL_TILE := "tile"

const REGION_FILL_ALPHA := 0.18
const REGION_LINE_ALPHA := 0.95
const REGION_Y_LIFT := 0.07

# ── 和旧地图编辑器（addons/map_editor/视口.gd）同一套镜头口径 ──────────────
## 俯角 = 游戏内魔兽镜头 camera_pitch_deg（50°）；FOV 与 魔兽镜头.gd 一致（52）。
const CAM_PITCH_DEG := 50.0
const CAM_FOV := 52.0
## 缩放范围：上限不是「能拉多远」，而是「拉远之后还看得见地图」。
const CAM_DIST_MIN := 12.0
const CAM_DIST_MAX := 200.0
## 默认距离：224m 图上大约看半张图；底壳更小，先保持同一手感再靠滚轮调。
const CAM_DIST_DEFAULT := 90.0
## Ctrl+Shift+C 跳到玩家区（主堡格子）时的距离 = 游戏默认镜头距离。
const CAM_DIST_PLAY := 32.0
## 镜头能到地图边界外多少米（= Cfg.game.camera_bounds_margin）
const CAM_BOUNDS_MARGIN := 4.0
## 界外底板：尺寸 / 高度 / 颜色（地图外看到的深色，不是天空）
const VOID_PLANE_SIZE := 4000.0
const VOID_PLANE_Y := -14.0
const VOID_COLOR := Color(0.030, 0.034, 0.042)
## 距离雾（把远处压黑，进一步藏掉地图边界）
const CAM_FOG_DENSITY := 0.0032
## 网格叠加线间距（米）
const GRID_STEP := 4.0
const GRID_COLOR := Color(0.85, 0.92, 1.0, 0.16)
const BORDER_COLOR := Color(1.0, 0.85, 0.35, 0.9)

# ── 地形：**和游戏里同一份材质与贴图**（唯一真源 RtsTerrain / 地形.gdshader）──
## 路径全部转发 RtsTerrain / ArtKit 的常量 —— 编辑器不写第二份资源路径。
const TERRAIN_MAT := RtsTerrain.MATERIAL_PATH
const WATER_MAT := RtsTerrain.WATER_MATERIAL_PATH
const RIPPLE_NORMAL := RtsTerrain.RIPPLE_NORMAL_PATH
const BATTLE_ENV := ArtKit.PATH_ENV
const ATLAS_PATH := RtsTerrain.ATLAS_PATH
const ATLAS_N_PATH := RtsTerrain.ATLAS_N_PATH
const TEX_GRASS_PATH := RtsTerrain.TEX_GRASS_PATH
const TEX_DIRT_PATH := RtsTerrain.TEX_DIRT_PATH
const TEX_CRACKED_PATH := RtsTerrain.TEX_CRACKED_PATH
const ROCK_DETAIL_PATH := RtsTerrain.ROCK_DETAIL_PATH
## 一格多少米（**必须与底材平铺距离一致**；真值在 RtsTerrain.TILE_M）
const TILE_M := RtsTerrain.TILE_M
## 底壳没有生态字段，按温带取色（与 MapDef.biome_tint 的默认档一致）。
const SHELL_BIOME := "temperate"

var shell: Dictionary = {}
var tool := TOOL_TERRAIN

var heights := PackedFloat32Array()
var surface: Array = []
var preview_layout: Dictionary = {}

# 笔刷
var brush_radius := 6.0
var brush_strength := 0.6
var brush_mode := "raise"
var surface_layer := 1
var decor_kind := "tree"

# 选择（多选：框选 / Shift 点选）
var selected_tiles: Array[int] = []
var selected_decor: Array[int] = []
var selected_point := -1
var hovered_tile := -1
var hovered_decor := -1

# 区域绘制（空字符串 = 不在绘制）
var region_mode := ""
var region_draft := PackedVector2Array()

# 撤销栈（整份 shell 快照，最多 UNDO_MAX 步）
const UNDO_MAX := 24
var _undo: Array = []

# 拖拽（撤销快照只在**真的移动过**时才入栈：单击选中不该占一步撤销）
var _dragging := false
var _drag_start := Vector3.ZERO
var _drag_offsets: Array = []
var _drag_snapshot: Dictionary = {}
var _drag_moved := false

# 框选
var _left_down := false
var _pending_add := false
var _box_active := false
var _box_start := Vector2.ZERO
var _box_end := Vector2.ZERO

# 相机（语义与旧编辑器一致：cam_pitch 为负 = 向下看）
var cam_target := Vector3.ZERO
var cam_yaw := 32.0
var cam_pitch := -CAM_PITCH_DEG
var cam_dist := CAM_DIST_DEFAULT
## 视口是否持有键盘焦点（由主屏每帧同步；和旧编辑器 has_focus() 同一作用）
var keys_focus := false

# 节点
var camera: Camera3D = null
var sun: DirectionalLight3D = null
var fill: DirectionalLight3D = null
var world_env: WorldEnvironment = null
var terrain_mesh: MeshInstance3D = null
var water_mesh: MeshInstance3D = null
var grid_mesh: MeshInstance3D = null
var border_mesh: MeshInstance3D = null
var decal_mesh: MeshInstance3D = null
var ribbon_mesh: MeshInstance3D = null
var regions_root: Node3D = null
var region_draft_root: Node3D = null
var tiles_root: Node3D = null
var tile_markers_root: Node3D = null
var decor_root: Node3D = null
var selection_root: Node3D = null

var _terrain_mat: ShaderMaterial = null
var _water_mat: Material = null
var _void_plane: MeshInstance3D = null
var _hmin := 0.0
var _hmax := 0.0
var _decor_scene_cache: Dictionary = {}

var _painting := false
var _paint_ground := Vector3.ZERO
var _paint_height := 0.0
var _paint_accum := 0.0
var _grid_accum := 0.0
var _hover_ground := Vector3.ZERO
var _hover_valid := false

# 交互状态（沿用旧编辑器：中键/Alt+左键旋转、右键/Shift+中键平移）
var _orbiting := false
var _left_orbit := false
var _panning := false
var _rmb_moved := 0.0


# ===========================================================================
# 场景装配
# ===========================================================================
func build_world() -> void:
	if camera != null:
		return
	world_env = WorldEnvironment.new()
	world_env.name = "Env"
	world_env.environment = _masked_environment()
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	# 与 主场景.tscn 的主光同一套：暖色、2.35 能量、阴影 bias 0.085 / normal 1.85
	sun.rotation_degrees = Vector3(-48.0, -66.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.83)
	sun.light_energy = 2.35
	sun.shadow_enabled = true
	sun.shadow_bias = 0.085
	sun.shadow_normal_bias = 1.85
	sun.directional_shadow_max_distance = 160.0
	add_child(sun)

	fill = DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-22.0, 118.0, 0.0)
	fill.light_color = Color(0.46, 0.61, 0.95)
	fill.light_energy = 0.30
	add_child(fill)

	camera = Camera3D.new()
	camera.name = "Camera"
	# 透视 + 与游玩一致的 FOV/俯角（编辑器相机要和真玩起来一个视角）
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = CAM_FOV
	camera.near = 0.1
	camera.far = 1200.0
	add_child(camera)

	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "Terrain"
	add_child(terrain_mesh)
	water_mesh = MeshInstance3D.new()
	water_mesh.name = "Water"
	add_child(water_mesh)
	decal_mesh = MeshInstance3D.new()
	decal_mesh.name = "SurfaceDecals"
	decal_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(decal_mesh)
	grid_mesh = MeshInstance3D.new()
	grid_mesh.name = "Grid"
	add_child(grid_mesh)
	border_mesh = MeshInstance3D.new()
	border_mesh.name = "Border"
	border_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(border_mesh)
	ribbon_mesh = MeshInstance3D.new()
	ribbon_mesh.name = "Ribbon"
	add_child(ribbon_mesh)
	regions_root = Node3D.new()
	regions_root.name = "Regions"
	add_child(regions_root)
	region_draft_root = Node3D.new()
	region_draft_root.name = "RegionDraft"
	add_child(region_draft_root)
	tiles_root = Node3D.new()
	tiles_root.name = "Tiles"
	add_child(tiles_root)
	tile_markers_root = Node3D.new()
	tile_markers_root.name = "TileMarkers"
	add_child(tile_markers_root)
	decor_root = Node3D.new()
	decor_root.name = "Decor"
	add_child(decor_root)
	selection_root = Node3D.new()
	selection_root.name = "Selection"
	add_child(selection_root)

	# 地图外的「黑色底板」：镜头看向边界外时看到的是这块板，不是天球。
	_void_plane = MeshInstance3D.new()
	_void_plane.name = "Void"
	var pm := PlaneMesh.new()
	pm.size = Vector2(VOID_PLANE_SIZE, VOID_PLANE_SIZE)
	_void_plane.mesh = pm
	var vmat := StandardMaterial3D.new()
	vmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	vmat.albedo_color = VOID_COLOR
	vmat.disable_receive_shadows = true
	_void_plane.material_override = vmat
	_void_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_void_plane.position = Vector3(0.0, VOID_PLANE_Y, 0.0)
	add_child(_void_plane)
	_update_camera()


## 环境沿用旧编辑器的做法：拿游戏里的 战斗环境.tres **复制一份再改**，
## 把天空换成近黑纯色 + 一层薄距离雾 —— 地图边界之外是深色，不是一片天空/虚空。
## 直接改共享资源会污染游戏里那一份，所以必须 duplicate。
func _masked_environment() -> Environment:
	var src: Environment = null
	if ResourceLoader.exists(BATTLE_ENV):
		src = load(BATTLE_ENV) as Environment
	var env: Environment = null
	if src != null:
		env = src.duplicate(true) as Environment
	if env == null:
		env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.028, 0.032, 0.040)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.47, 0.56)
	env.ambient_light_energy = 0.55
	env.fog_enabled = true
	env.fog_light_color = Color(0.035, 0.040, 0.050)
	env.fog_density = CAM_FOG_DENSITY
	return env


func load_shell(p_shell: Dictionary, keep_camera: bool = false) -> void:
	shell = p_shell
	if shell.is_empty():
		return
	# 新建 / 旧图迁移：三块区域缺了就补默认矩形（几何在 Model 里算）
	ShellStore.ensure_regions(shell)
	heights = ShellStore.heights_or_procedural(shell)
	surface = ShellStore.surface_index(shell)
	_clear_selection()
	preview_layout = {}
	rebuild_all()
	update_ambient()
	if not keep_camera:
		# 与旧编辑器一致：一张图进来先把镜头复位到「游玩视角」，而不是沿用上一张图的机位。
		reset_camera()


func rebuild_all() -> void:
	if camera == null:
		build_world()
	_build_terrain()
	_build_water()
	_build_grid()
	_build_ribbon()
	_build_regions()
	_build_tiles()
	_build_decor()
	_rebuild_selection_rings()
	_update_camera()


# ===========================================================================
# 地形 / 地表
# ===========================================================================
func _build_terrain() -> void:
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	var ox := float(g["origin_x"])
	var oz := float(g["origin_z"])
	if heights.size() != cols * rows:
		heights = ShellStore.heights_or_procedural(shell)
	_hmin = 0.0
	_hmax = 0.0
	for h in heights:
		_hmin = minf(_hmin, h)
		_hmax = maxf(_hmax, h)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(cols * rows)
	normals.resize(cols * rows)
	colors.resize(cols * rows)
	uvs.resize(cols * rows)
	# 格子压暗的落点只取一次（每顶点再去翻 tiles 字典会很贵）
	var camps: Array[Vector2] = []
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		camps.append(Vector2(float(td.get("x", 0.0)), float(td.get("z", 0.0))))
	for row in rows:
		for col in cols:
			var i := row * cols + col
			var y := heights[i]
			verts[i] = Vector3(ox + float(col) * cell, y, oz + float(row) * cell)
			var hl := heights[row * cols + maxi(col - 1, 0)]
			var hr := heights[row * cols + mini(col + 1, cols - 1)]
			var hd := heights[maxi(row - 1, 0) * cols + col]
			var hu := heights[mini(row + 1, rows - 1) * cols + col]
			var dx := (hr - hl) / (cell * 2.0)
			var dz := (hu - hd) / (cell * 2.0)
			normals[i] = Vector3(-dx, 1.0, -dz).normalized()
			# 顶点色只做「乘法染色 + 干度」，配色交给地形材质的草/泥贴图。
			# 口径与 RtsTerrain._tint_at 一致：编辑器看到的就是局内看到的那块地。
			colors[i] = _tint_at(verts[i], normals[i], camps)
			uvs[i] = Vector2(float(col) / float(maxi(cols - 1, 1)), float(row) / float(maxi(rows - 1, 1)))
	var indices := PackedInt32Array()
	indices.resize((cols - 1) * (rows - 1) * 6)
	var k := 0
	for row in rows - 1:
		for col in cols - 1:
			var a := row * cols + col
			var b := a + 1
			var c := a + cols
			var d := c + 1
			# 绕序按 Godot 顺时针正面：a→b→c / b→d→c（和 RtsTerrain._tri 的判定同一套）
			indices[k] = a
			indices[k + 1] = b
			indices[k + 2] = c
			indices[k + 3] = b
			indices[k + 4] = d
			indices[k + 5] = c
			k += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	terrain_mesh.mesh = mesh
	terrain_mesh.material_override = _terrain_material()
	_build_surface_decals()


## 地形材质 = **游戏里那一份**（Content/art/材质/地形材质.tres → 地形.gdshader）。
## 这里只把底壳自己的地块格点表 / 尺寸喂进去，不另写一套配色。
func _terrain_material() -> Material:
	if _terrain_mat == null:
		var base: Material = null
		if ResourceLoader.exists(TERRAIN_MAT):
			base = load(TERRAIN_MAT) as Material
		if base is ShaderMaterial:
			# **必须 duplicate**：地形要按底壳写 mat_map / map_half，
			# 直接改共享资源会把参数带到游戏里那一份（和 RtsTerrain 同一个理由）。
			_terrain_mat = (base as ShaderMaterial).duplicate(true) as ShaderMaterial
			_bind_terrain_textures()
	if _terrain_mat != null:
		_update_mat_map()
		return _terrain_mat
	# 兜底：材质资源被删了也别让地面消失（顶点色仍是同一套染色口径）
	var std := StandardMaterial3D.new()
	std.vertex_color_use_as_albedo = true
	std.vertex_color_is_srgb = true
	std.roughness = 0.96
	std.metallic = 0.0
	std.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return std


## 贴图/图集/岩石细节：路径与 RtsTerrain._apply_material_landmarks 完全一致。
func _bind_terrain_textures() -> void:
	if _terrain_mat == null:
		return
	var sz := ShellStore.size_of(shell)
	_terrain_mat.set_shader_parameter("tile_m", TILE_M)
	_terrain_mat.set_shader_parameter("map_half", sz.x * 0.5)
	_terrain_mat.set_shader_parameter("mat_cells", _mat_lattice_n())
	var bt: Array = MapDef.biome_tint(String(shell.get("biome", SHELL_BIOME)))
	_terrain_mat.set_shader_parameter("biome_color", bt[0])
	_terrain_mat.set_shader_parameter("biome_mix", bt[1])
	var slots := {
		"atlas_rgba": ATLAS_PATH,
		"atlas_n": ATLAS_N_PATH,
		"tex_grass": TEX_GRASS_PATH,
		"tex_dirt": TEX_DIRT_PATH,
		"tex_cracked": TEX_CRACKED_PATH,
		"rock_detail": ROCK_DETAIL_PATH,
	}
	for key in slots:
		var path: String = slots[key]
		if not ResourceLoader.exists(path):
			continue
		var t := load(path) as Texture2D
		if t != null:
			_terrain_mat.set_shader_parameter(key, t)


## 地块格点表的边长（格点数）。着色器里 map_half 是**同一个值管两轴**，
## 所以 z 方向并不是从 -map_half 开始：多留几行/列，按整数格点索引填。
func _mat_lattice_n() -> int:
	var sz := ShellStore.size_of(shell)
	return maxi(17, int(ceil(maxf(sz.x, sz.y) / TILE_M)) + 2)


## 把 surface 槽位翻译成魔兽 3 口径的 mat_map（R8，1 texel = 1 个 8m 格点）。
## 草丛=0 / 泥土=255；岩石、沙地在地块体系里没有对应材质，走覆盖层贴花（和旧编辑器一致）。
func _update_mat_map() -> void:
	if _terrain_mat == null:
		return
	var sz := ShellStore.size_of(shell)
	var n := _mat_lattice_n()
	var map_half := sz.x * 0.5
	var bytes := PackedByteArray()
	bytes.resize(n * n)
	for j in n:
		var wz := -map_half + float(j) * TILE_M
		var inside_z := wz >= (-sz.y * 0.5 - TILE_M) and wz <= (sz.y * 0.5 + TILE_M)
		for i in n:
			var wx := -map_half + float(i) * TILE_M
			var v := 0
			if inside_z and wx >= (-sz.x * 0.5 - TILE_M) and wx <= (sz.x * 0.5 + TILE_M):
				if _surface_index_at(wx, wz) == 1:
					v = 255
			bytes[j * n + i] = v
	var img := Image.create(n, n, false, Image.FORMAT_R8)
	img.set_data(n, n, false, Image.FORMAT_R8, bytes)
	_terrain_mat.set_shader_parameter("mat_map", ImageTexture.create_from_image(img))


func _surface_at(i: int) -> int:
	return int(surface[i]) if i >= 0 and i < surface.size() else 0


func _surface_index_at(wx: float, wz: float) -> int:
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	var col := clampi(int(round((wx - float(g["origin_x"])) / cell)), 0, cols - 1)
	var row := clampi(int(round((wz - float(g["origin_z"])) / cell)), 0, rows - 1)
	return _surface_at(row * cols + col)


## 顶点色 = RtsTerrain._tint_at 的同一套口径：
## rgb = 1.0 附近的乘法染色（大尺度冷暖 ±3.5% / 营地压暗 / 陡面偏灰），a = 干度。
func _tint_at(pos: Vector3, normal: Vector3, camps: Array[Vector2]) -> Color:
	var rng_h := maxf(_hmax - _hmin, 0.001)
	var alt := clampf((pos.y - _hmin) / rng_h, 0.0, 1.0)
	var up := clampf(normal.y, 0.0, 1.0)
	var warm := sin(pos.x * 0.052 + pos.z * 0.031) * 0.55 \
		+ sin(pos.z * 0.074 - pos.x * 0.021 + 1.7) * 0.45
	var k := 1.0 + warm * 0.035
	var tr := k * 1.012
	var tg := k
	var tb := k * 0.978
	var dry := smoothstep(0.30, 0.95, alt) * 0.85 + warm * 0.12
	var steep := 1.0 - up
	if steep > 0.06:
		var st := clampf((steep - 0.06) / 0.30, 0.0, 1.0)
		tr = lerpf(tr, 0.92, st * 0.7)
		tg = lerpf(tg, 0.94, st * 0.7)
		tb = lerpf(tb, 1.02, st * 0.7)
		dry *= 1.0 - st * 0.6
	var camp := 0.0
	var p2 := Vector2(pos.x, pos.z)
	for bp in camps:
		camp = maxf(camp, 1.0 - smoothstep(15.0, 34.0, p2.distance_to(bp)))
	if camp > 0.001:
		var dark := lerpf(1.0, 0.925, camp)
		tr *= dark
		tg *= dark
		tb *= dark
		dry *= lerpf(1.0, 0.45, camp)
	return Color(clampf(tr, 0.0, 1.6), clampf(tg, 0.0, 1.6), clampf(tb, 0.0, 1.6),
		clampf(dry, 0.0, 1.0))


## 岩石 / 沙地覆盖层：和旧编辑器（MapLoader.build_splat_overlay）同一个观感 ——
## 逐格贴地薄面 + 四角颜色插值。颜色取**底壳自己的材质槽位**（面板上看到的就是刷上的），
## 不另调一套色；草/泥两个槽位走真实地形贴图，不在这层里画。
func _build_surface_decals() -> void:
	if decal_mesh == null:
		return
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	var ox := float(g["origin_x"])
	var oz := float(g["origin_z"])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var painted := 0
	for row in rows - 1:
		for col in cols - 1:
			var i00 := row * cols + col
			var i10 := i00 + 1
			var i01 := i00 + cols
			var i11 := i01 + 1
			var v00 := _surface_at(i00)
			var v10 := _surface_at(i10)
			var v01 := _surface_at(i01)
			var v11 := _surface_at(i11)
			if not _is_decal_slot(v00) and not _is_decal_slot(v10) \
					and not _is_decal_slot(v01) and not _is_decal_slot(v11):
				continue
			painted += 1
			var x0 := ox + float(col) * cell
			var z0 := oz + float(row) * cell
			var a := Vector3(x0, heights[i00] + 0.22, z0)
			var b := Vector3(x0 + cell, heights[i10] + 0.22, z0)
			var cc := Vector3(x0, heights[i01] + 0.22, z0 + cell)
			var dd := Vector3(x0 + cell, heights[i11] + 0.22, z0 + cell)
			_splat_tri(st, a, b, cc, _decal_color(v00), _decal_color(v10), _decal_color(v01))
			_splat_tri(st, b, dd, cc, _decal_color(v10), _decal_color(v11), _decal_color(v01))
	if painted == 0:
		decal_mesh.mesh = null
		return
	decal_mesh.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# **UNSHADED**：地表层是"刷上去的颜色"，不是受光表面（和旧编辑器同一口径）
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.disable_receive_shadows = true
	decal_mesh.material_override = mat


func _is_decal_slot(v: int) -> bool:
	return v == 2 or v == 3


func _decal_color(v: int) -> Color:
	if v == 2 or v == 3:
		var c := ShellStore.palette_color(shell, v)
		return Color(c.r, c.g, c.b, 0.75)
	return Color(0.0, 0.0, 0.0, 0.0)


func _splat_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 0.0000001:
		return
	n = n.normalized()
	if n.y < 0.0:
		n = -n
	var pts := [a, b, c]
	var cols := [ca, cb, cc]
	for i in 3:
		st.set_normal(n)
		st.set_color(cols[i])
		st.add_vertex(pts[i])


func _build_water() -> void:
	var sz := ShellStore.size_of(shell)
	var level := float((shell.get("terrain", {}) as Dictionary).get("water_level", ShellStore.WATER_DEFAULT))
	if water_mesh.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(sz.x, sz.y)
		water_mesh.mesh = plane
	water_mesh.position = Vector3(0.0, level, 0.0)
	water_mesh.material_override = _water_material()


## 水面沿用游戏里的 水材质.tres（卡通水面 + 波纹法线），不另调一块蓝玻璃。
func _water_material() -> Material:
	if _water_mat == null and ResourceLoader.exists(WATER_MAT):
		_water_mat = load(WATER_MAT) as Material
	if _water_mat == null:
		var std := StandardMaterial3D.new()
		std.albedo_color = Color(0.16, 0.36, 0.52, 0.85)
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.roughness = 0.12
		std.metallic = 0.35
		_water_mat = std
	if _water_mat is ShaderMaterial and ResourceLoader.exists(RIPPLE_NORMAL):
		(_water_mat as ShaderMaterial).set_shader_parameter("ripple_normal", load(RIPPLE_NORMAL))
	return _water_mat


## 编辑器辅助网格：和旧编辑器一样**贴着地形走**（4m 一格 + 地图边界框）。
func _build_grid() -> void:
	if grid_mesh == null:
		return
	var sz := ShellStore.size_of(shell)
	var hx := sz.x * 0.5
	var hz := sz.y * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var x := -hx
	while x <= hx + 0.01:
		var prev := Vector3(x, _h(x, -hz) + 0.10, -hz)
		var z := -hz
		while z < hz:
			var nz := minf(z + GRID_STEP, hz)
			var p := Vector3(x, _h(x, nz) + 0.10, nz)
			_grid_line(st, prev, p)
			prev = p
			z = nz
		x += GRID_STEP
	var z2 := -hz
	while z2 <= hz + 0.01:
		var prev2 := Vector3(-hx, _h(-hx, z2) + 0.10, z2)
		var xx := -hx
		while xx < hx:
			var nx := minf(xx + GRID_STEP, hx)
			var p2 := Vector3(nx, _h(nx, z2) + 0.10, z2)
			_grid_line(st, prev2, p2)
			prev2 = p2
			xx = nx
		z2 += GRID_STEP
	grid_mesh.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid_mesh.material_override = mat
	_build_border()


func _grid_line(st: SurfaceTool, a: Vector3, b: Vector3) -> void:
	st.set_color(GRID_COLOR)
	st.add_vertex(a)
	st.set_color(GRID_COLOR)
	st.add_vertex(b)


## 地图边界框（始终显示，跟网格开关无关）
func _build_border() -> void:
	if border_mesh == null:
		return
	var sz := ShellStore.size_of(shell)
	var hx := sz.x * 0.5
	var hz := sz.y * 0.5
	var corners: Array[Vector2] = [
		Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz),
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var seg := 32
		var prev := Vector3(a.x, _h(a.x, a.y) + 0.12, a.y)
		for k in range(1, seg + 1):
			var t := float(k) / float(seg)
			var p: Vector2 = a.lerp(b, t)
			var cur := Vector3(p.x, _h(p.x, p.y) + 0.12, p.y)
			st.set_color(BORDER_COLOR)
			st.add_vertex(prev)
			st.set_color(BORDER_COLOR)
			st.add_vertex(cur)
			prev = cur
	border_mesh.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	border_mesh.material_override = mat


# ===========================================================================
# 脊线（通道本身；分区改由多边形区域负责）
# ===========================================================================
func _build_ribbon() -> void:
	var width_m := float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)) * ShellStore.R1
	var samples := ShellStore.sample_spine(shell, 96)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in samples.size():
		var s: Dictionary = samples[i]
		var t := int(round(float(i) / float(maxi(samples.size() - 1, 1)) * 999.0))
		var d := ShellStore.direction_at_t(shell, t)
		var n := Vector2(-d.y, d.x)
		var px := float(s["x"])
		var pz := float(s["z"])
		var yl := ShellStore.height_at(shell, px + n.x * width_m * 0.5, pz + n.y * width_m * 0.5) + 0.08
		var yr := ShellStore.height_at(shell, px - n.x * width_m * 0.5, pz - n.y * width_m * 0.5) + 0.08
		st.set_color(Color(0.94, 0.78, 0.42, 0.32))
		st.add_vertex(Vector3(px + n.x * width_m * 0.5, yl, pz + n.y * width_m * 0.5))
		st.set_color(Color(0.94, 0.78, 0.42, 0.32))
		st.add_vertex(Vector3(px - n.x * width_m * 0.5, yr, pz - n.y * width_m * 0.5))
	var mesh := st.commit()
	ribbon_mesh.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ribbon_mesh.material_override = mat


# ===========================================================================
# 势力区域（多边形）
# ===========================================================================
func _build_regions() -> void:
	for c in regions_root.get_children():
		c.queue_free()
	for kind in ShellStore.REGION_IDS:
		var pts := ShellStore.region_points(shell, kind)
		if pts.size() < 3:
			continue
		var col: Color = ShellStore.REGION_COLORS.get(kind, Color.WHITE)
		var holder := Node3D.new()
		holder.name = "Region_" + kind
		holder.set_meta("region_kind", kind)
		regions_root.add_child(holder)
		holder.add_child(_region_fill_mesh(pts, col))
		holder.add_child(_region_outline_mesh(pts, col, 0.14))
		var c := ShellStore.region_centroid(pts)
		var label := Label3D.new()
		label.name = "Label"
		label.text = T(ShellStore.REGION_KEYS.get(kind, kind))
		label.font_size = 64
		label.pixel_size = 0.016
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.outline_size = 12
		label.modulate = Color(col.r, col.g, col.b, 0.98)
		label.position = Vector3(c.x, _h(c.x, c.y) + 2.4, c.y)
		holder.add_child(label)
	_build_region_draft()


func _region_fill_mesh(pts: PackedVector2Array, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Fill"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var idx := Geometry2D.triangulate_polygon(pts)
	if idx.is_empty():
		return mi
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Color(col.r, col.g, col.b, REGION_FILL_ALPHA)
	for i in idx:
		var p := pts[i]
		var y := _h(p.x, p.y) + REGION_Y_LIFT
		st.set_color(c)
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(p.x, y, p.y))
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mi.material_override = mat
	return mi


## 贴地描边：逐段加密（2m 一段），跟着地形起伏走。
func _region_outline_mesh(pts: PackedVector2Array, col: Color, lift: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Outline"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var c := Color(col.r, col.g, col.b, REGION_LINE_ALPHA)
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var seg := maxi(1, int(ceil(a.distance_to(b) / 2.0)))
		var prev := Vector3(a.x, _h(a.x, a.y) + lift, a.y)
		for k in range(1, seg + 1):
			var t := float(k) / float(seg)
			var p := a.lerp(b, t)
			var cur := Vector3(p.x, _h(p.x, p.y) + lift, p.y)
			st.set_color(c)
			st.add_vertex(prev)
			st.set_color(c)
			st.add_vertex(cur)
			prev = cur
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	return mi


func _build_region_draft() -> void:
	if region_draft_root == null:
		return
	for c in region_draft_root.get_children():
		c.queue_free()
	if region_mode.is_empty() or region_draft.is_empty():
		return
	var col: Color = ShellStore.REGION_COLORS.get(region_mode, Color.WHITE)
	var pts := region_draft
	# 顶点标记：小球 + 首点高亮圈（点它就能闭合）
	for i in pts.size():
		var p := pts[i]
		var ball := SphereMesh.new()
		ball.radius = 0.32 if i > 0 else 0.55
		ball.height = ball.radius * 2.0
		var mi := MeshInstance3D.new()
		mi.name = "V%d" % i
		mi.mesh = ball
		mi.position = Vector3(p.x, _h(p.x, p.y) + 0.45, p.y)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.9
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		region_draft_root.add_child(mi)
	if pts.size() < 2:
		return
	var closed := PackedVector2Array(pts)
	if pts.size() >= 3:
		region_draft_root.add_child(_region_fill_mesh(closed, col))
	# 折线（未闭合也画出来，让人知道下一个点连到哪）
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var c := Color(col.r, col.g, col.b, 0.95)
	for i in pts.size():
		var a := pts[i]
		var b := pts[mini(i + 1, pts.size() - 1)] if i + 1 < pts.size() else pts[0]
		if i + 1 >= pts.size() and pts.size() < 3:
			break
		var seg := maxi(1, int(ceil(a.distance_to(b) / 2.0)))
		var prev := Vector3(a.x, _h(a.x, a.y) + 0.18, a.y)
		for k in range(1, seg + 1):
			var t := float(k) / float(seg)
			var p := a.lerp(b, t)
			var cur := Vector3(p.x, _h(p.x, p.y) + 0.18, p.y)
			st.set_color(c)
			st.add_vertex(prev)
			st.set_color(c)
			st.add_vertex(cur)
			prev = cur
	var mi2 := MeshInstance3D.new()
	mi2.name = "DraftOutline"
	mi2.mesh = st.commit()
	var mat2 := StandardMaterial3D.new()
	mat2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat2.vertex_color_use_as_albedo = true
	mat2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi2.material_override = mat2
	mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	region_draft_root.add_child(mi2)


# ===========================================================================
# 区域绘制状态机
# ===========================================================================
func begin_region(kind: String) -> void:
	region_mode = kind
	region_draft = PackedVector2Array()
	_clear_selection()
	_build_region_draft()


func cancel_region() -> void:
	if region_mode.is_empty() and region_draft.is_empty():
		return
	region_mode = ""
	region_draft = PackedVector2Array()
	_build_region_draft()


## 返回 true = 这一下左键被区域绘制吃掉。
func add_region_vertex(g: Vector3, screen_pos: Vector2) -> bool:
	if region_mode.is_empty():
		return false
	if region_draft.size() >= 3:
		var first := region_draft[0]
		if _screen_of(Vector3(first.x, _h(first.x, first.y), first.y)).distance_to(screen_pos) <= 14.0:
			finish_region()
			return true
	region_draft.append(Vector2(g.x, g.z))
	_build_region_draft()
	return true


## 闭合当前区域。返回 errors（空 = 成功）。失败时保留草稿，让人继续加点/取消。
func finish_region() -> Array:
	if region_mode.is_empty():
		return []
	if region_draft.size() < 3:
		return ["need 3 vertices"]
	var errors := ShellStore.region_validate(region_mode, region_draft)
	if not errors.is_empty():
		return errors
	push_undo()
	ShellStore.set_region_points(shell, region_mode, region_draft)
	region_changed.emit(region_mode)
	region_mode = ""
	region_draft = PackedVector2Array()
	_build_regions()
	changed.emit()
	picked.emit("region", 0)
	return []


# ===========================================================================
# 战术格子
# ===========================================================================
func _build_tiles() -> void:
	for c in tiles_root.get_children():
		c.queue_free()
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		var idx := int(td.get("index", 0))
		var active := true
		if not preview_layout.is_empty():
			active = ShellStore.is_active(preview_layout, idx)
		var node := _make_tile_node(td, active)
		node.name = "T%d" % idx
		node.set_meta("tile_index", idx)
		tiles_root.add_child(node)
	_refresh_tile_markers()


func _make_tile_node(td: Dictionary, active: bool) -> Node3D:
	var idx := int(td.get("index", 0))
	var side := String(td.get("side", "player"))
	var role := String(td.get("role", "build"))
	var w := float(td.get("w", ShellStore.TILE_SIZE_DEFAULT))
	var d := float(td.get("d", ShellStore.TILE_SIZE_DEFAULT))
	var ty := float(td.get("terrain_y", 0.0))
	var holder := Node3D.new()
	holder.position = Vector3(float(td.get("x", 0.0)), ty, float(td.get("z", 0.0)))
	holder.rotation = Vector3(0.0, deg_to_rad(float(td.get("yaw", 0.0))), 0.0)
	var accent: Color = ShellStore.REGION_COLORS.get(side, Color.WHITE)
	if role == "keep":
		accent = Color("#F0B95A")
	if not active:
		accent = Color("#6E7480")
	var is_sel := selected_tiles.has(idx)

	# 底盘：一块贴着地形的薄石板（编辑器辅助几何，不是游戏美术资产）
	var plate := BoxMesh.new()
	plate.size = Vector3(w, 0.22, d)
	var pmi := MeshInstance3D.new()
	pmi.name = "Plate"
	pmi.mesh = plate
	pmi.position = Vector3(0.0, 0.14, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color("#3A4352") if active else Color("#252A33")
	pmat.roughness = 0.85
	if is_sel:
		pmat.emission_enabled = true
		pmat.emission = Color("#F0B95A")
		pmat.emission_energy_multiplier = 0.25
	pmi.material_override = pmat
	pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(pmi)

	# 边框：四个角的世界折线（贴地，跟着地形）
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var hw := w * 0.5
	var hd := d * 0.5
	var corners: Array[Vector2] = [
		Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd), Vector2(-hw, hd),
	]
	var line_col := Color(accent.r, accent.g, accent.b, 0.95 if is_sel else 0.55)
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var seg := maxi(1, int(ceil(a.distance_to(b) / 1.5)))
		var prev := _tile_world(a, w, d, td) + Vector3(0.0, 0.2, 0.0)
		for k in range(1, seg + 1):
			var t := float(k) / float(seg)
			var cur := _tile_world(a.lerp(b, t), w, d, td) + Vector3(0.0, 0.2, 0.0)
			st.set_color(line_col)
			st.add_vertex(prev)
			st.set_color(line_col)
			st.add_vertex(cur)
			prev = cur
	var omi := MeshInstance3D.new()
	omi.name = "Outline"
	omi.mesh = st.commit()
	var omat := StandardMaterial3D.new()
	omat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	omat.vertex_color_use_as_albedo = true
	omat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	omi.material_override = omat
	omi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(omi)

	# 索引牌（始终可见：一眼知道布局卡引用的是哪个号）
	var label := Label3D.new()
	label.name = "Label"
	label.text = "T%d" % idx
	label.font_size = 72
	label.pixel_size = 0.015
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.outline_size = 12
	label.modulate = Color(1.0, 1.0, 1.0, 0.96) if active else Color(0.55, 0.6, 0.7, 0.9)
	label.position = Vector3(0.0, 1.3, 0.0)
	# 选中/悬停时由两个锚点标记接管画面，索引牌先让位（否则三行字叠在一起）
	label.visible = not is_sel
	holder.add_child(label)

	if not active:
		_build_tile_ruin(holder, w, d)
	return holder


## 未激活格子 = 碎石遗迹（和旧候选石台的 ruin 同语义：能看见、不能建造）。
func _build_tile_ruin(holder: Node3D, w: float, d: float) -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color("#2B3038")
	stone.roughness = 0.9
	for i in 5:
		var box := BoxMesh.new()
		var s := minf(w, d) * (0.12 + 0.03 * float(i % 3))
		box.size = Vector3(s * 1.6, s * 0.7, s * 1.2)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		var ang := float(i) / 5.0 * TAU
		mi.position = Vector3(cos(ang) * w * 0.2, 0.14, sin(ang) * d * 0.2)
		mi.rotation = Vector3(0.0, ang, 0.12 * float(i - 2))
		mi.material_override = stone
		holder.add_child(mi)


## 边框顶点是**局部坐标**（挂在一个已经平移/旋转过的 holder 下）：
## 只把"世界地形高度差"折算进来，绝不能再把 tile 的 x/z 加一遍 ——
## 否则边框会以两倍偏移漂到地图外面（2026-11-21 截图自检抓到的就是这个）。
func _tile_world(local_xz: Vector2, _w: float, _d: float, td: Dictionary) -> Vector3:
	var yaw := deg_to_rad(float(td.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)
	var wx := float(td.get("x", 0.0)) + local_xz.x * c + local_xz.y * s
	var wz := float(td.get("z", 0.0)) - local_xz.x * s + local_xz.y * c
	var dy := _h(wx, wz) - float(td.get("terrain_y", 0.0))
	return Vector3(local_xz.x, dy + 0.28, local_xz.y)


## 只给"选中 / 悬停"的格子画两个锚点标记：左上角建筑位 + 正中心出兵位。
## 全图 12 个格子都挂标记会糊成一团，所以按需重建。
func _refresh_tile_markers() -> void:
	if tile_markers_root == null:
		return
	for c in tile_markers_root.get_children():
		c.queue_free()
	var want: Array[int] = []
	for i in selected_tiles:
		if not want.has(i):
			want.append(i)
	if hovered_tile >= 0 and not want.has(hovered_tile):
		want.append(hovered_tile)
	for idx in want:
		var td := ShellStore.tile_by_index(shell, idx)
		if td.is_empty():
			continue
		tile_markers_root.add_child(_make_tile_markers(td))


func _make_tile_markers(td: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.name = "M%d" % int(td.get("index", 0))
	var anchors := ShellStore.tile_anchors(td)
	if anchors.is_empty():
		return holder
	# 建筑位：左上角的金色方框 + 一根短立柱
	var bx := float(anchors.get("building_x", td.get("x", 0.0)))
	var bz := float(anchors.get("building_z", td.get("z", 0.0)))
	var by := _h(bx, bz)
	var gold := Color("#F0B95A")
	var frame := BoxMesh.new()
	frame.size = Vector3(1.6, 0.08, 1.6)
	var fmi := MeshInstance3D.new()
	fmi.name = "BuildingAnchor"
	fmi.mesh = frame
	fmi.position = Vector3(bx, by + 0.22, bz)
	fmi.material_override = _flat_mat(gold, 0.75)
	holder.add_child(fmi)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.06
	pole.bottom_radius = 0.06
	pole.height = 1.2
	var pmi := MeshInstance3D.new()
	pmi.mesh = pole
	pmi.position = Vector3(bx, by + 0.8, bz)
	pmi.material_override = _flat_mat(gold, 0.9)
	holder.add_child(pmi)
	var blabel := Label3D.new()
	blabel.text = T("shell.tile.building")
	blabel.font_size = 40
	blabel.pixel_size = 0.011
	blabel.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	blabel.outline_size = 8
	blabel.modulate = gold
	blabel.position = Vector3(bx, by + 1.55, bz)
	holder.add_child(blabel)

	# 出兵位：正中心的青色圈（复用局内选中圈资产）
	var sx := float(anchors.get("spawn_x", td.get("x", 0.0)))
	var sz := float(anchors.get("spawn_z", td.get("z", 0.0)))
	var sy := _h(sx, sz)
	var ring_scn := _sel_ring_scene()
	var ring := ring_scn.instantiate() as Node3D if ring_scn != null else null
	if ring != null:
		ring.name = "SquadSpawnAnchor"
		ring.position = Vector3(sx, sy + 0.06, sz)
		ring.scale = Vector3.ONE * 1.4
		_tint_ring(ring, Color("#45D6A2"), 0.8)
		holder.add_child(ring)
	var slabel := Label3D.new()
	slabel.text = T("shell.tile.spawn")
	slabel.font_size = 40
	slabel.pixel_size = 0.011
	slabel.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	slabel.outline_size = 8
	slabel.modulate = Color("#45D6A2")
	slabel.position = Vector3(sx, sy + 1.1, sz)
	holder.add_child(slabel)
	return holder


func _flat_mat(col: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.4
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if alpha < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	m.disable_receive_shadows = true
	return m


# ===========================================================================
# 选中高亮圈（唯一资产：Content/art/特效/选中圈.tscn）
# ===========================================================================
func _rebuild_selection_rings() -> void:
	if selection_root == null:
		return
	for c in selection_root.get_children():
		c.queue_free()
	for idx in selected_tiles:
		var td := ShellStore.tile_by_index(shell, idx)
		if td.is_empty():
			continue
		var r := maxf(float(td.get("w", 6.0)), float(td.get("d", 6.0))) * 0.52
		_add_ring(Vector3(float(td.get("x", 0.0)), float(td.get("terrain_y", 0.0)) + 0.05, float(td.get("z", 0.0))),
			r, ShellStore.REGION_COLORS.get(String(td.get("side", "player")), Color.WHITE))
	for idx in selected_decor:
		var list: Array = shell.get("decorations", [])
		if idx < 0 or idx >= list.size():
			continue
		var dd: Dictionary = list[idx]
		var row := ShellStore.decor_row(String(dd.get("kind", "tree")))
		var base := float(row.get("radius", 1.2)) * float(dd.get("scale", 1.0))
		_add_ring(Vector3(float(dd.get("x", 0.0)), float(dd.get("y", 0.0)) + 0.05, float(dd.get("z", 0.0))),
			maxf(base, 0.7), Color("#F0B95A"))


func _add_ring(pos: Vector3, radius: float, col: Color) -> void:
	var ring_scn := _sel_ring_scene()
	if ring_scn == null:
		return
	var ring := ring_scn.instantiate() as Node3D
	if ring == null:
		return
	ring.position = pos
	ring.scale = Vector3.ONE * maxf(radius / 0.8, 0.35)
	_tint_ring(ring, col, 0.95)
	selection_root.add_child(ring)


## 改选中圈材质：**必须 duplicate**（PackedScene 里的子资源是共享的，
## 直接改会把所有圈一起染色 —— 这条和地形材质同一个理由）。
func _tint_ring(ring: Node3D, col: Color, alpha: float) -> void:
	var mi: MeshInstance3D = null
	for c in ring.get_children():
		if c is MeshInstance3D:
			mi = c as MeshInstance3D
			break
	if mi == null:
		return
	var src: Material = null
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		src = mi.mesh.surface_get_material(0)
	if src == null:
		src = mi.material_override
	if src is ShaderMaterial:
		var mat := (src as ShaderMaterial).duplicate(true) as ShaderMaterial
		mat.set_shader_parameter("team_color", col)
		mat.set_shader_parameter("opacity", alpha)
		mi.material_override = mat


# ===========================================================================
# 纯视觉装饰（只实例化既有资产）
# ===========================================================================
func _build_decor() -> void:
	for c in decor_root.get_children():
		c.queue_free()
	var list: Array = shell.get("decorations", [])
	for i in list.size():
		var d: Dictionary = list[i]
		var node := _make_decor_node(d)
		if node == null:
			continue
		node.name = "D%d" % i
		node.set_meta("decor_index", i)
		var gy := _h(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		d["y"] = snappedf(gy, 0.001)
		node.position = Vector3(float(d.get("x", 0.0)), gy, float(d.get("z", 0.0)))
		node.rotation = Vector3(0.0, deg_to_rad(float(d.get("yaw", 0.0))), 0.0)
		node.scale = Vector3.ONE * float(d.get("scale", 1.0))
		decor_root.add_child(node)


## **不现拼占位网格**：自然类走 RtsDecorLib 的场景，道具类直接实例化登记的 GLB。
func _make_decor_node(d: Dictionary) -> Node3D:
	var kind := String(d.get("kind", "tree"))
	var row := ShellStore.decor_row(kind)
	if row.is_empty():
		return null
	var source := String(row.get("source", "scene"))
	var path := String(row.get("path", ""))
	if source == "scene":
		var lib := _decor_lib_script()
		if lib != null:
			var n := lib.call("instantiate", StringName(kind)) as Node3D
			if n != null:
				return n
	var ps: PackedScene = _decor_scene(path)
	if ps == null:
		return null
	var inst := ps.instantiate()
	var node := inst as Node3D
	if node == null:
		if inst != null:
			inst.queue_free()
		return null
	return node


func _decor_lib_script() -> Script:
	if _decor_lib == null and ResourceLoader.exists(DECOR_LIB_PATH):
		_decor_lib = load(DECOR_LIB_PATH) as Script
	return _decor_lib


func _sel_ring_scene() -> PackedScene:
	if _sel_ring == null and ResourceLoader.exists(SEL_RING_PATH):
		_sel_ring = load(SEL_RING_PATH) as PackedScene
	return _sel_ring


func _decor_scene(path: String) -> PackedScene:
	if path.is_empty():
		return null
	if _decor_scene_cache.has(path):
		return _decor_scene_cache[path] as PackedScene
	var ps: PackedScene = null
	if ResourceLoader.exists(path):
		ps = load(path) as PackedScene
	_decor_scene_cache[path] = ps
	return ps


# ===========================================================================
# 相机
# ===========================================================================
func _h(x: float, z: float) -> float:
	return ShellStore.height_at_shell(shell, heights, x, z)


func _update_camera() -> void:
	if camera == null:
		return
	var yaw := deg_to_rad(cam_yaw)
	var pitch := deg_to_rad(cam_pitch)
	# cam_pitch 是「向下看的俯角」（负数），相机高度要用 -sin(cam_pitch)
	var offset := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw)) * cam_dist
	var pos := cam_target + offset
	# 地形保护：机位不许插进山体/台地里（只抬 y，不动俯角/距离/注视点）
	pos.y = maxf(pos.y, _h(pos.x, pos.z) + 3.0)
	camera.global_position = pos
	camera.look_at(cam_target, Vector3.UP)


func set_camera(yaw: float, pitch: float, dist: float, target: Vector3) -> void:
	cam_yaw = yaw
	cam_pitch = clampf(pitch, -88.0, -10.0)
	cam_dist = clampf(dist, CAM_DIST_MIN, CAM_DIST_MAX)
	cam_target = target
	_clamp_target()
	_update_camera()


## 复位：**游玩视角**（俯角 50° / FOV 52 / 距离 CAM_DIST_DEFAULT），看向地图中心。
func reset_camera() -> void:
	cam_target = Vector3.ZERO
	cam_dist = CAM_DIST_DEFAULT
	cam_yaw = 32.0
	cam_pitch = -CAM_PITCH_DEG
	_clamp_target()
	_update_camera()


## Ctrl+Shift+C：一键跳到玩家区主堡格子（= 旧编辑器 focus_player 的同一手感）。
func focus_player() -> void:
	var target := Vector3.ZERO
	var found := false
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		if String(td.get("side", "")) == "player" and String(td.get("role", "")) == "keep":
			target = Vector3(float(td.get("x", 0.0)), float(td.get("terrain_y", 0.0)), float(td.get("z", 0.0)))
			found = true
			break
	if not found:
		var sz := ShellStore.size_of(shell)
		target = Vector3(-sz.x * 0.25, _h(-sz.x * 0.25, 0.0), 0.0)
	cam_target = target
	cam_dist = clampf(CAM_DIST_PLAY, CAM_DIST_MIN, CAM_DIST_MAX)
	cam_yaw = 32.0
	cam_pitch = -CAM_PITCH_DEG
	_clamp_target()
	_update_camera()


## 俯瞰全图：俯角顶到 88°（正上方）。
func set_view_top() -> void:
	cam_pitch = -88.0
	cam_yaw = 0.0
	_clamp_target()
	_update_camera()


func set_view_iso() -> void:
	cam_pitch = -CAM_PITCH_DEG
	cam_yaw = 35.0
	_clamp_target()
	_update_camera()


func focus_on(world_pos: Vector3) -> void:
	cam_target = world_pos
	_clamp_target()
	_update_camera()


func zoom_by(factor: float) -> void:
	cam_dist = clampf(cam_dist * factor, CAM_DIST_MIN, CAM_DIST_MAX)
	_clamp_target()
	_update_camera()


func focus_selected() -> void:
	var target := Vector3.ZERO
	var found := false
	if not selected_tiles.is_empty():
		var td := ShellStore.tile_by_index(shell, selected_tiles[0])
		if not td.is_empty():
			target = Vector3(float(td.get("x", 0.0)), float(td.get("terrain_y", 0.0)), float(td.get("z", 0.0)))
			found = true
	elif not selected_decor.is_empty():
		var list: Array = shell.get("decorations", [])
		var i := selected_decor[0]
		if i >= 0 and i < list.size():
			var dd: Dictionary = list[i]
			target = Vector3(float(dd.get("x", 0.0)), float(dd.get("y", 0.0)), float(dd.get("z", 0.0)))
			found = true
	elif selected_point >= 0:
		var pts: Array = (shell.get("spine", {}) as Dictionary).get("points", [])
		if selected_point < pts.size():
			var sp: Dictionary = pts[selected_point]
			target = Vector3(float(sp.get("x", 0.0)), _h(float(sp.get("x", 0.0)), float(sp.get("z", 0.0))), float(sp.get("z", 0.0)))
			found = true
	if found:
		cam_target = target
		_clamp_target()
		_update_camera()


## 镜头边界（玩家口径「最多只能看到地图边界外一点点，禁止甩进无尽虚空」）。
##
## 与游戏 魔兽镜头 / 旧编辑器 视口._clamp_target() 同一套算法：
##   相机会在注视点后面后退 `dist × cos(俯角)` 米，所以能看的范围要**先扣掉这段后撤**，
##   否则拉远之后注视点还在图内、画面早已越过边界。
func _clamp_target() -> void:
	var sz := ShellStore.size_of(shell)
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var pitch := -deg_to_rad(cam_pitch)
	var reach := cam_dist * cos(pitch)
	var hx := maxf(sz.x * 0.5 - reach + CAM_BOUNDS_MARGIN, sz.x * 0.12)
	var hz := maxf(sz.y * 0.5 - reach + CAM_BOUNDS_MARGIN, sz.y * 0.12)
	cam_target.x = clampf(cam_target.x, -hx, hx)
	cam_target.z = clampf(cam_target.z, -hz, hz)
	cam_target.y = _h(cam_target.x, cam_target.z)


## WASD 平移 / QE 旋转 / 1-2 缩放（只有视口拿到键盘焦点时才吃键）。
func _handle_camera_keys(delta: float) -> void:
	if not keys_focus:
		return
	var yaw := deg_to_rad(cam_yaw)
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
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
		cam_target += move.normalized() * delta * maxf(18.0, cam_dist * 0.85)
		_clamp_target()
	if Input.is_key_pressed(KEY_Q):
		cam_yaw += rad_to_deg(delta * 1.6)
	if Input.is_key_pressed(KEY_E):
		cam_yaw -= rad_to_deg(delta * 1.6)
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_E):
		_update_camera()


func update_ambient() -> void:
	if world_env == null:
		return
	var amb: Dictionary = (shell.get("terrain", {}) as Dictionary).get("ambient", {})
	var env := world_env.environment
	env.ambient_light_color = Color(String(amb.get("tint", "#6B788F")))
	env.ambient_light_energy = float(amb.get("energy", 0.55))
	env.fog_density = float(amb.get("fog_density", CAM_FOG_DENSITY))
	if sun != null:
		sun.rotation_degrees = Vector3(float(amb.get("sun_pitch", -48.0)), float(amb.get("sun_yaw", -66.0)), 0.0)


# ===========================================================================
# 输入
# ===========================================================================
func is_orbiting() -> bool:
	return _orbiting or _left_orbit


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					# 旧编辑器是**乘性**缩放（每格 12%），不是固定加减
					cam_dist = clampf(cam_dist * 0.88, CAM_DIST_MIN, CAM_DIST_MAX)
					_clamp_target()
					_update_camera()
					return true
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					cam_dist = clampf(cam_dist * 1.14, CAM_DIST_MIN, CAM_DIST_MAX)
					_clamp_target()
					_update_camera()
					return true
			MOUSE_BUTTON_MIDDLE:
				# 中键旋转；按住 Shift = 平移（和旧编辑器一致）
				if mb.pressed:
					_orbiting = not Input.is_key_pressed(KEY_SHIFT)
					_panning = Input.is_key_pressed(KEY_SHIFT)
				else:
					_orbiting = false
					_panning = false
				return true
			MOUSE_BUTTON_RIGHT:
				# 右键拖动 = 平移；右键单击（位移 < 4px）= 取消当前动作
				if mb.pressed:
					_panning = true
					_rmb_moved = 0.0
				else:
					_panning = false
					if _rmb_moved < 4.0:
						_on_right_click()
				return true
			MOUSE_BUTTON_LEFT:
				_left_down = mb.pressed
				if mb.pressed:
					if Input.is_key_pressed(KEY_ALT):
						# Alt+左键 = 转视角（笔记本没中键也能转）
						_left_orbit = true
						_orbiting = true
						return true
					return _on_left_down(pos)
				else:
					if _left_orbit:
						# 本次左键只用来转视角，松手收尾，不落到任何工具上
						_left_orbit = false
						_orbiting = false
						return true
					return _on_left_up(pos)
		return false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			# 灵敏度 = 旧编辑器：yaw 0.006 rad/px / pitch 0.005 rad/px
			cam_yaw -= mm.relative.x * rad_to_deg(0.006)
			cam_pitch = clampf(cam_pitch - mm.relative.y * rad_to_deg(0.005), -88.0, -10.0)
			_update_camera()
			return true
		if _panning:
			_rmb_moved += mm.relative.length()
			var yaw := deg_to_rad(cam_yaw)
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var scale := 0.0016 * cam_dist
			cam_target -= right * mm.relative.x * scale
			cam_target -= fwd * (-mm.relative.y * scale)
			_clamp_target()
			_update_camera()
			return true
		var g := ground_at(pos)
		_hover_ground = g
		_hover_valid = true
		if _painting and tool == TOOL_TERRAIN:
			_paint_ground = g
		# 框选：按住左键在空地上拖出矩形
		if _pending_add and _left_down:
			if pos.distance_to(_box_start) > 4.0:
				_box_active = true
				_pending_add = false
		if _box_active:
			_box_end = pos
			box_changed.emit(_box_start, _box_end)
		# 悬停：给格子画锚点标记
		if tool == TOOL_TILE and not _dragging and not _box_active:
			var h := pick_tile(pos)
			if h != hovered_tile:
				hovered_tile = h
				_refresh_tile_markers()
		elif tool != TOOL_TILE and hovered_tile >= 0:
			hovered_tile = -1
			_refresh_tile_markers()
		# 拖拽移动：选中物跟着鼠标走，贴合地形
		if _dragging and not is_orbiting():
			_drag_apply(g)
		return false
	elif event is InputEventKey:
		return _handle_key(event as InputEventKey)
	return false


func _handle_key(k: InputEventKey) -> bool:
	if not k.pressed:
		return false
	# Ctrl+Z 撤销（必须先于 match）
	if k.keycode == KEY_Z and k.ctrl_pressed:
		return undo()
	# Ctrl+Shift+C 一键跳到玩家区（必须先于 match：Ctrl+C 是复制）
	if k.keycode == KEY_C and k.ctrl_pressed and k.shift_pressed:
		focus_player()
		return true
	match k.keycode:
		KEY_F:
			focus_selected()
			return true
		KEY_DELETE, KEY_BACKSPACE:
			return _delete_selected()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not region_mode.is_empty():
				var errs := finish_region()
				region_finished.emit(errs)
				return true
			return false
		KEY_ESCAPE:
			if not region_mode.is_empty():
				cancel_region()
				region_cancelled.emit()
				return true
			_painting = false
			_clear_selection()
			_refresh_tile_markers()
			picked.emit("none", -1)
			return true
		KEY_1:
			zoom_by(0.9)
			return true
		KEY_2:
			zoom_by(1.1)
			return true
		KEY_R:
			# 选中装饰时旋转（45°，与面板按钮同口径；Shift+R 反向）
			if tool == TOOL_DECOR and not selected_decor.is_empty():
				rotate_decor(selected_decor[0], -45.0 if Input.is_key_pressed(KEY_SHIFT) else 45.0)
				return true
			# 选中格子时按 R 也转 45°（格子朝向会影响锚点位置）
			if tool == TOOL_TILE and not selected_tiles.is_empty():
				rotate_tiles(-45.0 if Input.is_key_pressed(KEY_SHIFT) else 45.0)
				return true
	return false


func _on_right_click() -> void:
	# 右键 = 取消当前动作（绘制中取消绘制，否则停笔 + 清空选择）
	_painting = false
	if not region_mode.is_empty():
		cancel_region()
		region_cancelled.emit()
		return
	_clear_selection()
	_refresh_tile_markers()
	picked.emit("none", -1)


func _clear_selection() -> void:
	selected_tiles.clear()
	selected_decor.clear()
	selected_point = -1
	hovered_tile = -1
	hovered_decor = -1


func clear_selection() -> void:
	_clear_selection()
	_rebuild_selection_rings()
	_refresh_tile_markers()
	picked.emit("none", -1)


func _delete_selected() -> bool:
	if not selected_tiles.is_empty() or not selected_decor.is_empty():
		push_undo()
		var tile_list: Array = shell.get("tiles", [])
		var kill_tiles := selected_tiles.duplicate()
		for i in range(tile_list.size() - 1, -1, -1):
			if kill_tiles.has(int((tile_list[i] as Dictionary).get("index", -1))):
				tile_list.remove_at(i)
		var decor_list: Array = shell.get("decorations", [])
		var kill_decor := selected_decor.duplicate()
		kill_decor.sort()
		kill_decor.reverse()
		for i in kill_decor:
			if i >= 0 and i < decor_list.size():
				decor_list.remove_at(int(i))
		_clear_selection()
		_build_tiles()
		_build_decor()
		_rebuild_selection_rings()
		changed.emit()
		return true
	return false


func _on_left_down(pos: Vector2) -> bool:
	var g := ground_at(pos)
	if not region_mode.is_empty():
		return add_region_vertex(g, pos)
	if tool == TOOL_TERRAIN:
		push_undo()
		_painting = true
		_paint_ground = g
		_paint_height = ShellStore.height_at_shell(shell, heights, g.x, g.z)
		_apply_brush(g, 1.0)
		return true
	if tool == TOOL_DECOR:
		var hit := pick_decor(pos)
		if hit >= 0:
			if Input.is_key_pressed(KEY_SHIFT):
				_toggle_decor(hit)
			elif not selected_decor.has(hit):
				_select_only_decor(hit)
			_begin_drag(g)
			return true
		# 空地：先记成"可能是框选"，松手没移动才放装饰
		_pending_add = true
		_box_active = false
		_box_start = pos
		_box_end = pos
		return true
	if tool == TOOL_TILE:
		var thit := pick_tile(pos)
		if thit >= 0:
			if Input.is_key_pressed(KEY_SHIFT):
				_toggle_tile(thit)
			elif not selected_tiles.has(thit):
				_select_only_tile(thit)
			_begin_drag(g)
			return true
		_pending_add = true
		_box_active = false
		_box_start = pos
		_box_end = pos
		return true
	if tool == TOOL_SPINE:
		var sh := pick_spine_point(pos)
		if sh >= 0:
			selected_point = sh
			_begin_drag(g)
			picked.emit("point", sh)
			return true
	return false


func _on_left_up(pos: Vector2) -> bool:
	if _dragging:
		_dragging = false
		_drag_offsets.clear()
		_drag_snapshot = {}
		_drag_moved = false
		_rebuild_selection_rings()
		_refresh_tile_markers()
		changed.emit()
		return true
	if _box_active:
		_box_active = false
		_pending_add = false
		_finish_box_select(_box_start, pos)
		box_changed.emit(_box_start, _box_start)
		box_cleared.emit()
		return true
	if _pending_add:
		_pending_add = false
		var g := ground_at(pos)
		if tool == TOOL_DECOR:
			add_decor(g, decor_kind)
		elif tool == TOOL_TILE:
			add_tile(g)
		return true
	if _painting:
		_painting = false
		_grid_accum = 0.0
		_build_grid()
		changed.emit()
		return true
	return false


func _begin_drag(g: Vector3) -> void:
	if selected_tiles.is_empty() and selected_decor.is_empty() and selected_point < 0:
		return
	_dragging = true
	_drag_start = g
	_drag_moved = false
	_drag_snapshot = shell.duplicate(true)
	_drag_offsets.clear()
	for idx in selected_tiles:
		var td := ShellStore.tile_by_index(shell, idx)
		if td.is_empty():
			continue
		_drag_offsets.append({"kind": "tile", "index": idx,
			"dx": float(td.get("x", 0.0)) - g.x, "dz": float(td.get("z", 0.0)) - g.z})
	for i in selected_decor:
		var list: Array = shell.get("decorations", [])
		if i < 0 or i >= list.size():
			continue
		var dd: Dictionary = list[i]
		_drag_offsets.append({"kind": "decor", "index": i,
			"dx": float(dd.get("x", 0.0)) - g.x, "dz": float(dd.get("z", 0.0)) - g.z})


func _drag_apply(g: Vector3) -> void:
	if not _drag_snapshot.is_empty():
		_undo.append(_drag_snapshot)
		if _undo.size() > UNDO_MAX:
			_undo.pop_front()
		_drag_snapshot = {}
		_drag_moved = true
	for row in _drag_offsets:
		var d: Dictionary = row
		var nx := snappedf(g.x + float(d["dx"]), 0.05)
		var nz := snappedf(g.z + float(d["dz"]), 0.05)
		if String(d["kind"]) == "tile":
			var td := ShellStore.tile_by_index(shell, int(d["index"]))
			if td.is_empty():
				continue
			td["x"] = nx
			td["z"] = nz
			td["terrain_y"] = snappedf(_h(nx, nz), 0.001)
		else:
			var list: Array = shell.get("decorations", [])
			var i := int(d["index"])
			if i < 0 or i >= list.size():
				continue
			var dd: Dictionary = list[i]
			dd["x"] = nx
			dd["z"] = nz
			dd["y"] = snappedf(_h(nx, nz), 0.001)
	_build_tiles()
	_build_decor()
	_rebuild_selection_rings()
	_refresh_tile_markers()


func _finish_box_select(from: Vector2, to: Vector2) -> void:
	var rect := Rect2(from, to - from).abs()
	var t_hits: Array[int] = []
	var d_hits: Array[int] = []
	if tool == TOOL_TILE:
		for t in ShellStore.tiles(shell):
			var td: Dictionary = t
			var p := _screen_of(Vector3(float(td.get("x", 0.0)), float(td.get("terrain_y", 0.0)), float(td.get("z", 0.0))))
			if rect.has_point(p):
				t_hits.append(int(td.get("index", 0)))
		if not Input.is_key_pressed(KEY_SHIFT):
			selected_tiles.clear()
			selected_decor.clear()
		for idx in t_hits:
			if not selected_tiles.has(idx):
				selected_tiles.append(idx)
	elif tool == TOOL_DECOR:
		var list: Array = shell.get("decorations", [])
		for i in list.size():
			var dd: Dictionary = list[i]
			var p := _screen_of(Vector3(float(dd.get("x", 0.0)), float(dd.get("y", 0.0)) + 0.8, float(dd.get("z", 0.0))))
			if rect.has_point(p):
				d_hits.append(i)
		if not Input.is_key_pressed(KEY_SHIFT):
			selected_tiles.clear()
			selected_decor.clear()
		for i in d_hits:
			if not selected_decor.has(i):
				selected_decor.append(i)
	_rebuild_selection_rings()
	_refresh_tile_markers()
	if not t_hits.is_empty() or not d_hits.is_empty():
		picked.emit("tile" if tool == TOOL_TILE else "decor", t_hits.size() + d_hits.size())


func _process(delta: float) -> void:
	if camera == null:
		return
	_handle_camera_keys(delta)
	_update_camera()
	if _painting and tool == TOOL_TERRAIN and _hover_valid:
		_paint_accum += delta
		if _paint_accum >= 0.04:
			_paint_accum = 0.0
			_apply_brush(_paint_ground, 1.0)


# ===========================================================================
# 笔刷
# ===========================================================================
func _apply_brush(center: Vector3, _weight: float) -> void:
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	var ox := float(g["origin_x"])
	var oz := float(g["origin_z"])
	# 草丛/泥土写的是 **8m 地块格点**（旧编辑器 mat_brush_radius 的口径）：
	#   笔刷半径只有 6m、格点间距 8m —— 不外扩半格就会出现"点了半天一点反应都没有"。
	#   判定语义 = "笔刷圈碰到的地块都算"。岩石/沙地是贴花，仍按原半径。
	var reach := brush_radius
	if brush_mode == "surface" and (surface_layer == 0 or surface_layer == 1):
		reach = brush_radius + TILE_M * 0.5
	var c0 := int(clampf(floor((center.x - reach - ox) / cell), 0.0, float(cols - 1)))
	var c1 := int(clampf(ceil((center.x + reach - ox) / cell), 0.0, float(cols - 1)))
	var r0 := int(clampf(floor((center.z - reach - oz) / cell), 0.0, float(rows - 1)))
	var r1 := int(clampf(ceil((center.z + reach - oz) / cell), 0.0, float(rows - 1)))
	var touched := false
	for row in range(r0, r1 + 1):
		for col in range(c0, c1 + 1):
			var wx := ox + float(col) * cell
			var wz := oz + float(row) * cell
			var d := Vector2(wx - center.x, wz - center.z).length()
			if d > reach:
				continue
			var fall := pow(1.0 - d / maxf(reach, 0.001), 1.6)
			var i := row * cols + col
			match brush_mode:
				"raise":
					heights[i] = minf(heights[i] + brush_strength * fall * 0.22, 12.0)
				"lower":
					heights[i] = maxf(heights[i] - brush_strength * fall * 0.22, -8.0)
				"smooth":
					var sum := 0.0
					var n := 0
					for dr in [-1, 0, 1]:
						for dc in [-1, 0, 1]:
							var rr := clampi(row + dr, 0, rows - 1)
							var cc := clampi(col + dc, 0, cols - 1)
							sum += heights[rr * cols + cc]
							n += 1
					heights[i] = lerpf(heights[i], sum / float(n), clampf(brush_strength * fall, 0.0, 1.0))
				"flatten":
					heights[i] = lerpf(heights[i], _paint_height, clampf(brush_strength * fall, 0.0, 1.0))
				"surface":
					if fall > 0.25:
						while surface.size() < cols * rows:
							surface.append(0)
						surface[i] = surface_layer
			touched = true
	if touched:
		var terrain: Dictionary = shell.get("terrain", {})
		terrain["heights"] = heights_to_array()
		shell["terrain"] = terrain
		var surf: Dictionary = shell.get("surface", {})
		surf["index"] = surface
		shell["surface"] = surf
		_build_terrain()
		_build_water()
		_build_ribbon()
		_build_regions()
		_build_tiles()
		_build_decor()
		_rebuild_selection_rings()
		# 辅助网格贴着地形走：拖动中 5Hz 重建就够，松手再补一次精确的
		_grid_accum += 0.04
		if _grid_accum >= 0.2:
			_grid_accum = 0.0
			_build_grid()
		brushed.emit()


func heights_to_array() -> Array:
	var out: Array = []
	out.resize(heights.size())
	for i in heights.size():
		out[i] = snappedf(heights[i], 0.001)
	return out


# ===========================================================================
# 撤销
# ===========================================================================
func push_undo() -> void:
	if shell.is_empty():
		return
	_undo.append(shell.duplicate(true))
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()


func can_undo() -> bool:
	return not _undo.is_empty()


## 撤销一步：把快照**就地**写回 shell（保持引用不变，dev_data 里那份才认得）。
func undo() -> bool:
	if _undo.is_empty():
		return false
	var snap: Dictionary = _undo.pop_back()
	shell.clear()
	for k in snap.keys():
		shell[k] = snap[k]
	heights = ShellStore.heights_or_procedural(shell)
	surface = ShellStore.surface_index(shell)
	_clear_selection()
	rebuild_all()
	update_ambient()
	changed.emit()
	picked.emit("none", -1)
	return true


# ===========================================================================
# 编辑：装饰
# ===========================================================================
func add_decor(g: Vector3, kind: String) -> void:
	push_undo()
	var list: Array = shell.get("decorations", [])
	list.append({
		"kind": kind,
		"x": snappedf(g.x, 0.01),
		"z": snappedf(g.z, 0.01),
		"y": snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001),
		"yaw": 0.0,
		"scale": 1.0,
	})
	shell["decorations"] = list
	_select_only_decor(list.size() - 1)
	_build_decor()
	_rebuild_selection_rings()
	changed.emit()
	picked.emit("decor", list.size() - 1)


func move_decor(index: int, g: Vector3) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	var d: Dictionary = list[index]
	d["x"] = snappedf(g.x, 0.01)
	d["z"] = snappedf(g.z, 0.01)
	d["y"] = snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001)
	_build_decor()
	_rebuild_selection_rings()
	changed.emit()


func rotate_decor(index: int, deg: float) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	push_undo()
	var d: Dictionary = list[index]
	d["yaw"] = fmod(float(d.get("yaw", 0.0)) + deg + 360.0, 360.0)
	_build_decor()
	changed.emit()


func set_decor_scale(index: int, value: float) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	(list[index] as Dictionary)["scale"] = clampf(value, 0.4, 3.0)
	_build_decor()
	_rebuild_selection_rings()
	changed.emit()


func remove_decor(index: int) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	push_undo()
	list.remove_at(index)
	_clear_selection()
	_build_decor()
	_rebuild_selection_rings()
	changed.emit()


# ===========================================================================
# 编辑：战术格子
# ===========================================================================
func add_tile(g: Vector3) -> void:
	push_undo()
	var list: Array = shell.get("tiles", [])
	var idx := ShellStore.next_index(shell)
	list.append({
		"index": idx,
		"side": ShellStore.side_of(g.x),
		"role": "build",
		"x": snappedf(g.x, 0.05),
		"z": snappedf(g.z, 0.05),
		"w": ShellStore.TILE_SIZE_DEFAULT,
		"d": ShellStore.TILE_SIZE_DEFAULT,
		"yaw": 0.0,
		"terrain_y": snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001),
	})
	shell["tiles"] = list
	_select_only_tile(idx)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()
	picked.emit("tile", idx)


func move_tile(index: int, g: Vector3) -> void:
	var td := ShellStore.tile_by_index(shell, index)
	if td.is_empty():
		return
	td["x"] = snappedf(g.x, 0.05)
	td["z"] = snappedf(g.z, 0.05)
	td["side"] = ShellStore.side_of(float(td["x"]))
	td["terrain_y"] = snappedf(ShellStore.height_at_shell(shell, heights, float(td["x"]), float(td["z"])), 0.001)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func snap_tiles() -> void:
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		td["terrain_y"] = snappedf(ShellStore.height_at_shell(shell, heights, float(td.get("x", 0.0)), float(td.get("z", 0.0))), 0.001)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func set_tile_role(index: int, role: String) -> void:
	var td := ShellStore.tile_by_index(shell, index)
	if td.is_empty():
		return
	push_undo()
	td["role"] = role
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func set_tile_size(index: int, w: float, d: float) -> void:
	var td := ShellStore.tile_by_index(shell, index)
	if td.is_empty():
		return
	td["w"] = clampf(w, 2.0, 24.0)
	td["d"] = clampf(d, 2.0, 24.0)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func set_tiles_size(w: float, d: float) -> void:
	if selected_tiles.is_empty():
		return
	for idx in selected_tiles:
		var td := ShellStore.tile_by_index(shell, idx)
		if td.is_empty():
			continue
		td["w"] = clampf(w, 2.0, 24.0)
		td["d"] = clampf(d, 2.0, 24.0)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func rotate_tiles(deg: float) -> void:
	if selected_tiles.is_empty():
		return
	push_undo()
	for idx in selected_tiles:
		var td := ShellStore.tile_by_index(shell, idx)
		if td.is_empty():
			continue
		td["yaw"] = fmod(float(td.get("yaw", 0.0)) + deg + 360.0, 360.0)
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


func remove_tile(index: int) -> void:
	var list: Array = shell.get("tiles", [])
	var removed := false
	push_undo()
	for i in range(list.size() - 1, -1, -1):
		if int((list[i] as Dictionary).get("index", -1)) == index:
			list.remove_at(i)
			removed = true
	if removed:
		selected_tiles.erase(index)
		_build_tiles()
		_rebuild_selection_rings()
		changed.emit()


func renumber_tiles() -> void:
	var list: Array = shell.get("tiles", [])
	push_undo()
	list.sort_custom(func(a, b): return float(a.get("x", 0.0)) < float(b.get("x", 0.0)))
	for i in list.size():
		var td: Dictionary = list[i]
		td["index"] = i + 1
	selected_tiles.clear()
	_build_tiles()
	_rebuild_selection_rings()
	changed.emit()


# ===========================================================================
# 编辑：脊线
# ===========================================================================
func set_spine_width(width_logic: float) -> void:
	var spine: Dictionary = shell.get("spine", {})
	spine["width_logic"] = clampf(round(width_logic), 100.0, 999.0)
	spine["width_m"] = snappedf(float(spine["width_logic"]) * ShellStore.R1, 0.001)
	shell["spine"] = spine
	_build_ribbon()
	changed.emit()


func move_spine_point(index: int, g: Vector3) -> void:
	var pts: Array = (shell.get("spine", {}) as Dictionary).get("points", [])
	if index < 0 or index >= pts.size():
		return
	var p: Dictionary = pts[index]
	p["x"] = snappedf(g.x, 0.05)
	p["z"] = snappedf(g.z, 0.05)
	_build_ribbon()
	changed.emit()


func add_spine_point() -> void:
	var spine: Dictionary = shell.get("spine", {})
	var pts: Array = spine.get("points", [])
	if pts.size() < 2:
		return
	push_undo()
	var a: Dictionary = pts[pts.size() - 2]
	var b: Dictionary = pts[pts.size() - 1]
	pts.insert(pts.size() - 1, {"x": (float(a.get("x", 0.0)) + float(b.get("x", 0.0))) * 0.5,
		"z": (float(a.get("z", 0.0)) + float(b.get("z", 0.0))) * 0.5})
	spine["points"] = pts
	shell["spine"] = spine
	_build_ribbon()
	changed.emit()


func remove_spine_point() -> void:
	var spine: Dictionary = shell.get("spine", {})
	var pts: Array = spine.get("points", [])
	if pts.size() <= 2:
		return
	push_undo()
	pts.remove_at(pts.size() - 1)
	spine["points"] = pts
	shell["spine"] = spine
	_build_ribbon()
	changed.emit()


# ===========================================================================
# 拾取
# ===========================================================================
func ground_at(pos: Vector2) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var plane := Plane(Vector3.UP, 0.0)
	var hit: Variant = plane.intersects_ray(from, dir)
	if hit == null:
		return Vector3.ZERO
	var p: Vector3 = hit
	p.y = ShellStore.height_at_shell(shell, heights, p.x, p.z)
	return p


func _screen_of(world: Vector3) -> Vector2:
	if camera == null or camera.is_position_behind(world):
		return Vector2(-100000.0, -100000.0)
	return camera.unproject_position(world)


## 点选格子：先看地面点落在哪个格子里（旋转按 yaw 还原），再按屏幕距离兜底。
func pick_tile(pos: Vector2) -> int:
	var g := ground_at(pos)
	var best := -1
	var best_inside := 1e20
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		if not ShellStore.tile_contains(td, g.x, g.z):
			continue
		var dd := Vector2(float(td.get("x", 0.0)) - g.x, float(td.get("z", 0.0)) - g.z).length()
		if dd < best_inside:
			best_inside = dd
			best = int(td.get("index", -1))
	if best >= 0:
		return best
	# 兜底：格子很小 / 被地形挡住时，按屏幕距离选最近的索引牌
	var best_d := 26.0
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		var wp := Vector3(float(td.get("x", 0.0)), float(td.get("terrain_y", 0.0)) + 0.6, float(td.get("z", 0.0)))
		var d := _screen_of(wp).distance_to(pos)
		if d < best_d:
			best_d = d
			best = int(td.get("index", -1))
	return best


func pick_decor(pos: Vector2) -> int:
	var best := -1
	var best_d := 30.0
	var list: Array = shell.get("decorations", [])
	for i in list.size():
		var d: Dictionary = list[i]
		var row := ShellStore.decor_row(String(d.get("kind", "tree")))
		var h := float(row.get("radius", 1.2)) * float(d.get("scale", 1.0)) * 0.6
		var wp := Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)) + h, float(d.get("z", 0.0)))
		var dist := _screen_of(wp).distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = i
	return best


func pick_spine_point(pos: Vector2) -> int:
	var pts: Array = (shell.get("spine", {}) as Dictionary).get("points", [])
	var best := -1
	var best_d := 28.0
	for i in pts.size():
		var p: Dictionary = pts[i]
		var wp := Vector3(float(p.get("x", 0.0)), ShellStore.height_at(shell, float(p.get("x", 0.0)), float(p.get("z", 0.0))) + 0.5, float(p.get("z", 0.0)))
		var dist := _screen_of(wp).distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = i
	return best


func _select_only_tile(index: int) -> void:
	selected_tiles.clear()
	selected_decor.clear()
	selected_point = -1
	selected_tiles.append(index)
	_rebuild_selection_rings()
	_refresh_tile_markers()
	picked.emit("tile", index)


func _select_only_decor(index: int) -> void:
	selected_tiles.clear()
	selected_decor.clear()
	selected_point = -1
	selected_decor.append(index)
	_rebuild_selection_rings()
	_refresh_tile_markers()
	picked.emit("decor", index)


func _toggle_tile(index: int) -> void:
	if selected_tiles.has(index):
		selected_tiles.erase(index)
	else:
		selected_tiles.append(index)
	_rebuild_selection_rings()
	_refresh_tile_markers()
	picked.emit("tile", index)


func _toggle_decor(index: int) -> void:
	if selected_decor.has(index):
		selected_decor.erase(index)
	else:
		selected_decor.append(index)
	_rebuild_selection_rings()
	picked.emit("decor", index)


func select_tile(index: int) -> void:
	_select_only_tile(index)


func select_tiles(indices: Array) -> void:
	selected_tiles.clear()
	for i in indices:
		selected_tiles.append(int(i))
	_rebuild_selection_rings()
	_refresh_tile_markers()


func select_decor(index: int) -> void:
	_select_only_decor(index)


## 拖拽：选中格子/装饰/脊线控制点后，鼠标位移直接改数据（贴合地形）。
func drag_to(g: Vector3) -> void:
	if tool == TOOL_TILE and not selected_tiles.is_empty():
		for idx in selected_tiles:
			move_tile(idx, g)
	elif tool == TOOL_DECOR and not selected_decor.is_empty():
		for idx in selected_decor:
			move_decor(idx, g)
	elif tool == TOOL_SPINE and selected_point >= 0:
		move_spine_point(selected_point, g)


func hover_info() -> Dictionary:
	return {"valid": _hover_valid, "x": _hover_ground.x, "z": _hover_ground.z, "y": _hover_ground.y}


func is_dragging() -> bool:
	return _dragging


func T(key: String, params: Dictionary = {}) -> String:
	return ShellText.t(key, params)
