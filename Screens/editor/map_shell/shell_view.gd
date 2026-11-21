@tool
extends Node3D
## 3D 地图底壳编辑器 · 世界与编辑核心
## 属于：Screens/editor/map_shell（开发工具，不进发行版）
##
## 只做四件事：地形/地表笔刷、纯视觉装饰摆放、弯曲行军脊线与分割环、候选独立石台锚点。
## 明确不做：摆兵种、写触发器、涂 A* 寻路格、配经济（三分离后属于布局卡/遭遇卡/关卡）。
##
## 数据：直接读写 shell_store 的 map_shells 结构；写盘由外层 map_shell_editor.gd 调 dev_data。

signal brushed()
signal picked(kind: String, index: int)
signal changed()

const ShellStore := preload("res://Screens/editor/shell_store.gd")

const TOOL_TERRAIN := "terrain"
const TOOL_DECOR := "decor"
const TOOL_SPINE := "spine"
const TOOL_PLATFORM := "platform"

const RING_COLORS := {
	"player_zone_end": Color("#4EA1FF"),
	"neutral_center": Color("#4ED8D8"),
	"push_line": Color("#45D6A2"),
	"base_cross_line": Color("#F0B95A"),
}
const SURFACE_TINTS := [Color("#5D6B3F"), Color("#6B5A43"), Color("#5A5F68"), Color("#8A7A56")]

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

# 选择
var selected_platform := -1
var selected_divider := ""
var selected_decor := -1
var selected_point := -1

# 相机
var cam_target := Vector3.ZERO
var cam_yaw := -48.0
var cam_pitch := -40.0
var cam_dist := 74.0

# 节点
var camera: Camera3D = null
var sun: DirectionalLight3D = null
var world_env: WorldEnvironment = null
var terrain_mesh: MeshInstance3D = null
var water_mesh: MeshInstance3D = null
var grid_mesh: MeshInstance3D = null
var ribbon_mesh: MeshInstance3D = null
var rings_root: Node3D = null
var platforms_root: Node3D = null
var decor_root: Node3D = null

var _painting := false
var _paint_ground := Vector3.ZERO
var _paint_height := 0.0
var _paint_accum := 0.0
var _last_mouse := Vector2.ZERO
var _hover_ground := Vector3.ZERO
var _hover_valid := false


# ===========================================================================
# 场景装配
# ===========================================================================
func build_world() -> void:
	if camera != null:
		return
	world_env = WorldEnvironment.new()
	world_env.name = "Env"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#0B0E14")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#9FB6D8")
	env.ambient_light_energy = 0.9
	env.fog_enabled = true
	env.fog_light_color = Color("#1A2230")
	env.fog_density = 0.012
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-46.0, 132.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 52.0
	camera.near = 0.1
	camera.far = 400.0
	add_child(camera)

	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "Terrain"
	add_child(terrain_mesh)
	water_mesh = MeshInstance3D.new()
	water_mesh.name = "Water"
	add_child(water_mesh)
	grid_mesh = MeshInstance3D.new()
	grid_mesh.name = "Grid"
	add_child(grid_mesh)
	ribbon_mesh = MeshInstance3D.new()
	ribbon_mesh.name = "Ribbon"
	add_child(ribbon_mesh)
	rings_root = Node3D.new()
	rings_root.name = "Rings"
	add_child(rings_root)
	platforms_root = Node3D.new()
	platforms_root.name = "Platforms"
	add_child(platforms_root)
	decor_root = Node3D.new()
	decor_root.name = "Decor"
	add_child(decor_root)
	_update_camera()


func load_shell(p_shell: Dictionary) -> void:
	shell = p_shell
	if shell.is_empty():
		return
	heights = ShellStore.heights_or_procedural(shell)
	surface = ShellStore.surface_index(shell)
	selected_platform = -1
	selected_divider = ""
	selected_decor = -1
	selected_point = -1
	preview_layout = {}
	rebuild_all()
	update_ambient()


