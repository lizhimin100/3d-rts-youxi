extends SceneTree
## **单位头像 / 图标的运行时渲染器** —— 出 `美术/图标/单位/<id>.png`（256²）。
##
## 为什么用引擎渲、而不是 Blender：
##   这几个单位走的是 `MatKit` 卡通 shader（材质名 `M_<zone>`，队伍色是 shader 参数），
##   Blender 里没有这套材质，渲出来是灰模（农民那张实测整张发灰）。
##   引擎渲 = **玩家真正看到的样子**：图集/卡通 shader/队伍色/描边一个不差。
##
## 做法：每个单位开一个 320² 的 SubViewport（自带世界 + 三点光），
##   把模型按 def.height 卡进画面，渲几帧后 `get_texture().get_image()` 存 PNG。
##
## 运行（**不能加 --headless**，headless 是 dummy 渲染器，抓不到画面）：
##   godot --path . --resolution 480x320 --script 工具/渲染单位头像.gd

const ICON_DIR := "res://美术/图标/单位/"
const SIZE := 320
const OUT := 256
## 画面填充率（0.86 = 上下各留 7% 呼吸位）
const FILL := 0.86

var _ids: Array[StringName] = [&"footman", &"peasant", &"archer", &"mage", &"steam_guard"]
var _i: int = -1   # _next() 里先 +1 再 build，所以从 -1 起
var _vp: SubViewport = null
var _wait: int = 0
var _done: bool = false


func _initialize() -> void:
	_ensure_dir()
	print("========== 渲染单位头像 ==========")
	# ★ 必须等一帧：_initialize() 里节点树还没真正跑起来，
	#   这时候 add_child 进去的相机/网格 `global_transform` 全是单位阵，
	#   机位会算错（表现为一堆 "Node not inside tree"）。
	call_deferred("_next")


func _ensure_dir() -> void:
	var d := DirAccess.open("res://美术/图标")
	if d == null:
		return
	if not d.dir_exists("单位"):
		d.make_dir("单位")


func _process(_delta: float) -> bool:
	if _done:
		return true
	if _vp == null:
		return false
	_wait += 1
	if _wait < 5:
		return false
	var img: Image = _vp.get_texture().get_image()
	if img != null and not img.is_empty():
		# 320 → 256（等比缩，Lanczos 级别的平滑）
		img.resize(OUT, OUT, Image.INTERPOLATE_LANCZOS)
		var path := ICON_DIR + String(_ids[_i]) + ".png"
		var err := img.save_png(path)
		print("  · %s → %s err=%d size=%s" % [String(_ids[_i]), path, err, str(img.get_size())])
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


func _build(id: StringName) -> void:
	# ★ --script 模式下自动加载单例的全局名还没注册，不能直接写 Cfg（见 界面自检 顶部注释）
	var cfg: Node = root.get_node_or_null("Cfg")
	var def: UnitDef = cfg.call("unit", id) if cfg != null else null
	if def == null:
		print("  !! 没有定义：", String(id))
		return
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.own_world_3d = true
	_vp.transparent_bg = false   # 图标要一块深色底（魔兽图标没有透明底的）
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_vp)

	var stage := Node3D.new()
	_vp.add_child(stage)

	# 环境（暗底 + 一点点环境光，和 UI 的深色段底同色系）
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.062, 0.078)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.28, 0.32, 0.42)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	# 三点光
	_key(stage, Vector3(-0.7, -1.0, -0.6), Color(1.0, 0.90, 0.76), 1.35)
	_key(stage, Vector3(0.9, -0.6, -0.5), Color(0.58, 0.72, 1.0), 0.45)
	_key(stage, Vector3(0.2, 0.6, 1.0), Color(1.0, 0.96, 0.88), 0.85)

	# 模型：和游戏里同一条路（ArtKit → 模型工厂 → 队伍色）
	var fallback := Vector3(def.body_radius * 2.0, def.height, def.body_radius * 2.0)
	var model: Node3D = ArtKit.build_model(def.model_path, def.model_scale, fallback)
	if model == null:
		print("  !! 模型加载失败：", String(id))
		return
	stage.add_child(model)
	ArtKit.apply_team_color(model, Color(0.24, 0.56, 1.0))

	# 等比缩放到目标高度 + 脚下贴 0
	var box := _aabb(model)
	if box.size.y > 0.01:
		var s: float = def.height / box.size.y
		# 只对"资产比例离谱"的情况动手，正常模型别缩
		if absf(s - 1.0) > 0.25:
			model.scale = Vector3.ONE * s
			box = _aabb(model)
	model.position -= Vector3(box.position.x, box.position.y, box.position.z)

	var cam := Camera3D.new()
	cam.fov = 38.0
	stage.add_child(cam)
	# 用**贴地后的真实包围盒**量身高：def.height 是逻辑值，和模型对不齐
	# （方块人 1.75 / 步兵逻辑 1.78 / 法师 1.80），拿逻辑值算距离会切头切脚。
	var box2 := _aabb(model)
	var h: float = maxf(box2.size.y, 0.6)
	var cy: float = box2.position.y + h * 0.5
	# 距离按"身高刚好填满 FILL"反解：fov 是竖直视角；0.94 是取景系数（略收紧，图标里人要大一点）
	var dist: float = (h * 0.5 / FILL) / tan(deg_to_rad(cam.fov * 0.5)) * 0.94
	# ★ 相机放在 **-Z 前方**：单位模型的正脸朝 -Z（和游戏里一致），
	#   之前放在 +Z 拍到的是后脑勺。
	var yaw := deg_to_rad(36.0)
	var pitch := deg_to_rad(10.0)
	var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var target := Vector3(0.0, cy, 0.0)
	cam.position = target + dir * dist
	cam.look_at(target, Vector3.UP)
	cam.current = true
	print("  · 渲染 %s（高 %.2fm，机位 %.2fm）" % [def.display_name, h, dist])


func _key(parent: Node3D, dir: Vector3, col: Color, energy: float) -> void:
	var l := DirectionalLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.shadow_enabled = false
	parent.add_child(l)
	var target := Vector3(0.0, 1.0, 0.0)
	l.position = target + dir.normalized() * 10.0
	l.look_at(target, Vector3.UP)


## 递归算模型的世界包围盒
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
