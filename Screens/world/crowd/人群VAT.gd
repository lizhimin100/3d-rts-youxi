extends RefCounted
## **VAT 单位套件** —— 把 `Tools/烘焙VAT.gd` 的产物装成 "MultiMesh 能直接吃的 mesh + 材质"。
##
## 为什么单独一层：人群演示/以后的正式人群层都要"按名字拿一套单位"，
## 谁都不该知道纹理分行、帧数、shader uniform 叫什么。改烘焙布局只改这里和 shader。
##
## 产物约定（`Content/art/VAT/`，由烘焙脚本生成）：
##   <name>_mesh.res      合并后的 ArrayMesh（UV2.x=顶点序号、UV2.y=区域、COLOR=基色）
##   <name>_<clip>.res    ImageTexture（RGBAH，上半位置下半法线）
##   <name>.json          { fps, verts, tris, bbox, clips: { idle: {frames, seconds}, walk: {...} } }

const SHADER_PATH := "res://Screens/world/crowd/人群VAT.gdshader"
const DIR := "res://Content/art/VAT/"


## 有没有烘过这个单位
static func has(name: String) -> bool:
	return ResourceLoader.exists(DIR + name + "_mesh.res") \
		and ResourceLoader.exists(DIR + name + ".json")


## 组一套（缺 idle 或 walk 都返回空字典，调用方回退到胶囊/方块）
static func build(name: String) -> Dictionary:
	if not has(name):
		return {}
	var mesh: Mesh = load(DIR + name + "_mesh.res") as Mesh
	var meta: Dictionary = read_meta(name)
	var clips: Dictionary = meta.get("clips", {})
	if mesh == null or not clips.has("idle") or not clips.has("walk"):
		return {}
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH) as Shader
	if mat.shader == null:
		return {}
	var idle_tex: Texture2D = load(DIR + name + "_idle.res") as Texture2D
	var walk_tex: Texture2D = load(DIR + name + "_walk.res") as Texture2D
	if idle_tex == null or walk_tex == null:
		return {}
	mat.set_shader_parameter("vat_idle", idle_tex)
	mat.set_shader_parameter("vat_walk", walk_tex)
	mat.set_shader_parameter("idle_frames", float(clips["idle"].get("frames", 1)))
	mat.set_shader_parameter("idle_seconds", float(clips["idle"].get("seconds", 1.0)))
	mat.set_shader_parameter("walk_frames", float(clips["walk"].get("frames", 1)))
	mat.set_shader_parameter("walk_seconds", float(clips["walk"].get("seconds", 1.0)))
	return {
		"mesh": mesh,
		"material": mat,
		"meta": meta,
		# 模型原点在脚底（烘焙时把骨架变换换到了单位根），所以只留 3cm 贴地余量，
		# 和主线 `关卡桥.GROUND_LIFT` 一致。用 0.85（胶囊半身高）会整个人悬空。
		"y_offset": 0.03,
		"name": name,
	}


static func read_meta(name: String) -> Dictionary:
	var p := DIR + name + ".json"
	if not FileAccess.file_exists(p):
		return {}
	var txt := FileAccess.get_file_as_string(p)
	var j: Variant = JSON.parse_string(txt)
	return j as Dictionary if j is Dictionary else {}
