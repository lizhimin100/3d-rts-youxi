class_name 自然材质库
extends RefCounted
## **自然材质库**：给"文生 3D 那批自然物"（树 / 草 / 岩石 / 金矿 / 木桩 / 尸骨）套一层统一材质。
##
## ── 为什么必须有这一层 ──────────────────────────────────────────────
## 这批 GLB 的 albedo 贴图是**纯灰度噪声**（三通道完全相等，均值 0.78~0.88），
## glTF 里又没有 baseColorFactor（缺省白）—— 于是树、草、岩石在引擎里渲染成
## 同一种灰白。老板说"树顶那个颜色跟石头一模一样，一坨"，根因就在这里。
##
## 处理办法**不是重烘贴图**（慢且易崩），而是：
##   · 灰度贴图降级成**细节噪声**（StandardMaterial3D 的 albedo 是 albedo_color × albedo_texture）；
##   · 颜色从 `代码/美术/调色板.gd` 取（和建筑同一套色）；
##   · 光照参数和建筑同一套（StandardMaterial3D，哑光，无自发光）。
##
## ── 三条铁律（与建筑一致，别改） ────────────────────────────────────
##   1. 只用 StandardMaterial3D，**不挂任何 .gdshader**（建筑材质铁律）；
##   2. **不开 emission** —— 全场光逻辑只有一盏太阳 + 天光，开了就"发光"，掉出同一套光；
##   3. 颜色只从调色板取，本文件不另起一套色。
##
## ── 用法 ───────────────────────────────────────────────────────────
##   `自然材质库.apply(模型根节点)` —— 递归、幂等，可重复调；
##   材质按「语义 + 贴图 + 法线强度」缓存共享，140 棵树只占 5 份材质。
##
## 材质名故意带 `自然_` 前缀：ArtKit 的旧式染色（_walk_tint）看到它会跳过，
## MatKit 的 zone 换材质只认 `M_` 前缀也会跳过 —— 这套色不会被队伍色链路二次拉色。

## 资源名标记（见上：给 ArtKit / MatKit 的"别动我"信号）
const 标记 := "自然_"
const 调色板路径 := "res://美术/调色板/联盟调色板.tres"

## 语义 → 调色板 zone（颜色 / 粗糙度 / 金属度都从调色板取，缺省走默认）
const 语义色 := {
	"leaf_light": "leaf_light",
	"leaf": "leaf_olive",
	"leaf_dark": "leaf_deep",
	"grass": "grass",
	"bark": "bark",
	"bark_dark": "bark_dark",
	"rock": "rock",
	"rock_dark": "rock_dark",
	"wood": "wood",
	"wood_dark": "wood_dark",
	"bone": "bone",
	"canvas": "canvas",
	"canvas_dark": "canvas_dark",
	"gold": "gold",
	"gold_glow": "gold",
	"ore": "ore",
	"iron": "iron",
	"steel": "steel",
	"rope": "rope",
	"hay": "hay",
	"plaster": "plaster",
	"dirt": "dirt",
	"cavity": "cavity",
}

## 关键词 → 语义。**按长度倒序匹配**（leaf_light 不会被 leaf 抢），
## 同长度按本表先后（所以 gold* 必须排在 rock 前面，goldrock 不会被判成石头）。
const 关键词 := [
	["leaf_light", "leaf_light"],
	["leaf_dark", "leaf_dark"],
	["leaf", "leaf"],
	["foliage", "leaf"],
	["bark_dark", "bark_dark"],
	["bark", "bark"],
	["grass", "grass"],
	["gold_glow", "gold_glow"],
	["gold", "gold"],
	["ore", "ore"],
	["rock_dark", "rock_dark"],
	["rock", "rock"],
	["wood_dark", "wood_dark"],
	["wood", "wood"],
	["bone", "bone"],
	["canvas", "canvas"],
	["cloth", "canvas"],
	["tent", "canvas"],
	["iron", "iron"],
	["metal", "steel"],
	["steel", "steel"],
	["rope", "rope"],
	["hay", "hay"],
	["plaster", "plaster"],
	["dirt", "dirt"],
	["cavity", "cavity"],
]

## 少数语义要在调色板之外微调（金脉要"亮一下"，但仍不许 emission）
const 语义粗糙 := {"gold_glow": 0.26}
const 语义金属 := {"gold_glow": 0.70}

## 灰度贴图的亮度补偿：贴图均值 0.78~0.88，乘上来会整体压暗，
## 这里按 sRGB 幂律把它抬回"调色板原色"（1.14 ≈ 贴图 0.88，1.28 ≈ 贴图 0.78）。
const 补偿_叶 := 1.06
const 补偿_树皮 := 1.10
const 补偿_默认 := 1.08

