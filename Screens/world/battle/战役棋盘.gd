extends Node3D
## 职责：把底壳的战术格子画成**能看懂的棋盘**——玩家区 3 列 × 6 行 PvZ 式双色微差格、
##       中立据点格、敌方格、主堡格，以及格子的两个标准锚点（左上象限建筑位 / 正中心出兵位）。
## 属于：Screens/world/battle（表现层）
##
## 纪律：
##   · 格子位置/尺寸/贴地高度全部来自 `SquadArena`（世界米），这里不重算锚点；
##     两个锚点直接用桥给的 `building_x/z` 与 `spawn_x/z`（唯一实现在 TacticalTile.cs）；
##   · 颜色来自 `map_shells.json` 的 `board.theme`（可换皮）；这里不接受写死色值调用；
##   · **棋盘是一层"草坪漆"**：贴地、半透明、和地表用同一张草地贴图（世界 XZ 投影），
##     所以地面纹理细节始终透得出来。绝不是一块不透明厚板 —— 上一版画了 16cm 厚的实心块
##     + 侧面 + 亮边框，整片战场像贴了一叠瓷砖，把地形全遮死了；
##   · 相邻格只做 6%~10% 的明暗微差（`two_tone`），近看是一整块草地、远看能数清 18 格；
##   · 只画几何，不做任何"这格能不能建"的判断 —— 那是 Model 的 FreePlayerTiles()。

## 棋盘色层的默认值（数据里 look.board 缺失时兜底；真值在 map_shells.json 的 look.board）
const FILL_ALPHA_DEFAULT := 0.30
const BORDER_ALPHA_DEFAULT := 0.46
const BORDER_M_DEFAULT := 0.22
const LIFT_DEFAULT := 0.018
const TWO_TONE_DEFAULT := 0.08
## 相邻格明暗差的合法区间：低于 6% 数不清格子，高于 10% 就变成"瓷砖"。
const TWO_TONE_MIN := 0.06
const TWO_TONE_MAX := 0.10

var _slab: MeshInstance3D = null
var _marks: MeshInstance3D = null
var _highlight: MeshInstance3D = null
var _arena: Dictionary = {}
var _theme: Dictionary = {}
var _spec: Dictionary = {}
var _look: Dictionary = {}
var _free_tiles: Array = []
var _armed := false
var _hover := 0
var _dirty_marks := true


func _ready() -> void:
	_slab = _make_mesh_node("Tiles")
	_marks = _make_mesh_node("Anchors")
	_highlight = _make_mesh_node("Highlight")


func _make_mesh_node(n: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _line_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ===========================================================================
# 装配
# ===========================================================================
func set_arena(arena: Dictionary, theme: Dictionary, spec: Dictionary = {},
		look: Dictionary = {}) -> void:
	_arena = arena
	_theme = theme
	_spec = spec if not spec.is_empty() else RtsTileSpec.spec_from({})
	_look = look
	_rebuild()


## 玩家已打出建造牌、正在选格子：高亮所有空格子。
func set_armed(armed: bool, free_tiles: Array) -> void:
	_armed = armed
	_free_tiles = free_tiles
	_rebuild_highlight()


func set_hover_tile(index: int) -> void:
	if _hover == index:
		return
	_hover = index
	if _armed:
		_rebuild_highlight()


func _rebuild() -> void:
	if _slab == null:
		return
	var tiles: Array = _arena.get("tiles", [])
	# 双色微差：按 X / Z 各自排序后的下标奇偶决定深浅（换皮只改 theme）
	var xs := _unique_sorted(tiles, "x")
	var zs := _unique_sorted(tiles, "z")
	var lift := _lift()
	var st_even := SurfaceTool.new()
	var st_odd := SurfaceTool.new()
	st_even.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_odd.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n_even := 0
	var n_odd := 0
	for t in tiles:
		var tile: Dictionary = t
		var side := String(tile.get("side", "player"))
		var role := String(tile.get("role", "build"))
		var ci := xs.find(snappedf(float(tile.get("x", 0.0)), 0.01))
		var ri := zs.find(snappedf(float(tile.get("z", 0.0)), 0.01))
		var even := ((ci + ri) % 2) == 0
		var fill := _tile_color(side, role, even)
		var border := _border_color(fill)
		var st := st_even if even else st_odd
		_paint_tile(st, tile, lift, fill, border)
		if even:
			n_even += 1
		else:
			n_odd += 1
	var mesh := ArrayMesh.new()
	# 空 SurfaceTool 调 commit 会报 "No vertices were added"（引擎 ERROR）：按画了几格决定提交
	if n_even > 0:
		mesh = st_even.commit()
	if n_odd > 0:
		var odd := st_odd.commit()
		if odd != null and odd.get_surface_count() > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, odd.surface_get_arrays(0))
	_slab.mesh = mesh
	_slab.material_override = null
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, _tile_material("tile_a"))
	if mesh.get_surface_count() > 1:
		mesh.surface_set_material(1, _tile_material("tile_b"))
	_rebuild_marks()
	_rebuild_highlight()


