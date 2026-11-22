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
## fill_alpha 压得很低（0.20）：这一层是"草坪漆"，不是"色块"。低于 0.12 就数不清格子，
## 高于 0.30 就把地形纹理糊住了 —— 区间是观感规格，不是随手填的。
const FILL_ALPHA_DEFAULT := 0.20
const EDGE_ALPHA_DEFAULT := 0.34
const EDGE_M_DEFAULT := 0.55
const LIFT_DEFAULT := 0.02
const TWO_TONE_DEFAULT := 0.08
const TONE_COOL_DEFAULT := 0.35
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
		var edge := _edge_color(fill)
		var edge_norm := _edge_soft(tile)
		var st := st_even if even else st_odd
		_paint_tile(st, tile, lift, fill, edge, edge_norm)
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


## 棋盘观感探针（截图断言读它）：证明这一层是"半透明草坪漆"而不是"不透明色块"。
## alpha 高、双色差出区间、软边为 0 —— 任意一条不成立就读成瓷砖，所以这里给出 ok 判据。
func look_report() -> String:
	var a := _alpha()
	var t := _two_tone()
	var e := clampf(_style("edge_m", EDGE_M_DEFAULT), 0.0, 2.5)
	var ok := a <= 0.34 and a >= 0.10 and t >= TWO_TONE_MIN and t <= TWO_TONE_MAX and e >= 0.25
	return "alpha=%.2f tone=%.3f edge=%.2fm ok=%d" % [a, t, e, 1 if ok else 0]


## 一对相邻格的颜色：亮格用主题色，暗格按 `two_tone` 压暗。
##
## **为什么要按 alpha 补偿**：这是一层半透明色层，压暗量会被 alpha 稀释
##（合成后 = 地面×(1-a) + 色层×a）。所以暗格要预先压暗 `two_tone / alpha`，
## 画面上相邻格的亮度差才是数据里写的那 6%~10% —— 否则永远"看起来没差别"。
func _pair(light: Color, dark: Color) -> Array:
	var a := maxf(_alpha(), 0.12)
	var k := clampf(_two_tone() / a, 0.02, 0.80)
	var ll := _lum(light)
	# 皮肤自己给了一对"已经落在 6%~10%"的颜色就照用；给得不对（手改 JSON 很容易）就按
	# two_tone 反算 —— 棋盘的观感是规格，不是每个皮肤各调一次的玄学。
	if ll > 0.001 and dark != light:
		var d := (ll - _lum(dark)) / ll
		if d >= TWO_TONE_MIN and d <= TWO_TONE_MAX:
			return [light, dark]
	# 暗格：先按 alpha 反算压暗，再给一点点"偏冷"的色相偏移（PvZ 草坪的两条割痕是靠冷暖分的，
	# 只靠明暗会读成"脏了一块"）。最后把亮度校回目标值，确保画面上仍是那 6~10%。
	var out := light.darkened(k)
	var cool := clampf(_style("tone_cool", TONE_COOL_DEFAULT), 0.0, 1.0)
	if cool > 0.001:
		out = Color(out.r * (1.0 - 0.10 * cool), out.g * (1.0 - 0.02 * cool),
			out.b * (1.0 + 0.14 * cool), out.a)
		var want := _lum(light) * (1.0 - k)
		var got := _lum(out)
		if got > 0.0001:
			var s := want / got
			out = Color(out.r * s, out.g * s, out.b * s, out.a)
	return [light, out]


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


## 格边：同色压暗 + 略高不透明度（读起来像"草坪分格缝"，不像"瓷砖缝"）。
func _edge_color(fill: Color) -> Color:
	var darken := clampf(_style("edge_darken", 0.14), 0.0, 0.6)
	var c := fill.darkened(darken)
	c.a = clampf(_style("edge_alpha", EDGE_ALPHA_DEFAULT), 0.0, 1.0)
	return c


## 软边宽度（占格边长的比例）：0.55m 的软边在 7m 格子上是 8%，正好"看得出分格、看不出线"。
func _edge_soft(tile: Dictionary) -> float:
	var m := clampf(_style("edge_m", EDGE_M_DEFAULT), 0.0, 2.5)
	var span := maxf(minf(float(tile.get("w", 7.0)), float(tile.get("d", 7.0))), 0.01)
	return clampf(m / span, 0.004, 0.30)


# ===========================================================================
# 一格 = 一张"草坪漆"：中心平涂 + 靠边柔和压暗（网格化顶点色渐变）
# ===========================================================================
#
# 为什么用网格而不是"填充 + 一圈实心边框"：
#   上一版是 16cm 厚实心块 + 不透明填充 + 0.3m 亮边框 —— 画面上是一叠瓷砖，
#   地形纹理一点透不出来，格子还比地面高一截。现在（2026-11-22）改成：
#     · 每个格子拆成 GRID×GRID 的小片，颜色按"到格边的距离"渐变：
#       中心 = 底色，靠边渐变到略暗一点的同色 —— 这就是"轻微边缘压暗"，
#       读起来是草坪的分格缝，不是瓷砖缝；
#     · 整层半透明（fill_alpha 从数据来），底下的草地贴图/交界阴影全程透得出来；
#     · 双色微差靠 `_pair`：按 alpha 反算出"压暗多少"，合成后的亮度差才是数据里那 6~10%。
const GRID := 4