func rebuild_all() -> void:
	if camera == null:
		build_world()
	_build_terrain()
	_build_water()
	_build_grid()
	_build_ribbon()
	_build_rings()
	_build_platforms()
	_build_decor()
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
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(cols * rows)
	normals.resize(cols * rows)
	colors.resize(cols * rows)
	uvs.resize(cols * rows)
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
			var idx := int(surface[i]) if i < surface.size() else 0
			var col_c := ShellStore.palette_color(shell, idx)
			var shade := clampf(0.86 + y * 0.035 + float((col * 7 + row * 13) % 5) * 0.012, 0.7, 1.14)
			colors[i] = Color(col_c.r * shade, col_c.g * shade, col_c.b * shade, 1.0)
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
			indices[k] = a
			indices[k + 1] = c
			indices[k + 2] = b
			indices[k + 3] = b
			indices[k + 4] = c
			indices[k + 5] = d
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
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.96
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	terrain_mesh.material_override = mat


func _build_water() -> void:
	var sz := ShellStore.size_of(shell)
	var water := float((shell.get("terrain", {}) as Dictionary).get("water_level", ShellStore.WATER_DEFAULT))
	var plane := PlaneMesh.new()
	plane.size = Vector2(sz.x, sz.y)
	water_mesh.mesh = plane
	water_mesh.position = Vector3(0.0, water, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.34, 0.48, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mat.metallic = 0.2
	water_mesh.material_override = mat


func _build_grid() -> void:
	var sz := ShellStore.size_of(shell)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var step := 10.0
	var x := -sz.x * 0.5
	while x <= sz.x * 0.5:
		im.surface_add_vertex(Vector3(x, 0.02, -sz.y * 0.5))
		im.surface_add_vertex(Vector3(x, 0.02, sz.y * 0.5))
		x += step
	var z := -sz.y * 0.5
	while z <= sz.y * 0.5:
		im.surface_add_vertex(Vector3(-sz.x * 0.5, 0.02, z))
		im.surface_add_vertex(Vector3(sz.x * 0.5, 0.02, z))
		z += step
	im.surface_end()
	grid_mesh.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.65, 0.85, 0.16)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid_mesh.material_override = mat


# ===========================================================================
# 脊线 / 分割环
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


func _build_rings() -> void:
	for c in rings_root.get_children():
		c.queue_free()
	var width_m := float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)) * ShellStore.R1
	for id in ShellStore.DIVIDER_IDS:
		var d: Dictionary = ShellStore.divider(shell, id)
		if d.is_empty():
			continue
		var t := int(d.get("t", 0))
		var p := ShellStore.point_at_t(shell, t)
		var y := ShellStore.height_at(shell, p.x, p.y) + 0.6
		var holder := Node3D.new()
		holder.name = "Ring_" + id
		holder.position = Vector3(p.x, y, p.y)
		var dir := ShellStore.direction_at_t(shell, t)
		var yaw := atan2(dir.x, dir.y)
		holder.rotation = Vector3(0.0, yaw, 0.0)
		holder.set_meta("divider", id)
		rings_root.add_child(holder)
		var torus := TorusMesh.new()
		torus.inner_radius = width_m * 0.5 + 0.45
		torus.outer_radius = width_m * 0.5 + 0.62
		torus.rings = 40
		torus.ring_segments = 6
		var mi := MeshInstance3D.new()
		mi.name = "Torus"
		mi.mesh = torus
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		var mat := StandardMaterial3D.new()
		var col: Color = RING_COLORS.get(id, Color("#F0B95A"))
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.7
		mi.material_override = mat
		holder.add_child(mi)
		var label := Label3D.new()
		label.name = "Label"
		label.text = "%s  t=%d" % [String(d.get("display_name", id)), t]
		label.font_size = 40
		label.pixel_size = 0.009
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = false
		label.outline_size = 8
		label.modulate = Color(col.r, col.g, col.b, 0.95)
		label.position = Vector3(0.0, 1.5, 0.0)
		holder.add_child(label)