func _unique_sorted(tiles: Array, key: String) -> Array:
	var seen := {}
	for t in tiles:
		var v := snappedf(float((t as Dictionary).get(key, 0.0)), 0.01)
		seen[v] = true
	var arr := seen.keys()
	arr.sort()
	return arr


# ===========================================================================
# 颜色：主题色 → 线性顶点色（含 6%~10% 双色微差）
# ===========================================================================
func _col(key: String, fallback: Color) -> Color:
	var v: Variant = _theme.get(key, null)
	if v is Color:
		return (v as Color).srgb_to_linear()
	if v is String and not String(v).is_empty():
		# 顶点色在 Godot 里按**线性**解释；主题里写的是 sRGB，必须换算，否则会白成一片。
		return Color(String(v)).srgb_to_linear()
	return fallback.srgb_to_linear()


func _style(key: String, fallback: float) -> float:
	var b: Variant = _look.get("board", {})
	var d: Dictionary = b if b is Dictionary else {}
	return float(d.get(key, fallback))


func _lift() -> float:
	return _style("lift_m", LIFT_DEFAULT)


func _alpha() -> float:
	return clampf(_style("fill_alpha", FILL_ALPHA_DEFAULT), 0.05, 0.95)


func _two_tone() -> float:
	return clampf(_style("two_tone", TWO_TONE_DEFAULT), TWO_TONE_MIN, TWO_TONE_MAX)


## 一对相邻格的颜色：亮格用主题色，暗格按 `two_tone` 压暗。
##
## **为什么要按 alpha 补偿**：这是一层半透明色层，压暗量会被 alpha 稀释
##（合成后 = 地面×(1-a) + 色层×a）。所以暗格要预先压暗 `two_tone / alpha`，
## 画面上相邻格的亮度差才是数据里写的那 6%~10% —— 否则永远"看起来没差别"。
func _pair(light: Color, dark: Color) -> Array:
	var a := maxf(_alpha(), 0.12)
	var k := clampf(_two_tone() / a, 0.02, 0.55)
	var ll := _lum(light)
	# 皮肤自己给了一对"已经落在 6%~10%"的颜色就照用；给得不对（手改 JSON 很容易）就按
	# two_tone 反算 —— 棋盘的观感是规格，不是每个皮肤各调一次的玄学。
	if ll > 0.001 and dark != light:
		var d := (ll - _lum(dark)) / ll
		if d >= TWO_TONE_MIN and d <= TWO_TONE_MAX:
			return [light, dark]
	return [light, light.darkened(k)]


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _tile_color(side: String, role: String, even: bool) -> Color:
	if role == "keep":
		var pair := _pair(_col("keep", Color(0.62, 0.52, 0.34)), _col("keep_dark", Color(0.55, 0.45, 0.29)))
		var c: Color = pair[0] if even else pair[1]
		c.a = _alpha()
		return c
	match side:
		"neutral":
			var base := _col("neutral", Color(0.66, 0.60, 0.42))
			var p2 := _pair(base, base.darkened(_two_tone()))
			var n: Color = p2[0] if even else p2[1]
			n.a = _alpha()
			return n
		"enemy":
			var pair3 := _pair(_col("enemy", Color(0.52, 0.34, 0.30)), _col("enemy_dark", Color(0.45, 0.29, 0.26)))
			var e: Color = pair3[0] if even else pair3[1]
			e.a = _alpha()
			return e
		_:
			var pair4 := _pair(_col("light", Color(0.66, 0.69, 0.48)), _col("dark", Color(0.56, 0.60, 0.38)))
			var l: Color = pair4[0] if even else pair4[1]
			l.a = _alpha()
			return l