func _paint_tile(st: SurfaceTool, tile: Dictionary, lift: float, fill: Color, edge: Color,
		edge_norm: float) -> void:
	var x := float(tile.get("x", 0.0))
	var z := float(tile.get("z", 0.0))
	var y := float(tile.get("terrain_y", 0.0)) + lift
	var hw := float(tile.get("w", 4.0)) * 0.5
	var hd := float(tile.get("d", 4.0)) * 0.5
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)
	var soft := clampf(edge_norm, 0.001, 0.5)
	var rows := GRID + 1
	var grid: Array[Vector3] = []
	var cols: Array[Color] = []
	grid.resize(rows * rows)
	cols.resize(rows * rows)
	for j in rows:
		var v := float(j) / float(GRID)
		for i in rows:
			var u := float(i) / float(GRID)
			var lx := (u * 2.0 - 1.0) * hw
			var lz := (v * 2.0 - 1.0) * hd
			grid[j * rows + i] = Vector3(x + lx * c + lz * s, y, z - lx * s + lz * c)
			# 到最近格边的"归一化深度"：0 = 正好在边上，1 = 越过软边宽度
			var d := minf(minf(u, 1.0 - u), minf(v, 1.0 - v)) / soft
			var t := smoothstep(0.0, 1.0, clampf(d, 0.0, 1.0))
			cols[j * rows + i] = edge.lerp(fill, t)
	for j in GRID:
		for i in GRID:
			var a: int = j * rows + i
			var b: int = a + 1
			var cc: int = a + rows
			var d2: int = cc + 1
			_tri_c(st, grid[a], grid[b], grid[d2], cols[a], cols[b], cols[d2])
			_tri_c(st, grid[a], grid[d2], grid[cc], cols[a], cols[d2], cols[cc])


func _tri_c(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color, normal: Vector3 = Vector3.UP) -> void:
	st.set_color(ca)
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_color(cb)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_color(cc)
	st.set_normal(normal)
	st.add_vertex(c)


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


## 色层材质：**一层纯色半透明漆**，颜色 100% 来自顶点色（主题说了算），不吃任何贴图。
##
## 为什么不再叠一张草地贴图：上一版让色层自己也三平面铺同一张草地，结果两层纹理
## 各走各的周期（地形 12.5m / 色层 8m），叠出来是"重影"，而且色层不受光、亮度比地面高，
## 整片棋盘像浮在地面上的一层塑料膜。现在只做三件事：
##   ① 顶点色当底色（含透明度）；
##   ② 半透明混合 —— 底层地形的草叶、交界阴影按 (1-alpha) 原样透出来；
##   ③ 不受光、不写深度、不投阴影（它是一层油漆，不是一块板）。
func _tile_material(key: String) -> Material:
	var base := RtsTerrainAssets.skin_material(key)
	var m: StandardMaterial3D = null
	if base is StandardMaterial3D:
		m = (base as StandardMaterial3D).duplicate() as StandardMaterial3D
	if m == null:
		m = StandardMaterial3D.new()
	m.albedo_texture = null
	m.albedo_color = Color.WHITE
	m.vertex_color_use_as_albedo = true
	# 不受光：这一层是半透明"草坪漆"，跟着地形自己的两阶光照走会出现双份明暗
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.uv1_triplanar = false
	m.uv1_scale = Vector3.ONE
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
	build_col.a = 0.42
	var spawn_col := _col("spawn_anchor", Color(0.30, 0.62, 1.0))
	spawn_col.a = 0.55
	var lift := _lift()
	var ratio := float(_spec.get("footprint_ratio", RtsTileSpec.FOOTPRINT_DEFAULT))
	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		# 只给我方格子画锚点：敌方/中立每格都画会变成一片圈圈，反而看不清战场。
		if String(tile.get("side", "player")) != "player":
			continue
		var y := float(tile.get("terrain_y", 0.0)) + lift + 0.008
		# 建筑位：左上象限中心的一个小方框（大小 = 建筑实际占地的外沿）
		if String(tile.get("role", "build")) == "build":
			var ax := float(tile.get("building_x", tile.get("x", 0.0)))
			var az := float(tile.get("building_z", tile.get("z", 0.0)))
			var c := RtsTileSpec.center(tile, Vector2(ax, az), _spec)
			var half := RtsTileSpec.span_of(tile, ratio) * 0.5 * 1.04
			_flat_ring_rect(st, c.x, c.y, half, half, 0.07, y, build_col)
		# 出兵位：正中心圆环（细一圈，别抢建筑的视线）
		var sx := float(tile.get("spawn_x", tile.get("x", 0.0)))
		var sz := float(tile.get("spawn_z", tile.get("z", 0.0)))
		_flat_ring(st, sx, sz, 0.58, 0.49, y, spawn_col)
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