# ===========================================================================
# 石台锚点
# ===========================================================================
func _build_platforms() -> void:
	for c in platforms_root.get_children():
		c.queue_free()
	for p in ShellStore.platforms(shell):
		var pd: Dictionary = p
		var idx := int(pd.get("index", 0))
		var active := true
		if not preview_layout.is_empty():
			active = ShellStore.is_active(preview_layout, idx)
		var node := _make_platform_node(pd, active)
		node.name = "P%d" % idx
		node.set_meta("platform_index", idx)
		platforms_root.add_child(node)
	if selected_platform >= 0:
		_mark_platform(selected_platform)


func _make_platform_node(pd: Dictionary, active: bool) -> Node3D:
	var idx := int(pd.get("index", 0))
	var role := String(pd.get("role", "build"))
	var side := String(pd.get("side", "player"))
	var radius := float(pd.get("radius", 2.0))
	var base_h := float(pd.get("base_h", ShellStore.BASE_H))
	var ty := float(pd.get("terrain_y", 0.0))
	var holder := Node3D.new()
	holder.position = Vector3(float(pd.get("x", 0.0)), ty, float(pd.get("z", 0.0)))
	holder.rotation = Vector3(0.0, deg_to_rad(float(pd.get("yaw", 0.0))), 0.0)
	var accent := Color("#4EA1FF") if side == "player" else Color("#FF6E6E")
	if role == "keep":
		accent = Color("#F0B95A")
	if not active:
		accent = Color("#6E7480")
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color("#3A4150") if active else Color("#2B3038")
	stone.roughness = 0.9
	var top_mat := StandardMaterial3D.new()
	top_mat.albedo_color = accent.darkened(0.55) if active else Color("#343941")
	top_mat.roughness = 0.8
	if not active:
		_build_ruin(holder, radius, stone)
		return holder
	var pillar := CylinderMesh.new()
	pillar.top_radius = radius * 0.82
	pillar.bottom_radius = radius * 0.9
	pillar.height = maxf(base_h, 0.4)
	pillar.radial_segments = 24
	var pmi := MeshInstance3D.new()
	pmi.name = "Pillar"
	pmi.mesh = pillar
	pmi.position = Vector3(0.0, base_h * 0.5, 0.0)
	pmi.material_override = stone
	holder.add_child(pmi)
	var top := CylinderMesh.new()
	top.top_radius = radius
	top.bottom_radius = radius * 0.96
	top.height = 0.3
	top.radial_segments = 28
	var tmi := MeshInstance3D.new()
	tmi.name = "Top"
	tmi.mesh = top
	tmi.position = Vector3(0.0, base_h + 0.15, 0.0)
	tmi.material_override = top_mat
	holder.add_child(tmi)
	if role == "keep":
		var ring := TorusMesh.new()
		ring.inner_radius = radius * 0.66
		ring.outer_radius = radius * 0.74
		ring.rings = 36
		ring.ring_segments = 6
		var rmi := MeshInstance3D.new()
		rmi.name = "KeepRing"
		rmi.mesh = ring
		rmi.position = Vector3(0.0, base_h + 0.32, 0.0)
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = Color("#F0B95A")
		rmat.emission_enabled = true
		rmat.emission = Color("#F0B95A")
		rmat.emission_energy_multiplier = 0.45
		rmi.material_override = rmat
		holder.add_child(rmi)
	var label := Label3D.new()
	label.name = "Label"
	label.text = str(idx)
	label.font_size = 64
	label.pixel_size = 0.013
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.outline_size = 10
	label.modulate = Color(1.0, 1.0, 1.0, 0.96) if active else Color(0.55, 0.6, 0.7, 0.9)
	label.position = Vector3(0.0, base_h + 1.15, 0.0)
	holder.add_child(label)
	return holder


func _build_ruin(holder: Node3D, radius: float, stone: StandardMaterial3D) -> void:
	var pieces := 5
	for i in pieces:
		var box := BoxMesh.new()
		var s := radius * (0.28 + 0.08 * float(i % 3))
		box.size = Vector3(s * 1.6, s * 0.7, s * 1.2)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		var ang := float(i) / float(pieces) * TAU
		mi.position = Vector3(cos(ang) * radius * 0.42, 0.12, sin(ang) * radius * 0.42)
		mi.rotation = Vector3(0.0, ang, 0.12 * float(i - 2))
		mi.material_override = stone
		holder.add_child(mi)
	var label := Label3D.new()
	label.name = "Label"
	label.text = str(int(holder.get_meta("platform_index", 0)))
	label.font_size = 40
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.55, 0.6, 0.7, 0.8)
	label.position = Vector3(0.0, 1.0, 0.0)
	holder.add_child(label)


