extends SceneTree
## **技能图标渲染器** —— 出 `_qa/图标原图_技能/<id>.png`（512²，透明底）。
##
## 为什么在引擎里搭几何体渲，而不是画 2D 或去 Blender：
##   单位/建筑图标是引擎渲的（卡通材质 + 三点光 + 暖底），技能图标要和它们一家人；
##   拿 Blender 渲会变成另一套光影（农民那张实测整只发灰）。
## 这里用最简单的 Box/Cylinder/Sphere + 本工程调色板色，摆成道具特写。
##
## 运行（不能加 --headless，dummy 渲染器抓不到画面）：
##   godot --path . --resolution 480x320 --script 工具/渲染技能图标.gd
## 之后跑 python 工具/合成技能图标.py 贴底版（和单位图标同一张底板）。

const RAW_DIR := "res://_qa/图标原图_技能/"
const SIZE := 512
const FILL := 0.70

const STEEL := Color(0.62, 0.64, 0.68)
const STEEL_DARK := Color(0.33, 0.35, 0.40)
const CLOTH := Color(0.17, 0.37, 0.69)
const WOOD := Color(0.42, 0.30, 0.18)
const WOOD_LIGHT := Color(0.55, 0.41, 0.25)
const GOLD := Color(0.88, 0.68, 0.26)
const FIRE := Color(1.0, 0.42, 0.10)
const FIRE_CORE := Color(1.0, 0.86, 0.42)
const LEATHER := Color(0.34, 0.24, 0.16)

var _ids: Array[String] = ["shield_up", "triple_shot", "fireball", "chop_wood", "mine_gold"]
var _i: int = -1
var _vp: SubViewport = null
var _wait: int = 0
var _done: bool = false


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RAW_DIR))
	print("========== 渲染技能图标 ==========")
	call_deferred("_next")


func _process(_delta: float) -> bool:
	if _done:
		return true
	if _vp == null:
		return false
	_wait += 1
	if _wait < 6:
		return false
	var img: Image = _vp.get_texture().get_image()
	if img != null and not img.is_empty():
		var path := RAW_DIR + _ids[_i] + ".png"
		var err := img.save_png(ProjectSettings.globalize_path(path))
		print("  · %s -> %s err=%d" % [_ids[_i], path, err])
	_next()
	return false


func _next() -> void:
	if _vp != null:
		_vp.queue_free()
		_vp = null
	_i += 1
	if _i >= _ids.size():
		_done = true
		print("========== 完成 %d 个 ==========" % _ids.size())
		quit()
		return
	_wait = 0
	_build(_ids[_i])


func _build(id: String) -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_vp)
	var stage := Node3D.new()
	_vp.add_child(stage)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.34, 0.44)
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	_key(stage, Vector3(-0.7, -1.0, -0.6), Color(1.0, 0.90, 0.76), 1.5)
	_key(stage, Vector3(0.9, -0.6, -0.5), Color(0.58, 0.72, 1.0), 0.55)
	_key(stage, Vector3(0.2, 0.6, 1.0), Color(1.0, 0.96, 0.88), 0.9)
	var prop := Node3D.new()
	stage.add_child(prop)
	match id:
		"shield_up": _prop_shield(prop)
		"triple_shot": _prop_bolts(prop)
		"fireball": _prop_fireball(prop)
		"chop_wood": _prop_axe(prop)
		"mine_gold": _prop_pick(prop)
		_: _prop_shield(prop)
	var box := _aabb(stage)
	var h: float = maxf(box.size.y, 0.3)
	var cam := Camera3D.new()
	cam.fov = 34.0
	stage.add_child(cam)
	# ★ 对焦到包围盒**中心**（三轴），而不是 (0, cy, 0)：
	#   道具不是都摆在原点的（盾偏左、镐偏右），按原点对焦会半张脸出画。
	var span: float = maxf(box.size.y, maxf(box.size.x, box.size.z))
	var dist: float = (span * 0.5 / FILL) / tan(deg_to_rad(cam.fov * 0.5))
	var yaw := deg_to_rad(32.0)
	var pitch := deg_to_rad(14.0)
	var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var target := box.get_center()
	cam.position = target + dir * dist
	cam.look_at(target, Vector3.UP)
	cam.current = true
	print("  · 渲染 %s（尺寸 %.2f，机位 %.2f）" % [id, h, dist])


# ===========================================================================
# 道具（都用最简单的体素块摆，风格和方块人一致）
# ===========================================================================

