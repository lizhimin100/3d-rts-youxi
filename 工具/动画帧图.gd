extends SceneTree
## **动作帧图（引擎内）**：把一个 GLB 的某个动作铺成 N 格，用眼睛数挥了几刀。
##
## 为什么要有它：离线数刀数以前走 Blender（工具/渲染动作帧.py），但 Blender 里没有
## 本工程的卡通材质与队伍色，渲出来是灰模。引擎里渲的是**玩家真正看到的那一版**。
##
## 跑法（要窗口；--headless 不出帧）：
##   godot --path . --resolution 900x600 --script 工具/动画帧图.gd -- --anim-sheet=out.png:attack:9
##   （out.png 相对工程根；第三段是帧数）

const 模型 := "res://美术/模型/方块人/方块人_联盟步兵.glb"

var _root: Node3D = null
var _cam: Camera3D = null


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var out := "_qa/anim_sheet.png"
	var clip := "attack"
	var n := 9
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--anim-sheet="):
			var parts := a.substr(String("--anim-sheet=").length()).split(":")
			if parts.size() > 0 and not String(parts[0]).is_empty():
				out = String(parts[0])
			if parts.size() > 1:
				clip = String(parts[1])
			if parts.size() > 2:
				n = int(parts[2])
	var ps := load(模型) as PackedScene
	if ps == null:
		print("SHEETERR 模型加载失败")
		quit(1)
		return
	_root = Node3D.new()
	_root.name = "帧图根"
	get_root().add_child(_root)
	var inst := ps.instantiate() as Node3D
	_root.add_child(inst)
	# 三点光：主光暖白、补光冷蓝、顶光弱 —— 和游戏里单位的照明一致，看刀口不吃亏
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 34, 0)
	sun.light_energy = 1.5
	sun.light_color = Color(1.0, 0.95, 0.86)
	_root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-12, -140, 0)
	fill.light_energy = 0.55
	fill.light_color = Color(0.68, 0.78, 1.0)
	_root.add_child(fill)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.17, 0.20)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.42, 0.45, 0.52)
	e.ambient_light_energy = 0.85
	env.environment = e
	_root.add_child(env)
	_cam = Camera3D.new()
	_cam.fov = 40.0
	_root.add_child(_cam)
	# ★ 站在**正面右前方**（模型朝 -Z，所以相机在 -Z 侧）：从背后看挥砍，
	#   剑会被身体挡住，只能看见"手抬起来又放下"，根本数不清几刀。
	_cam.global_position = Vector3(1.75, 1.30, -2.55)
	_cam.look_at(Vector3(0.0, 0.92, 0.0), Vector3.UP)
	_cam.current = true
	var ap := _find_ap(inst)
	if ap == null:
		print("SHEETERR 没有 AnimationPlayer")
		quit(1)
		return
	if not ap.has_animation(clip):
		print("SHEETERR 没有动作 ", clip)
		quit(1)
		return
	var anim := ap.get_animation(clip)
	var dur := anim.length
	# 逐帧：直接 seek 到第 i 帧（不靠实时播放，慢机器也不会掉帧）
	var shots: Array[Image] = []
	for i in n:
		var t := dur * float(i) / float(maxi(n - 1, 1))
		ap.play(clip)
		ap.seek(t, true)
		ap.pause()
		await process_frame
		await RenderingServer.frame_post_draw
		var img := get_root().get_texture().get_image()
		if img == null:
			print("SHEETERR 取帧失败")
			quit(1)
			return
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		shots.append(img)
	var cell := Vector2i(shots[0].get_width(), shots[0].get_height())
	var cols := mini(n, 5)
	var rows := int(ceil(float(n) / float(cols)))
	var sheet := Image.create(cell.x * cols, cell.y * rows, false, Image.FORMAT_RGBA8)
	for i in shots.size():
		var cx := (i % cols) * cell.x
		var cy := (i / cols) * cell.y
		sheet.blit_rect(shots[i], Rect2i(Vector2i.ZERO, cell), Vector2i(cx, cy))
	var abs_path := ProjectSettings.globalize_path("res://" + out) if not out.begins_with("/") else out
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := sheet.save_png(abs_path)
	print("ANIMSHEET %s clip=%s dur=%.2f frames=%d err=%d" % ["OK" if err == OK else "FAIL", clip, dur, n, err])
	quit(0)


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null