func _mark_platform(index: int) -> void:
	var node := platforms_root.get_node_or_null("P%d" % index)
	if node == null:
		return
	var marker := node.get_node_or_null("Marker")
	if marker != null:
		return
	var m := TorusMesh.new()
	var pd := ShellStore.platform_by_index(shell, index)
	var r := float(pd.get("radius", 2.0)) + 0.5
	m.inner_radius = r
	m.outer_radius = r + 0.18
	m.rings = 40
	var mi := MeshInstance3D.new()
	mi.name = "Marker"
	mi.mesh = m
	mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#FFFFFF")
	mat.emission_enabled = true
	mat.emission = Color("#FFFFFF")
	mat.emission_energy_multiplier = 0.8
	mi.material_override = mat
	(node as Node3D).add_child(mi)


# ===========================================================================
# 纯视觉装饰
# ===========================================================================
func _build_decor() -> void:
	for c in decor_root.get_children():
		c.queue_free()
	var list: Array = shell.get("decorations", [])
	for i in list.size():
		var d: Dictionary = list[i]
		var node := _make_decor_node(d)
		node.name = "D%d" % i
		node.set_meta("decor_index", i)
		node.position = Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))
		node.rotation = Vector3(0.0, deg_to_rad(float(d.get("yaw", 0.0))), 0.0)
		node.scale = Vector3.ONE * float(d.get("scale", 1.0))
		decor_root.add_child(node)


func _make_decor_node(d: Dictionary) -> Node3D:
	var kind := String(d.get("kind", "tree"))
	var holder := Node3D.new()
	var tint: Color = ShellStore.DECOR_TINT.get(kind, Color("#8A7A56"))
	var body := StandardMaterial3D.new()
	body.albedo_color = tint
	body.roughness = 0.9
	var dark := StandardMaterial3D.new()
	dark.albedo_color = tint.darkened(0.35)
	dark.roughness = 0.95
	match kind:
		"tree":
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.18
			trunk.bottom_radius = 0.28
			trunk.height = 2.4
			trunk.radial_segments = 8
			var tmi := MeshInstance3D.new()
			tmi.mesh = trunk
			tmi.position = Vector3(0.0, 1.2, 0.0)
			tmi.material_override = dark
			holder.add_child(tmi)
			for i in 3:
				var ball := SphereMesh.new()
				ball.radius = 1.5 - float(i) * 0.3
				ball.height = ball.radius * 1.6
				var mi := MeshInstance3D.new()
				mi.mesh = ball
				mi.position = Vector3(0.0, 2.6 + float(i) * 0.7, 0.0)
				mi.material_override = body
				holder.add_child(mi)
		"rock":
			var ball2 := SphereMesh.new()
			ball2.radius = 1.1
			ball2.height = 1.2
			var mi2 := MeshInstance3D.new()
			mi2.mesh = ball2
			mi2.position = Vector3(0.0, 0.4, 0.0)
			mi2.rotation = Vector3(0.0, 0.4, 0.2)
			mi2.material_override = body
			holder.add_child(mi2)
		"fence":
			for i in 3:
				var post := BoxMesh.new()
				post.size = Vector3(0.16, 1.1, 0.16)
				var pmi := MeshInstance3D.new()
				pmi.mesh = post
				pmi.position = Vector3(-1.0 + float(i), 0.55, 0.0)
				pmi.material_override = dark
				holder.add_child(pmi)
			for j in 2:
				var rail := BoxMesh.new()
				rail.size = Vector3(2.2, 0.12, 0.1)
				var rmi := MeshInstance3D.new()
				rmi.mesh = rail
				rmi.position = Vector3(0.0, 0.45 + float(j) * 0.42, 0.0)
				rmi.material_override = body
				holder.add_child(rmi)
		"flag":
			var pole := CylinderMesh.new()
			pole.top_radius = 0.06
			pole.bottom_radius = 0.08
			pole.height = 3.0
			var pmi2 := MeshInstance3D.new()
			pmi2.mesh = pole
			pmi2.position = Vector3(0.0, 1.5, 0.0)
			pmi2.material_override = dark
			holder.add_child(pmi2)
			var cloth := QuadMesh.new()
			cloth.size = Vector2(1.2, 0.7)
			var cmi := MeshInstance3D.new()
			cmi.mesh = cloth
			cmi.position = Vector3(0.62, 2.6, 0.0)
			cmi.material_override = body
			holder.add_child(cmi)
		"stump":
			var st := CylinderMesh.new()
			st.top_radius = 0.36
			st.bottom_radius = 0.42
			st.height = 0.6
			var smi := MeshInstance3D.new()
			smi.mesh = st
			smi.position = Vector3(0.0, 0.3, 0.0)
			smi.material_override = body
			holder.add_child(smi)
		"crate":
			var box := BoxMesh.new()
			box.size = Vector3(0.8, 0.8, 0.8)
			var bmi := MeshInstance3D.new()
			bmi.mesh = box
			bmi.position = Vector3(0.0, 0.4, 0.0)
			bmi.material_override = body
			holder.add_child(bmi)
		_:
			var fallback := BoxMesh.new()
			fallback.size = Vector3(0.6, 0.6, 0.6)
			var fmi := MeshInstance3D.new()
			fmi.mesh = fallback
			fmi.position = Vector3(0.0, 0.3, 0.0)
			fmi.material_override = body
			holder.add_child(fmi)
	return holder