func _prop_shield(p: Node3D) -> void:
	# 盾：钢边 + 蓝布盾面 + 金盾心 + 背后的剑。盾牌是主角，占满画面。
	_box(p, Vector3(1.00, 1.26, 0.14), Vector3(0.0, 0.72, 0.08), STEEL_DARK)
	_box(p, Vector3(0.86, 1.12, 0.12), Vector3(0.0, 0.72, -0.02), CLOTH)
	_box(p, Vector3(0.20, 0.20, 0.10), Vector3(0.0, 0.78, -0.10), GOLD)
	_cyl(p, 0.13, 0.13, 0.10, Vector3(0.0, 0.78, -0.16), GOLD, Vector3(90.0, 0.0, 0.0))
	# 盾面十字束带
	_box(p, Vector3(0.10, 1.00, 0.05), Vector3(0.0, 0.72, -0.11), LEATHER)
	_box(p, Vector3(0.78, 0.10, 0.05), Vector3(0.0, 0.98, -0.11), LEATHER)
	# 底部收尖（用一块旋转 45 度的方块当楔子）
	_box(p, Vector3(0.46, 0.46, 0.12), Vector3(0.0, 0.16, -0.02), CLOTH).rotation_degrees = Vector3(0.0, 0.0, 45.0)
	_box(p, Vector3(0.10, 0.42, 0.06), Vector3(0.0, 1.40, 0.04), STEEL_DARK)
	# 背后的剑（斜 28 度，只露一半，读起来是"带剑的步兵"）
	# 剑在盾**后面**（z=+0.30），只从右上角露出来，不切盾面
	var sword := Node3D.new()
	p.add_child(sword)
	sword.rotation_degrees = Vector3(0.0, 0.0, 34.0)
	_box(sword, Vector3(0.11, 1.05, 0.06), Vector3(0.44, 1.05, 0.30), STEEL)
	_box(sword, Vector3(0.16, 0.10, 0.07), Vector3(0.44, 1.58, 0.30), STEEL)
	_box(sword, Vector3(0.40, 0.11, 0.10), Vector3(0.44, 0.62, 0.30), GOLD)
	_box(sword, Vector3(0.10, 0.30, 0.10), Vector3(0.44, 0.44, 0.30), LEATHER)


func _prop_bolts(p: Node3D) -> void:
	# 三支弩箭从同一点呈扇形张开（读法是"一次打三发"）
	# 三支箭立在画面里呈扇形：箭杆沿 +Y，箭头朝上，尾羽在下
	for k in 3:
		var b := Node3D.new()
		p.add_child(b)
		var t: float = float(k) - 1.0
		b.position = Vector3(t * 0.14, 0.0, -absf(t) * 0.05)
		b.rotation_degrees = Vector3(0.0, 0.0, t * 19.0)
		_box(b, Vector3(0.075, 1.30, 0.075), Vector3(0.0, 0.78, 0.0), WOOD_LIGHT)
		_box(b, Vector3(0.17, 0.34, 0.10), Vector3(0.0, 1.54, 0.0), STEEL)
		_box(b, Vector3(0.07, 0.16, 0.06), Vector3(0.0, 1.76, 0.0), STEEL_DARK)
		_box(b, Vector3(0.22, 0.03, 0.05), Vector3(0.0, 0.26, 0.0), CLOTH)
		_box(b, Vector3(0.03, 0.22, 0.05), Vector3(0.0, 0.26, 0.0), CLOTH)
		_box(b, Vector3(0.03, 0.22, 0.05), Vector3(0.0, 0.38, 0.0), CLOTH)
	# 底下横一支弩臂，提示这是弩不是弓箭
	_box(p, Vector3(1.05, 0.08, 0.12), Vector3(0.0, 0.02, 0.22), LEATHER)


func _prop_fireball(p: Node3D) -> void:
	# 火球：核心 + 外焰舌 + 底部余烬
	_sphere(p, 0.40, Vector3(0.0, 0.62, 0.0), FIRE, true)
	_sphere(p, 0.25, Vector3(0.0, 0.62, -0.18), FIRE_CORE, true)
	# 拖尾：球后面三颗越来越小、越来越暗的火珠（读法是"飞过来的火球"）
	for k in 3:
		var f: float = float(k)
		_sphere(p, 0.30 - f * 0.07, Vector3(0.0, 0.62 - f * 0.04, 0.42 + f * 0.34),
			Color(0.95, 0.35 - f * 0.06, 0.08), true)

	# 底部余烬
	for k in 3:
		var a2: float = TAU * float(k) / 3.0 + 0.4
		_box(p, Vector3(0.16, 0.07, 0.16), Vector3(cos(a2) * 0.26, 0.10, sin(a2) * 0.26),
			Color(0.40, 0.16, 0.06))