## 内框线：同色压暗 + 略高不透明度（读起来像"格线"，不像"瓷砖缝"）。
func _border_color(fill: Color) -> Color:
	var darken := clampf(_style("border_darken", 0.22), 0.0, 0.6)
	var c := fill.darkened(darken)
	c.a = clampf(_style("border_alpha", BORDER_ALPHA_DEFAULT), 0.0, 1.0)
	return c


# ===========================================================================
# 一格 = 内面（半透明填充）+ 一圈内框线（略暗略实），全部贴地
# ===========================================================================
func _paint_tile(st: SurfaceTool, tile: Dictionary, lift: float, fill: Color, border: Color) -> void:
	var x := float(tile.get("x", 0.0))
	var z := float(tile.get("z", 0.0))
	var y := float(tile.get("terrain_y", 0.0)) + lift
	var hw := float(tile.get("w", 4.0)) * 0.5
	var hd := float(tile.get("d", 4.0)) * 0.5
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)
	var bw := clampf(_style("border_m", BORDER_M_DEFAULT), 0.0, minf(hw, hd) * 0.4)
	var ow: Array[Vector3] = _corners(x, z, y, hw, hd, c, s)
	var iw: Array[Vector3] = _corners(x, z, y, hw - bw, hd - bw, c, s)
	# 外缘（内框线）：四条梯形带
	for i in 4:
		var o0: Vector3 = ow[i]
		var o1: Vector3 = ow[(i + 1) % 4]
		var i0: Vector3 = iw[i]
		var i1: Vector3 = iw[(i + 1) % 4]
		_tri(st, o0, o1, i1, border)
		_tri(st, o0, i1, i0, border)
	# 内面：填充
	_tri(st, iw[0], iw[1], iw[2], fill)
	_tri(st, iw[0], iw[2], iw[3], fill)


func _corners(x: float, z: float, y: float, hw: float, hd: float, c: float, s: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for pair in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
		var lx: float = float(pair[0]) * hw
		var lz: float = float(pair[1]) * hd
		out.append(Vector3(x + lx * c + lz * s, y, z - lx * s + lz * c))
	return out


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color,
		normal: Vector3 = Vector3.UP) -> void:
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(c)


## 色层材质：直接吃皮肤表里的 `tile_a / tile_b`（同一张草地贴图），只做三件事：
##   ① 世界 XZ 三平面投影（8m 一铺，和地表贴图完全对齐 → 纹理细节连成一片）；
##   ② 开顶点色（颜色与透明度都来自顶点色，主题说了算）；
##   ③ 半透明混合（底层地形的草叶/交界阴影始终透得出来）。
func _tile_material(key: String) -> Material:
	var base := RtsTerrainAssets.skin_material(key)
	var m: StandardMaterial3D = null
	if base is StandardMaterial3D:
		m = (base as StandardMaterial3D).duplicate() as StandardMaterial3D
	if m == null:
		m = StandardMaterial3D.new()
		if ResourceLoader.exists(RtsTerrainAssets.TEX_GRASS_PATH):
			m.albedo_texture = load(RtsTerrainAssets.TEX_GRASS_PATH) as Texture2D
	m.albedo_color = Color.WHITE
	m.vertex_color_use_as_albedo = true
	# 不受光：这一层是半透明"草坪漆"，跟着地形自己的两阶光照走会出现双份明暗
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.uv1_scale = Vector3(1.0 / RtsTerrainAssets.TILE_M, 1.0 / RtsTerrainAssets.TILE_M, 1.0)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_triplanar_sharpness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.95
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# 半透明层不写深度、不投阴影：既不会在地上留一圈假影子，也不会把地形的接触阴影压掉
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	return m