# ===========================================================================
# 相机
# ===========================================================================
func _update_camera() -> void:
	if camera == null:
		return
	var yaw := deg_to_rad(cam_yaw)
	var pitch := deg_to_rad(cam_pitch)
	var offset := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw)) * cam_dist
	camera.position = cam_target + offset
	camera.look_at(cam_target, Vector3.UP)


func set_camera(yaw: float, pitch: float, dist: float, target: Vector3) -> void:
	cam_yaw = yaw
	cam_pitch = clampf(pitch, -85.0, -8.0)
	cam_dist = clampf(dist, 12.0, 160.0)
	cam_target = target
	_update_camera()


func focus_selected() -> void:
	if selected_platform >= 0:
		var pd := ShellStore.platform_by_index(shell, selected_platform)
		if not pd.is_empty():
			cam_target = Vector3(float(pd.get("x", 0.0)), float(pd.get("terrain_y", 0.0)), float(pd.get("z", 0.0)))
			cam_dist = 26.0
			_update_camera()


func update_ambient() -> void:
	if world_env == null:
		return
	var amb: Dictionary = (shell.get("terrain", {}) as Dictionary).get("ambient", {})
	var env := world_env.environment
	env.ambient_light_color = Color(String(amb.get("tint", "#9FB6D8")))
	env.ambient_light_energy = float(amb.get("energy", 0.9))
	env.fog_density = float(amb.get("fog_density", 0.012))
	if sun != null:
		sun.rotation_degrees = Vector3(float(amb.get("sun_pitch", -46.0)), float(amb.get("sun_yaw", 132.0)), 0.0)


# ===========================================================================
# 输入
# ===========================================================================
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_last_mouse = pos
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = clampf(cam_dist - 3.5, 12.0, 160.0)
			_update_camera()
			return true
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = clampf(cam_dist + 3.5, 12.0, 160.0)
			_update_camera()
			return true
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_drag_orbit = true
			else:
				_drag_orbit = false
			return true
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag_pan = mb.pressed
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _on_left_down(pos)
			else:
				return _on_left_up()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag_orbit:
			cam_yaw -= mm.relative.x * 0.4
			cam_pitch = clampf(cam_pitch + mm.relative.y * 0.3, -85.0, -8.0)
			_update_camera()
			return true
		if _drag_pan:
			var right := camera.global_transform.basis.x
			var fwd := -camera.global_transform.basis.z
			fwd.y = 0.0
			fwd = fwd.normalized()
			var scale := cam_dist * 0.0016
			cam_target -= right * mm.relative.x * scale
			cam_target -= fwd * mm.relative.y * scale
			_update_camera()
			return true
		_last_mouse = pos
		var g := ground_at(pos)
		_hover_ground = g
		_hover_valid = true
		if _painting and tool == TOOL_TERRAIN:
			_paint_ground = g
		return false
	elif event is InputEventKey:
		return false
	return false