## 树叶背光颜色（暖绿：太阳从叶背透过来，偏黄不偏青）
const 叶背光 := Color(0.50, 0.60, 0.26)
## 草的背光弱一档（草叶更薄，但一大片都"透亮"会显得假）
const 草背光 := Color(0.44, 0.54, 0.24)

static var _cache: Dictionary = {}
static var _调色板: RtsPalette = null
## 合并后的三张表（代码默认值打底 + .tres 覆盖），见 _取调色板()
static var _色表: Dictionary = {}
static var _粗表: Dictionary = {}
static var _金表: Dictionary = {}
static var _规则缓存: Array = []


# ===========================================================================
# 对外入口
# ===========================================================================

## 递归给整棵子树的 MeshInstance3D 套自然材质（**幂等**，重复调不会越包越厚）
static func apply(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	# 角色（有骨骼/动画）走的是 MatKit 卡通材质 + 队伍色链路，
	# 这里硬套会吃掉描边和顶点 AO，也把队伍色区一起冲掉 —— 直接放行。
	if _是角色(root):
		return
	for mi in _收集网格(root):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var 源: Material = mi.get_active_material(i)
			var 义 := 语义_of(_材质名(mi, 源, i))
			if 义.is_empty():
				continue
			var m := 取材质(义, 源)
			if m != null:
				mi.set_surface_override_material(i, m)


## 取一份（缓存共享的）自然材质。源材质只用来拿灰度 albedo / 法线，不会再被改动。
static func 取材质(语义: String, 源: Material = null) -> StandardMaterial3D:
	var alb: Texture2D = null
	var nrm: Texture2D = null
	var nsc := 1.0
	if 源 is BaseMaterial3D:
		var bm := 源 as BaseMaterial3D
		alb = bm.albedo_texture
		if bm.normal_enabled and bm.normal_texture != null:
			nrm = bm.normal_texture
			nsc = bm.normal_scale
	var key := "%s|%s|%s|%.2f" % [语义,
			alb.resource_path if alb != null else "-",
			nrm.resource_path if nrm != null else "-", nsc]
	if _cache.has(key):
		return _cache[key]
	var m := _造材质(语义, alb, nrm, nsc)
	_cache[key] = m
	return m


## 合批（MultiMeshInstance3D）专用：MultiMesh 不读 MeshInstance 的 surface override，
## 材质必须显式搬过去，否则岩石合批在游戏里还是 GLB 自带的灰白。
static func 套合批(mmi: MultiMeshInstance3D, 源: MeshInstance3D) -> void:
	if mmi == null or 源 == null or 源.mesh == null:
		return
	var 面数: int = 源.mesh.get_surface_count()
	if 面数 <= 0:
		return
	if 面数 == 1:
		var 一个: Material = 源.get_active_material(0)
		var 义 := 语义_of(_材质名(源, 一个, 0))
		if not 义.is_empty():
			mmi.material_override = 取材质(义, 一个)
		return
	for i in 面数:
		var 源材质: Material = 源.get_active_material(i)
		var 义2 := 语义_of(_材质名(源, 源材质, i))
		if 义2.is_empty():
			continue
		mmi.set_surface_override_material(i, 取材质(义2, 源材质))


## 材质名 → 语义（空串 = 不认识，原样保留）
static func 语义_of(名: String) -> String:
	var n := 名.to_lower()
	if n.is_empty():
		return ""
	# 队伍色区永远不碰（旗帜/披风/屋面的阵营色）
	if n.contains("team"):
		return ""
	for e in _规则():
		if n.contains(e[0]):
			return e[1]
	return ""


## 清缓存（退出/换肤时用，和 装饰库.clear_cache 一个规矩）
static func clear_cache() -> void:
	_cache.clear()
	_调色板 = null


# ===========================================================================
# 内部实现
# ===========================================================================

static func _造材质(语义: String, alb: Texture2D, nrm: Texture2D, nsc: float) -> StandardMaterial3D:
	var pal := _取调色板()
	var zone: String = 语义色.get(语义, "")
	var col: Color = _色表.get(zone, pal.fallback)
	var 粗糙: float = float(语义粗糙.get(语义, _粗表.get(zone, 0.9)))
	var 金属: float = float(语义金属.get(语义, _金表.get(zone, 0.0)))
	# 灰度贴图会压暗，抬回调色板原色（贴图只是细节，不该改变色相/明度语义）
	if alb != null:
		col = _提亮(col, _补偿_for(语义))

	var m := StandardMaterial3D.new()
	m.resource_name = 标记 + 语义
	m.albedo_color = col
	m.albedo_texture = alb
	m.metallic = 金属
	m.roughness = 粗糙
	# 自然物是糙面：高光压低，和建筑的哑光读法一致（Godot 4 里这个参数叫 metallic_specular）
	m.metallic_specular = 0.10 if 语义 != "leaf" and 语义 != "leaf_light" else 0.14
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm
		m.normal_scale = nsc

	match 语义:
		"leaf", "leaf_light", "leaf_dark", "grass":
			# 薄片两面可见（树冠/草叶是单面片，背面剔除会露出"空壳"）
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			# 背光：太阳穿过叶片的那种透光感。注意这是**漫反射透射**，不是自发光
			m.backlight_enabled = true
			m.backlight = 叶背光 if 语义.begins_with("leaf") else 草背光
		"cavity":
			# 洞窟内腔：吃不到光，直接压到近黑（矿洞门/树洞的"深"全靠这一块）
			m.albedo_color = _色表.get("cavity", Color(0.09, 0.09, 0.10))
			m.roughness = 0.98
	# 文字说明留在这里：**不要**加 emission —— 那会破坏"全场同一套光"的前提
	return m


static func _补偿_for(语义: String) -> float:
	match 语义:
		# 顶端受光块本来就在最亮一档，再叠背光容易过曝成"奶油色"（实测截图一眼假），
		# 所以叶黄只补一档，让它读成"被晒到的叶子"而不是"刷了金漆"。
		"leaf_light":
			return 0.98
		"leaf", "leaf_dark", "grass":
			return 补偿_叶
		"bark", "bark_dark":
			return 补偿_树皮
	return 补偿_默认


static func _提亮(c: Color, k: float) -> Color:
	# 等比缩放而不是逐通道 clamp：金/骨这种本来就接近 1 的色，
	# 逐通道截断会把色相推向白（金子变白铁），等比只损失一点亮度。
	var mx: float = maxf(maxf(c.r, c.g), c.b)
	var kk: float = minf(k, 1.0 / mx if mx > 0.0001 else k)
	return Color(c.r * kk, c.g * kk, c.b * kk, c.a)


## 关键词表按"长度倒序 + 表内顺序"排一次，之后每帧只是查表
static func _规则() -> Array:
	if not _规则缓存.is_empty():
		return _规则缓存
	var 带序: Array = []
	for i in 关键词.size():
		带序.append([i, 关键词[i][0], 关键词[i][1]])
	带序.sort_custom(func(a: Array, b: Array) -> bool:
		if a[1].length() != b[1].length():
			return a[1].length() > b[1].length()
		return a[0] < b[0])
	for e in 带序:
		_规则缓存.append([e[1], e[2]])
	return _规则缓存


## 取材质名：优先 resource_name（GLB 导入后是 M_bark / M_leaf_dark 这种），
## 其次 surface name，最后退回节点名（导入器会把节点叫 tree_M_bark）。
static func _材质名(mi: MeshInstance3D, 源: Material, i: int) -> String:
	if 源 != null and not String(源.resource_name).is_empty():
		return String(源.resource_name)
	if mi.mesh != null:
		var sn: String = String(mi.mesh.surface_get_name(i))
		if not sn.is_empty():
			return sn
	return String(mi.name)


## 有骨骼/动画 = 角色（走 MatKit 那条路，不归本库管）
static func _是角色(root: Node) -> bool:
	var 栈: Array[Node] = [root]
	while not 栈.is_empty():
		var n: Node = 栈.pop_back()
		if n is Skeleton3D or n is AnimationPlayer:
			return true
		for c in n.get_children():
			栈.append(c)
	return false


static func _收集网格(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var 栈: Array[Node] = [root]
	while not 栈.is_empty():
		var n: Node = 栈.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			out.append(mi)
		for c in n.get_children():
			栈.append(c)
	return out


static func _取调色板() -> RtsPalette:
	if _调色板 != null:
		return _调色板
	# 代码里的默认表（含 v3 追加的自然物 zone）
	var 默认 := RtsPalette.new()
	if ResourceLoader.exists(调色板路径):
		_调色板 = load(调色板路径) as RtsPalette
	if _调色板 == null:
		_调色板 = 默认
	# .tres 可能比代码旧（没写新追加的 zone）：代码默认值打底、.tres 覆盖。
	# 只查 .tres 的话，leaf_olive 会整个掉进 fallback —— 叶子又变成灰的。
	_色表 = 默认.colors.duplicate()
	_色表.merge(_调色板.colors, true)
	_粗表 = 默认.roughness.duplicate()
	_粗表.merge(_调色板.roughness, true)
	_金表 = 默认.metallic.duplicate()
	_金表.merge(_调色板.metallic, true)
	return _调色板
