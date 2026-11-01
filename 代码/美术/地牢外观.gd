class_name RtsDungeonVisual
extends RefCounted
## **地牢外观**：用现成的自然物资产拼一个"豺狼人巢穴"。
##
## 为什么不是一个新的 glb：地牢是"洞口 + 营地"的组合体，
## 而工程里已有 岩石 / 帐篷 / 营火 / 尸骨 / 断墙 这一整套**同一美术语言**的资产
## （全部走 自然材质库，颜色从调色板来）。用它们拼，比再造一个模型更快、
## 也不会引入第二套材质口径。
##
## 结构（俯视，+Z 是"正面/门口"）：
##   ┌────────────────────────────┐
##   │   岩石 岩石 岩石  ← 洞口的黑腔 │
##   │  断墙            帐篷          │
##   │        营火          尸骨      │
##   └────────────────────────────┘
##
## 三条纪律：
##   1. 所有部件都走 `ArtKit.build_model()`（自带缓存 + 自然材质 + 接触阴影不进这里）；
##   2. **不缩放父节点**：每个部件单独给 scale，方便以后微调；
##   3. 营火那盏 OmniLight 是"夜里能看见野怪营地"的关键，别删。

const ROCK := "res://美术/模型/岩石.glb"
const TENT := "res://美术/模型/帐篷.glb"
const CAMPFIRE := "res://美术/模型/营火.glb"
const BONES := "res://美术/模型/尸骨.glb"
const WALL := "res://美术/模型/断墙.glb"


static func build(def: UnitDef) -> Node3D:
	var root := Node3D.new()
	root.name = "地牢模型"

	# --- 洞口：三块大岩 + 里面一块近黑的"腔体" ---
	_part(root, ROCK, Vector3(-2.1, 0.0, -0.9), deg_to_rad(24.0), 1.45)
	_part(root, ROCK, Vector3(2.0, 0.0, -1.1), deg_to_rad(-38.0), 1.6)
	_part(root, ROCK, Vector3(0.2, 0.0, -2.3), deg_to_rad(96.0), 1.9)
	# 腔体：一块**竖直的暗面片**（不是盒子）。
	# ★ 用盒子会在俯视角露出"顶面"，画面里就是一块悬空的黑色矩形（第一版就长这样）；
	#   竖直面片只有一个面朝外，从任何角度都只看到"洞里的黑"，不会穿帮。
	var cavity := MeshInstance3D.new()
	cavity.name = "洞腔"
	var pm := PlaneMesh.new()
	pm.size = Vector2(3.6, 2.6)
	cavity.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.028, 0.024, 0.022)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	cavity.material_override = mat
	cavity.rotation = Vector3(deg_to_rad(-90.0), 0.0, 0.0)
	cavity.position = Vector3(0.0, 1.3, -1.1)
	root.add_child(cavity)

	# --- 营地：帐篷 + 断墙 + 营火 + 散落尸骨 ---
	_part(root, TENT, Vector3(2.8, 0.0, 1.1), deg_to_rad(-28.0), 1.15)
	_part(root, WALL, Vector3(-2.9, 0.0, 1.0), deg_to_rad(72.0), 1.0)
	_part(root, CAMPFIRE, Vector3(0.9, 0.0, 2.2), deg_to_rad(14.0), 1.15)
	_part(root, BONES, Vector3(-1.5, 0.0, 2.5), deg_to_rad(-52.0), 1.0)
	_part(root, BONES, Vector3(2.4, 0.0, 2.9), deg_to_rad(118.0), 0.85)

	# 营火的光：野怪营地夜里必须能被一眼看见（这也解释了"怪是从哪来的"）
	var lamp := OmniLight3D.new()
	lamp.name = "营火光"
	lamp.light_color = Color(1.0, 0.58, 0.24)
	lamp.light_energy = 2.2
	lamp.omni_range = 9.0
	lamp.omni_attenuation = 1.6
	lamp.position = Vector3(0.9, 0.9, 2.2)
	lamp.shadow_enabled = false
	root.add_child(lamp)

	# 地牢比普通建筑大：整棵按占地微缩一点，避免石头压到隔壁格子
	var f: Vector2i = def.footprint if def != null else Vector2i(5, 5)
	var span: float = float(maxi(maxi(f.x, f.y), 1))
	root.scale = Vector3.ONE * clampf(span / 5.0, 0.85, 1.35)
	return root


static func _part(root: Node3D, path: String, pos: Vector3, yaw: float, s: float) -> void:
	var n: Node3D = ArtKit.build_model(path, 1.0, Vector3(2.0, 1.5, 2.0))
	if n == null:
		return
	n.position = pos
	n.rotation.y = yaw
	n.scale = Vector3.ONE * s
	# 自然物全部投影：营地要"落在地上"，否则像浮贴
	for c in n.get_children():
		_set_shadow(c)
	root.add_child(n)


static func _set_shadow(n: Node) -> void:
	var mi := n as GeometryInstance3D
	if mi != null:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for c in n.get_children():
		_set_shadow(c)