var _drag_orbit := false
var _drag_pan := false


func _on_left_down(pos: Vector2) -> bool:
	var g := ground_at(pos)
	if tool == TOOL_TERRAIN:
		_painting = true
		_paint_ground = g
		_paint_height = ShellStore.height_at_shell(shell, heights, g.x, g.z)
		_apply_brush(g, 1.0)
		return true
	if tool == TOOL_DECOR:
		var hit := pick_decor(pos)
		if hit >= 0:
			selected_decor = hit
			picked.emit("decor", hit)
			return true
		add_decor(g, decor_kind)
		return true
	if tool == TOOL_PLATFORM:
		var phit := pick_platform(pos)
		if phit >= 0:
			selected_platform = phit
			_mark_platform(phit)
			picked.emit("platform", phit)
			return true
		add_platform(g)
		return true
	if tool == TOOL_SPINE:
		var dhit := pick_divider(pos)
		if not dhit.is_empty():
			selected_divider = String(dhit.get("id", ""))
			picked.emit("divider", 0)
			return true
		var sh := pick_spine_point(pos)
		if sh >= 0:
			selected_point = sh
			picked.emit("point", sh)
			return true
	return false


func _on_left_up() -> bool:
	if _painting:
		_painting = false
		changed.emit()
		return true
	return false


func _process(delta: float) -> void:
	if _painting and tool == TOOL_TERRAIN and _hover_valid:
		_paint_accum += delta
		if _paint_accum >= 0.04:
			_paint_accum = 0.0
			_apply_brush(_paint_ground, 1.0)
	if _drag_pan or _drag_orbit:
		return
	if _painting:
		return


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
	var c0 := int(clampf(floor((center.x - brush_radius - ox) / cell), 0.0, float(cols - 1)))
	var c1 := int(clampf(ceil((center.x + brush_radius - ox) / cell), 0.0, float(cols - 1)))
	var r0 := int(clampf(floor((center.z - brush_radius - oz) / cell), 0.0, float(rows - 1)))
	var r1 := int(clampf(ceil((center.z + brush_radius - oz) / cell), 0.0, float(rows - 1)))
	var touched := false
	for row in range(r0, r1 + 1):
		for col in range(c0, c1 + 1):
			var wx := ox + float(col) * cell
			var wz := oz + float(row) * cell
			var d := Vector2(wx - center.x, wz - center.z).length()
			if d > brush_radius:
				continue
			var fall := pow(1.0 - d / maxf(brush_radius, 0.001), 1.6)
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
		brushed.emit()


func heights_to_array() -> Array:
	var out: Array = []
	out.resize(heights.size())
	for i in heights.size():
		out[i] = snappedf(heights[i], 0.001)
	return out


# ===========================================================================
# 编辑：装饰
# ===========================================================================
func add_decor(g: Vector3, kind: String) -> void:
	var list: Array = shell.get("decorations", [])
	list.append({
		"kind": kind,
		"asset": kind,
		"x": snappedf(g.x, 0.01),
		"z": snappedf(g.z, 0.01),
		"y": snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001),
		"yaw": 0.0,
		"scale": 1.0,
	})
	shell["decorations"] = list
	selected_decor = list.size() - 1
	_build_decor()
	changed.emit()
	picked.emit("decor", selected_decor)


func move_decor(index: int, g: Vector3) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	var d: Dictionary = list[index]
	d["x"] = snappedf(g.x, 0.01)
	d["z"] = snappedf(g.z, 0.01)
	d["y"] = snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001)
	_build_decor()
	changed.emit()


func rotate_decor(index: int, deg: float) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	var d: Dictionary = list[index]
	d["yaw"] = fmod(float(d.get("yaw", 0.0)) + deg + 360.0, 360.0)
	_build_decor()
	changed.emit()