func _prop_axe(p: Node3D) -> void:
	# 斧头砍进树桩：斧是主角，桩只做基座
	_cyl(p, 0.40, 0.44, 0.62, Vector3(0.0, 0.31, 0.0), WOOD, Vector3.ZERO)
	_cyl(p, 0.40, 0.40, 0.05, Vector3(0.0, 0.63, 0.0), WOOD_LIGHT, Vector3.ZERO)
	var axe := Node3D.new()
	p.add_child(axe)
	axe.position = Vector3(0.0, 0.36, 0.0)
	axe.rotation_degrees = Vector3(0.0, 0.0, -20.0)
	_cyl(axe, 0.062, 0.062, 0.98, Vector3(0.0, 0.46, 0.0), WOOD_LIGHT, Vector3.ZERO)
	# 斧身：宽刃 + 下方的"胡子"（斧的标志性轮廓）
	_box(axe, Vector3(0.14, 0.30, 0.52), Vector3(0.0, 0.92, 0.0), STEEL)
	_box(axe, Vector3(0.11, 0.30, 0.18), Vector3(-0.01, 0.66, 0.26), STEEL)
	_box(axe, Vector3(0.11, 0.22, 0.14), Vector3(-0.01, 0.80, -0.30), STEEL_DARK)
	_box(axe, Vector3(0.19, 0.10, 0.18), Vector3(0.0, 1.06, 0.0), STEEL_DARK)
	# 木屑
	_box(p, Vector3(0.12, 0.05, 0.10), Vector3(0.42, 0.03, 0.22), WOOD_LIGHT)
	_box(p, Vector3(0.09, 0.04, 0.08), Vector3(0.58, 0.02, -0.10), WOOD_LIGHT)


func _prop_pick(p: Node3D) -> void:
	# 镐 + 金矿堆：镐斜靠在矿上
	_box(p, Vector3(0.72, 0.44, 0.62), Vector3(0.10, 0.22, 0.0), Color(0.29, 0.26, 0.23))
	_box(p, Vector3(0.34, 0.30, 0.30), Vector3(-0.20, 0.16, 0.16), Color(0.22, 0.20, 0.18))
	_box(p, Vector3(0.18, 0.16, 0.16), Vector3(0.26, 0.52, -0.06), GOLD)
	_box(p, Vector3(0.14, 0.13, 0.14), Vector3(0.00, 0.50, 0.16), GOLD)
	_box(p, Vector3(0.11, 0.10, 0.11), Vector3(0.40, 0.46, 0.12), GOLD)
	var pk := Node3D.new()
	p.add_child(pk)
	pk.position = Vector3(-0.12, 0.0, 0.0)
	pk.rotation_degrees = Vector3(0.0, 0.0, 16.0)
	_cyl(pk, 0.065, 0.065, 1.30, Vector3(0.0, 0.66, 0.0), WOOD_LIGHT, Vector3.ZERO)
	var hd := Node3D.new()
	pk.add_child(hd)
	hd.position = Vector3(0.0, 1.28, 0.0)
	hd.rotation_degrees = Vector3(0.0, 0.0, -14.0)
	_box(hd, Vector3(0.60, 0.14, 0.15), Vector3(0.0, 0.0, 0.0), STEEL)
	_box(hd, Vector3(0.26, 0.11, 0.12), Vector3(0.36, -0.10, 0.0), STEEL_DARK)
	_box(hd, Vector3(0.26, 0.11, 0.12), Vector3(-0.34, 0.10, 0.0), STEEL_DARK)
	_box(hd, Vector3(0.14, 0.20, 0.14), Vector3(0.0, -0.10, 0.0), STEEL_DARK)


# ===========================================================================
# 小工具
# ===========================================================================

func _mat(col: Color, emissive: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.62
	m.metallic = 0.25
	if emissive:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 3.0
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _box(p: Node3D, size: Vector3, at: Vector3, col: Color, emissive: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(col, emissive)
	mi.mesh = bm
	mi.position = at
	p.add_child(mi)
	return mi


func _cyl(p: Node3D, rt: float, rb: float, h: float, at: Vector3, col: Color, rot_deg: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = rt
	cm.bottom_radius = rb
	cm.height = h
	cm.radial_segments = 12
	cm.material = _mat(col)
	mi.mesh = cm
	mi.position = at
	mi.rotation_degrees = rot_deg
	p.add_child(mi)
	return mi


func _sphere(p: Node3D, r: float, at: Vector3, col: Color, emissive: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 24
	sm.rings = 12
	sm.material = _mat(col, emissive)
	mi.mesh = sm
	mi.position = at
	p.add_child(mi)
	return mi


func _key(parent: Node3D, dir: Vector3, col: Color, energy: float) -> void:
	var l := DirectionalLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.shadow_enabled = false
	parent.add_child(l)
	var target := Vector3(0.0, 0.6, 0.0)
	l.position = target + dir.normalized() * 10.0
	l.look_at(target, Vector3.UP)


func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		var mi := cur as MeshInstance3D
		if mi != null and mi.mesh != null:
			var b: AABB = mi.global_transform * mi.get_aabb()
			out = b if first else out.merge(b)
			first = false
		for c in cur.get_children():
			stack.append(c)
	return out