# ===========================================================================
# 锚点标记：左上象限 = 建筑位方框（尺寸跟着占地比例），正中心 = 出兵位圆环
# ===========================================================================
func _rebuild_marks() -> void:
	if _marks == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var build_col := _col("build_anchor", Color(0.75, 0.54, 0.18))
	build_col.a = 0.55
	var spawn_col := _col("spawn_anchor", Color(0.30, 0.62, 1.0))
	spawn_col.a = 0.85
	var lift := _lift()
	var ratio := float(_spec.get("footprint_ratio", RtsTileSpec.FOOTPRINT_DEFAULT))
	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		var side := String(tile.get("side", "player"))
		if side == "neutral":
			continue
		var y := float(tile.get("terrain_y", 0.0)) + lift + 0.008
		# 建筑位：左上象限中心的一个小方框（大小 = 建筑实际占地的外沿）
		if String(tile.get("role", "build")) == "build":
			var ax := float(tile.get("building_x", tile.get("x", 0.0)))
			var az := float(tile.get("building_z", tile.get("z", 0.0)))
			var c := RtsTileSpec.center(tile, Vector2(ax, az), _spec)
			var half := RtsTileSpec.span_of(tile, ratio) * 0.5 * 1.04
			_flat_ring_rect(st, c.x, c.y, half, half, 0.07, y, build_col)
		# 出兵位：正中心圆环
		var sx := float(tile.get("spawn_x", tile.get("x", 0.0)))
		var sz := float(tile.get("spawn_z", tile.get("z", 0.0)))
		_flat_ring(st, sx, sz, 0.62, 0.46, y, spawn_col)
	_marks.mesh = st.commit()
	_marks.material_override = _line_mat()
	_dirty_marks = false


## 高亮：正在挑格子时，所有空格子亮一圈；鼠标悬停那一格最亮
func _rebuild_highlight() -> void:
	if _highlight == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := _lift()
	if _armed:
		var base := Color(0.98, 0.86, 0.44, 0.20)
		var hot := Color(1.0, 0.95, 0.72, 0.42)
		for t in _arena.get("tiles", []):
			var tile: Dictionary = t
			var idx := int(tile.get("index", 0))
			if not _free_tiles.has(idx) and idx != _hover:
				continue
			var y := float(tile.get("terrain_y", 0.0)) + lift + 0.012
			var hw := float(tile.get("w", 4.0)) * 0.5
			var hd := float(tile.get("d", 4.0)) * 0.5
			var col := hot if idx == _hover else base
			_flat_rect(st, float(tile.get("x", 0.0)), float(tile.get("z", 0.0)), hw, hd, y, col)
	_highlight.mesh = st.commit()
	_highlight.material_override = _line_mat()


func _flat_rect(st: SurfaceTool, x: float, z: float, hw: float, hd: float, y: float, col: Color) -> void:
	var p0 := Vector3(x - hw, y, z - hd)
	var p1 := Vector3(x + hw, y, z - hd)
	var p2 := Vector3(x + hw, y, z + hd)
	var p3 := Vector3(x - hw, y, z + hd)
	_tri(st, p0, p1, p2, col)
	_tri(st, p0, p2, p3, col)


func _flat_ring_rect(st: SurfaceTool, x: float, z: float, hw: float, hd: float,
		thick: float, y: float, col: Color) -> void:
	var a0 := Vector3(x - hw, y, z - hd)
	var a1 := Vector3(x + hw, y, z - hd)
	var a2 := Vector3(x + hw, y, z + hd)
	var a3 := Vector3(x - hw, y, z + hd)
	var b0 := Vector3(x - hw + thick, y, z - hd + thick)
	var b1 := Vector3(x + hw - thick, y, z - hd + thick)
	var b2 := Vector3(x + hw - thick, y, z + hd - thick)
	var b3 := Vector3(x - hw + thick, y, z + hd - thick)
	var outer := [a0, a1, a2, a3]
	var inner := [b0, b1, b2, b3]
	for i in 4:
		var o0: Vector3 = outer[i]
		var o1: Vector3 = outer[(i + 1) % 4]
		var i0: Vector3 = inner[i]
		var i1: Vector3 = inner[(i + 1) % 4]
		_tri(st, o0, o1, i1, col)
		_tri(st, o0, i1, i0, col)


func _flat_ring(st: SurfaceTool, x: float, z: float, r_out: float, r_in: float, y: float, col: Color) -> void:
	var seg := 20
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var o0 := Vector3(x + cos(a0) * r_out, y, z + sin(a0) * r_out)
		var o1 := Vector3(x + cos(a1) * r_out, y, z + sin(a1) * r_out)
		var i0 := Vector3(x + cos(a0) * r_in, y, z + sin(a0) * r_in)
		var i1 := Vector3(x + cos(a1) * r_in, y, z + sin(a1) * r_in)
		_tri(st, o0, o1, i1, col)
		_tri(st, o0, i1, i0, col)