func scale_decor(index: int, mul: float) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	var d: Dictionary = list[index]
	d["scale"] = clampf(float(d.get("scale", 1.0)) * mul, 0.4, 3.0)
	_build_decor()
	changed.emit()


func remove_decor(index: int) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	list.remove_at(index)
	selected_decor = -1
	_build_decor()
	changed.emit()


# ===========================================================================
# 编辑：石台
# ===========================================================================
func add_platform(g: Vector3) -> void:
	var list: Array = shell.get("platforms", [])
	var idx := ShellStore.next_index(shell)
	var side := ShellStore.side_of(g.x)
	var pd := {
		"index": idx,
		"side": side,
		"role": "build",
		"x": snappedf(g.x, 0.05),
		"z": snappedf(g.z, 0.05),
		"radius": 2.0,
		"base_h": ShellStore.BASE_H,
		"terrain_y": snappedf(ShellStore.height_at_shell(shell, heights, g.x, g.z), 0.001),
		"yaw": 0.0,
	}
	list.append(pd)
	shell["platforms"] = list
	selected_platform = idx
	_build_platforms()
	changed.emit()
	picked.emit("platform", idx)


func move_platform(index: int, g: Vector3) -> void:
	var pd := ShellStore.platform_by_index(shell, index)
	if pd.is_empty():
		return
	pd["x"] = snappedf(g.x, 0.05)
	pd["z"] = snappedf(g.z, 0.05)
	pd["side"] = ShellStore.side_of(float(pd["x"]))
	pd["terrain_y"] = snappedf(ShellStore.height_at_shell(shell, heights, float(pd["x"]), float(pd["z"])), 0.001)
	_build_platforms()
	changed.emit()


func snap_platforms() -> void:
	for pd in (shell.get("platforms", []) as Array):
		var d: Dictionary = pd
		d["terrain_y"] = snappedf(ShellStore.height_at_shell(shell, heights, float(d.get("x", 0.0)), float(d.get("z", 0.0))), 0.001)
	_build_platforms()
	changed.emit()


func set_platform_role(index: int, role: String) -> void:
	var pd := ShellStore.platform_by_index(shell, index)
	if pd.is_empty():
		return
	pd["role"] = role
	_build_platforms()
	changed.emit()


func set_platform_radius(index: int, radius: float) -> void:
	var pd := ShellStore.platform_by_index(shell, index)
	if pd.is_empty():
		return
	pd["radius"] = clampf(radius, 1.0, 6.0)
	_build_platforms()
	changed.emit()


func set_platform_base(index: int, base_h: float) -> void:
	var pd := ShellStore.platform_by_index(shell, index)
	if pd.is_empty():
		return
	pd["base_h"] = clampf(base_h, 0.4, 4.0)
	_build_platforms()
	changed.emit()


func remove_platform(index: int) -> void:
	var list: Array = shell.get("platforms", [])
	for i in range(list.size() - 1, -1, -1):
		if int((list[i] as Dictionary).get("index", -1)) == index:
			list.remove_at(i)
	selected_platform = -1
	_build_platforms()
	changed.emit()


func renumber_platforms() -> void:
	var list: Array = shell.get("platforms", [])
	list.sort_custom(func(a, b): return float(a.get("x", 0.0)) < float(b.get("x", 0.0)))
	for i in list.size():
		(list[i] as Dictionary)["index"] = i + 1
	selected_platform = -1
	_build_platforms()
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
	_build_rings()
	changed.emit()


func set_divider_t(id: String, t: int) -> void:
	ShellStore.set_divider_t(shell, id, t)
	_build_rings()
	changed.emit()


func move_spine_point(index: int, g: Vector3) -> void:
	var pts: Array = (shell.get("spine", {}) as Dictionary).get("points", [])
	if index < 0 or index >= pts.size():
		return
	var p: Dictionary = pts[index]
	p["x"] = snappedf(g.x, 0.05)
	p["z"] = snappedf(g.z, 0.05)
	_build_ribbon()
	_build_rings()
	changed.emit()


func add_spine_point() -> void:
	var spine: Dictionary = shell.get("spine", {})
	var pts: Array = spine.get("points", [])
	if pts.size() < 2:
		return
	var a: Dictionary = pts[pts.size() - 2]
	var b: Dictionary = pts[pts.size() - 1]
	pts.insert(pts.size() - 1, {"x": (float(a.get("x", 0.0)) + float(b.get("x", 0.0))) * 0.5,
		"z": (float(a.get("z", 0.0)) + float(b.get("z", 0.0))) * 0.5})
	spine["points"] = pts
	shell["spine"] = spine
	_build_ribbon()
	_build_rings()
	changed.emit()


func remove_spine_point() -> void:
	var spine: Dictionary = shell.get("spine", {})
	var pts: Array = spine.get("points", [])
	if pts.size() <= 2:
		return
	pts.remove_at(pts.size() - 1)
	spine["points"] = pts
	shell["spine"] = spine
	_build_ribbon()
	_build_rings()
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


func pick_platform(pos: Vector2) -> int:
	var best := -1
	var best_d := 34.0
	for p in ShellStore.platforms(shell):
		var pd: Dictionary = p
		var y := float(pd.get("terrain_y", 0.0)) + float(pd.get("base_h", 0.0))
		var wp := Vector3(float(pd.get("x", 0.0)), y, float(pd.get("z", 0.0)))
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var d := sp.distance_to(pos)
		if d < best_d:
			best_d = d
			best = int(pd.get("index", -1))
	return best


func pick_decor(pos: Vector2) -> int:
	var best := -1
	var best_d := 26.0
	var list: Array = shell.get("decorations", [])
	for i in list.size():
		var d: Dictionary = list[i]
		var wp := Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)) + 1.0, float(d.get("z", 0.0)))
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dist := sp.distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = i
	return best


func pick_divider(pos: Vector2) -> Dictionary:
	var best := {}
	var best_d := 36.0
	for id in ShellStore.DIVIDER_IDS:
		var d: Dictionary = ShellStore.divider(shell, id)
		if d.is_empty():
			continue
		var t := int(d.get("t", 0))
		var p := ShellStore.point_at_t(shell, t)
		var wp := Vector3(p.x, ShellStore.height_at(shell, p.x, p.y) + 0.6, p.y)
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dist := sp.distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = {"id": id, "t": t}
	return best


func pick_spine_point(pos: Vector2) -> int:
	var pts: Array = (shell.get("spine", {}) as Dictionary).get("points", [])
	var best := -1
	var best_d := 28.0
	for i in pts.size():
		var p: Dictionary = pts[i]
		var wp := Vector3(float(p.get("x", 0.0)), ShellStore.height_at(shell, float(p.get("x", 0.0)), float(p.get("z", 0.0))) + 0.5, float(p.get("z", 0.0)))
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dist := sp.distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = i
	return best


## 拖拽：选中石台/装饰/脊线控制点后，鼠标位移直接改数据。
func drag_to(g: Vector3) -> void:
	if tool == TOOL_PLATFORM and selected_platform >= 0:
		move_platform(selected_platform, g)
	elif tool == TOOL_DECOR and selected_decor >= 0:
		move_decor(selected_decor, g)
	elif tool == TOOL_SPINE and selected_point >= 0:
		move_spine_point(selected_point, g)


func select_platform(index: int) -> void:
	selected_platform = index
	_build_platforms()


func set_decor_scale(index: int, value: float) -> void:
	var list: Array = shell.get("decorations", [])
	if index < 0 or index >= list.size():
		return
	(list[index] as Dictionary)["scale"] = clampf(value, 0.4, 3.0)
	_build_decor()
	changed.emit()


func hover_info() -> Dictionary:
	return {"valid": _hover_valid, "x": _hover_ground.x, "z": _hover_ground.z, "y": _hover_ground.y}


func is_dragging() -> bool:
	if tool == TOOL_PLATFORM and selected_platform >= 0:
		return true
	if tool == TOOL_DECOR and selected_decor >= 0:
		return true
	if tool == TOOL_SPINE and selected_point >= 0:
		return true
	return false
