@tool
extends RefCounted
## 地图底壳（MapShell）的几何与契约：R1 换算、势力区域多边形、战术格子锚点、地形高度场、校验。
## 属于：Screens/editor（开发工具，不进发行版）
##
## 纪律：
##   · 这里是底壳几何的唯一实现：三维底壳编辑器、数据工作台、生成脚本都调它，不各写一份；
##   · **区域多边形与格子锚点的判定/校验在 Model（C#）**，这里只做转发 + JSON ↔ Variant 转换；
##   · 只做纯函数，不读文件（读写统一走 dev_data.gd）；
##   · 源码零写死中文：显示名一律来自 Content/data/*.json 或 ui.csv。
##
## 方位：x 向右（-size.x/2 .. +size.x/2），z 向玩家（-size.z/2 .. +size.z/2），y 向上。
## 玩家区在左（x < 0），敌方区在右（x > 0）。

const R1 := 0.015
const CELL := 1.5
const TILE_SIZE_DEFAULT := 6.0
const TILE_SIZE_KEEP := 10.0
const MIN_GAP_M := 1.0
const T_DENOM := 1000.0

## 底板（立体厚度地块 + 画布冗余 + 格子统一倍率）的默认值。
## **规则不在这里**：取值范围与算式在 Model/Map/MapBoard.cs，这里只做 JSON ↔ Variant 转换。
const BOARD_FALLBACK := {
	"depth": 6.0,
	"bevel": 0.35,
	"margin": 0.45,
	"tile_scale": 1.0,
	"snap": 1.0,
}

## 三个势力区域（顺序 = 顶栏按钮顺序）。字符串契约与 Model/Map/RegionPolygon.cs 一致。
const REGION_IDS := ["player", "neutral", "enemy"]
const REGION_KEYS := {
	"player": "shell.region.player",
	"neutral": "shell.region.neutral",
	"enemy": "shell.region.enemy",
}
const REGION_COLORS := {
	"player": Color("#4EA1FF"),
	"neutral": Color("#B8BCC6"),
	"enemy": Color("#FF6E6E"),
}
const TILE_SIDES := ["player", "enemy", "neutral"]
const TILE_ROLES := ["keep", "build"]
const DECOR_KINDS := ["tree", "rock", "grass", "rubble", "goldmine",
	"fence", "flag", "stump", "crate", "barrel", "tent", "wall", "signpost", "bones"]

## 装饰注册表（真实资产路径只写在 JSON 里，源码保持 ASCII）。
const DECOR_TABLE := "res://Content/data/shell_decor.json"
static var _decor_rows: Array = []
static var _decor_loaded := false

const PALETTE_FALLBACK := [
	{"id": "grass", "color": "#5D6B3F"},
	{"id": "dirt", "color": "#6B5A43"},
	{"id": "rock", "color": "#5A5F68"},
	{"id": "sand", "color": "#8A7A56"},
]

## Model 桥（懒建；非 .NET 编辑器下为 null，校验会明确报"内核不可用"）。
static var _bridge: RefCounted = null
static var _bridge_checked := false


static func bridge() -> RefCounted:
	if _bridge != null and is_instance_valid(_bridge):
		return _bridge
	if _bridge_checked:
		return _bridge
	_bridge_checked = true
	var script: Script = load("res://Game/adapters/bridge.gd") as Script
	if script == null:
		return null
	_bridge = script.call("get_bridge") as RefCounted
	return _bridge


# ===========================================================================
# R1 与逻辑刻度
# ===========================================================================
static func logic_of(meters: float) -> float:
	return roundf(meters / R1)


static func meters_of(logic: float) -> float:
	return logic * R1


# ===========================================================================
# 地形高度场
# ===========================================================================
static func size_of(shell: Dictionary) -> Vector2:
	var s: Dictionary = shell.get("size", {})
	return Vector2(float(s.get("x", 120.0)), float(s.get("z", 63.0)))


static func grid_of(shell: Dictionary) -> Dictionary:
	var sz := size_of(shell)
	var cell := float((shell.get("terrain", {}) as Dictionary).get("cell", CELL))
	if cell <= 0.0:
		cell = CELL
	var cols := int(round(sz.x / cell)) + 1
	var rows := int(round(sz.y / cell)) + 1
	return {"cell": cell, "cols": cols, "rows": rows, "origin_x": -sz.x * 0.5, "origin_z": -sz.y * 0.5}


static func world_of_cell(shell: Dictionary, col: int, row: int) -> Vector2:
	var g := grid_of(shell)
	var cell := float(g["cell"])
	return Vector2(float(g["origin_x"]) + float(col) * cell, float(g["origin_z"]) + float(row) * cell)


static func cell_of_world(shell: Dictionary, x: float, z: float) -> Vector2:
	var g := grid_of(shell)
	var cell := float(g["cell"])
	return Vector2((x - float(g["origin_x"])) / cell, (z - float(g["origin_z"])) / cell)


## 三块势力区域的**外包矩形**（世界米）：战术区地面强制平整的唯一口径。
##
## 为什么必须是一条硬规则：寻路、格子贴地、建筑落位、小队站位全都假定战术区是水平面。
## 高度场只要在战术区里起伏 30cm，格子就会一半陷进土里、一半浮在空中（2026-11-22 之前的真实故障）。
## 因此 `terrain_height()` 在这个矩形内**恒返回 0**，起伏只允许出现在矩形外的周边环境带。
static func play_area(shell: Dictionary) -> Rect2:
	var min_x := 1e9
	var max_x := -1e9
	var min_z := 1e9
	var max_z := -1e9
	for kind in REGION_IDS:
		for p in region_points(shell, kind):
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
			min_z = minf(min_z, p.y)
			max_z = maxf(max_z, p.y)
	if min_x > max_x:
		# 没有区域多边形（新建图的第一帧）：整图按平整处理，宁可不起伏也不要陷地
		var sz := size_of(shell)
		return Rect2(-sz.x * 0.5, -sz.y * 0.5, sz.x, sz.y)
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z)


## 平整区外缘的抬升带宽度（米）：从 0 平滑抬到丘陵高度，避免硬折角。
const RIM_RAMP_M := 13.0
## 抬升带外沿的基准高度（米）：像一圈缓坡把战场围在中间。
const RIM_BASE_H := 2.2
## 丘陵起伏振幅（米）：只改观感，不参与任何判定。
## 2.6 太温吞 —— 从 60m 高的机位看下去就是一整片平绿，读不出"立体沙盘"。
const HILL_AMP := 7.5
## 紧贴战术区的一圈**土坎**：几米内抬起来，肉眼看得出"这块地是抬起来的立体块"。
## 坡度 = RIM_STEP_H / RIM_STEP_M ≈ 51°，着色器按"陡面"把它画成岩壁/土层（见 地形.gdshader 的 cliff）。
## 太小（<2m）等于没有；太大（>6m）会把玩家区围成坑、俯视时挡住棋盘后排。
const RIM_STEP_M := 3.2
const RIM_STEP_H := 4.0
## 土坎离战术区边缘的**草地缓冲带**（米）：0 会让土坎紧贴边线，读起来像绕着战场的一条土路；
## 留 6m 草地再起坡，流程就是"平整战场 → 一圈草地 → 抬起来的土坎/丘陵"，层次才对。
const RIM_STEP_GAP := 6.0

## 未雕刻时的丘陵噪声：只负责"高低不平"，不含平整区判定（判定在 terrain_height）。
static func procedural_height(seed_value: int, x: float, z: float) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var p1 := rng.randf_range(0.0, TAU)
	var p2 := rng.randf_range(0.0, TAU)
	var p3 := rng.randf_range(0.0, TAU)
	# 两层：40~70m 的大起伏（读得出"坡"）+ 12~20m 的碎起伏（读得出"不是塑料布"）。
	# 波长再长就退回"整张图一个大缓坡"，再短会在环境带里起尖包。
	var ridge := 0.45 * sin(x * 0.13 + p1) + 0.35 * cos(z * 0.17 + p2) \
		+ 0.20 * sin((x + z) * 0.09 + p3)
	var fine := 0.55 * sin(x * 0.31 + p2) * cos(z * 0.27 + p3)
	var h := RIM_BASE_H + HILL_AMP * (0.45 + ridge * 0.55 + fine * 0.30)
	return clampf(h, RIM_BASE_H - HILL_AMP * 0.55, RIM_BASE_H + HILL_AMP * 1.1)


## 底壳的**初始地面高度**（未雕刻时）：战术区恒 0，区外按距离平滑抬成丘陵。
##
## 这是"三块作战区绝对平整 + 周边立体地形"两条要求的唯一实现：
## 编辑器、生成脚本、局内都读同一份 heights（数据），但生成规则只在这里写一次。
static func terrain_height(shell: Dictionary, x: float, z: float) -> float:
	var area := play_area(shell)
	var d := maxf(maxf(area.position.x - x, x - (area.position.x + area.size.x)), 0.0)
	var dz := maxf(maxf(area.position.y - z, z - (area.position.y + area.size.y)), 0.0)
	var outside := sqrt(d * d + dz * dz)
	if outside <= 0.001:
		return 0.0
	var w := smoothstep(0.0, RIM_RAMP_M, outside)
	var h := w * procedural_height(int(shell.get("seed", 1)), x, z)
	# 紧贴战术区的土坎：3.2m 内抬 4m（≈51°），一圈连续的立体边缘。
	# 起伏 ±18% 是为了别像一圈混凝土围墙 —— 但它始终是"陡面"，着色器会把它画成岩壁。
	var step := smoothstep(RIM_STEP_GAP, RIM_STEP_GAP + RIM_STEP_M, outside) * RIM_STEP_H
	step *= 0.82 + 0.18 * sin(x * 0.083 + z * 0.061)
	h = maxf(h, step)
	# 外缘再缓缓抬高一点：远处高地挡住地平线，玩家在任何合法机位都看不到图外的虚空
	h += w * clampf((outside - RIM_RAMP_M) * 0.10, 0.0, 5.0)
	return clampf(h, 0.0, 14.0)


static func heights_or_procedural(shell: Dictionary) -> PackedFloat32Array:
	var g := grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var have: Array = (shell.get("terrain", {}) as Dictionary).get("heights", [])
	var out := PackedFloat32Array()
	out.resize(cols * rows)
	if have.size() == cols * rows:
		for i in cols * rows:
			out[i] = float(have[i])
		return out
	for row in rows:
		for col in cols:
			var w := world_of_cell(shell, col, row)
			out[row * cols + col] = terrain_height(shell, w.x, w.y)
	return out


## 双线性采样高度（世界坐标 -> 米）。
static func height_at(shell: Dictionary, x: float, z: float) -> float:
	var g := grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var heights := heights_or_procedural(shell)
	var fx := clampf((x - float(g["origin_x"])) / float(g["cell"]), 0.0, float(cols - 1))
	var fz := clampf((z - float(g["origin_z"])) / float(g["cell"]), 0.0, float(rows - 1))
	var c0 := int(floor(fx))
	var r0 := int(floor(fz))
	var c1 := mini(c0 + 1, cols - 1)
	var r1 := mini(r0 + 1, rows - 1)
	var tx := fx - float(c0)
	var tz := fz - float(r0)
	var h00 := heights[r0 * cols + c0]
	var h10 := heights[r0 * cols + c1]
	var h01 := heights[r1 * cols + c0]
	var h11 := heights[r1 * cols + c1]
	var a := lerpf(h00, h10, tx)
	var b := lerpf(h01, h11, tx)
	return lerpf(a, b, tz)


## 用一份显式高度场采样（编辑器里正在改的那份，不一定已写回 shell）。
static func height_at_shell(shell: Dictionary, p_heights: PackedFloat32Array, x: float, z: float) -> float:
	var g := grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	if p_heights.size() != cols * rows:
		return height_at(shell, x, z)
	var fx := clampf((x - float(g["origin_x"])) / float(g["cell"]), 0.0, float(cols - 1))
	var fz := clampf((z - float(g["origin_z"])) / float(g["cell"]), 0.0, float(rows - 1))
	var c0 := int(floor(fx))
	var r0 := int(floor(fz))
	var c1 := mini(c0 + 1, cols - 1)
	var r1 := mini(r0 + 1, rows - 1)
	var tx := fx - float(c0)
	var tz := fz - float(r0)
	var a := lerpf(p_heights[r0 * cols + c0], p_heights[r0 * cols + c1], tx)
	var b := lerpf(p_heights[r1 * cols + c0], p_heights[r1 * cols + c1], tx)
	return lerpf(a, b, tz)


## 初始地表：走廊铺泥土，其余草地。
## **默认只铺两种真实地块材质**（草/泥）—— 岩石、沙地在地块体系里没有对应材质（是贴花），
## 新图一上来就按高度铺满，整片会变成"灰色/米色塑料布"。它们留给手动笔刷。
static func autopaint(shell: Dictionary) -> Array:
	var g := grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var area := play_area(shell).grow(1.5)
	var out: Array = []
	out.resize(cols * rows)
	for row in rows:
		for col in cols:
			var w := world_of_cell(shell, col, row)
			# 战术区**整片草地**：草坪棋盘的底色必须干净，泥点只留给区外的行军道。
			# （上一版在 |z| ≤ 5 铺了一条 10m 宽的泥带，正好从中间那道格子底下穿过，
			#   棋盘再透明也会被这条泥路抢戏。）
			var idx := 0
			var wobble := 1.6 * sin(w.x * 0.055) + 1.0 * sin(w.x * 0.021 + 1.7)
			# 泥地只铺到**远离战场**的环境带（离区边 38m 以外）且只落在近水平的地面上：
			# 贴坡的裸土会连成一条又宽又亮的"土路"，在俯视构图里比重还高过棋盘。
			if not area.has_point(w) and _outside_of(area, w) > 38.0 and absf(w.y) <= 1.4 + wobble * 0.5:
				idx = 1
			out[row * cols + col] = idx
	return out


## 点到矩形的水平距离（矩形内返回 0）。只服务地表铺色，不做任何玩法判定。
static func _outside_of(rect: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0)
	var dz := maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)
	return sqrt(dx * dx + dz * dz)


static func surface_index(shell: Dictionary) -> Array:
	var arr: Array = (shell.get("surface", {}) as Dictionary).get("index", [])
	var g := grid_of(shell)
	if arr.size() == int(g["cols"]) * int(g["rows"]):
		return arr
	return autopaint(shell)


static func palette(shell: Dictionary) -> Array:
	var arr: Array = (shell.get("surface", {}) as Dictionary).get("palette", [])
	if arr.is_empty():
		return PALETTE_FALLBACK.duplicate()
	return arr


static func palette_color(shell: Dictionary, index: int) -> Color:
	var arr := palette(shell)
	var row: Dictionary = arr[clampi(index, 0, arr.size() - 1)]
	return Color(String(row.get("color", "#5D6B3F")))


# ===========================================================================
# 底板：立体厚度 / 画布冗余 / 格子统一倍率
# ===========================================================================
## 底板参数（缺字段补默认；**不写回**，写回走 ensure_board）。
static func board_of(shell: Dictionary) -> Dictionary:
	var b: Variant = shell.get("board", {})
	var d: Dictionary = b if b is Dictionary else {}
	return {
		"depth": float(d.get("depth", BOARD_FALLBACK["depth"])),
		"bevel": float(d.get("bevel", BOARD_FALLBACK["bevel"])),
		"margin": float(d.get("margin", BOARD_FALLBACK["margin"])),
		"tile_scale": float(d.get("tile_scale", BOARD_FALLBACK["tile_scale"])),
		"snap": float(d.get("snap", BOARD_FALLBACK["snap"])),
	}


## 老图迁移：没有 board 就补一份默认，返回 true = 改动过（调用方要置脏）。
static func ensure_board(shell: Dictionary) -> bool:
	var b: Variant = shell.get("board", null)
	if b is Dictionary and (b as Dictionary).size() >= 5:
		return false
	var out: Dictionary = {}
	for k in BOARD_FALLBACK.keys():
		out[k] = (b as Dictionary).get(k, BOARD_FALLBACK[k]) if b is Dictionary else BOARD_FALLBACK[k]
	shell["board"] = out
	return true


static func set_board_value(shell: Dictionary, key: String, value: float) -> void:
	var d := board_of(shell)
	if not d.has(key):
		return
	d[key] = value
	shell["board"] = d


## 画布尺寸（地图 + 四周冗余）。唯一算式在 Model/Map/MapBoard.cs；桥不可用时按同一公式兜底。
static func canvas_size_of(shell: Dictionary) -> Vector2:
	var sz := size_of(shell)
	var margin := float(board_of(shell)["margin"])
	var b := bridge()
	if b != null:
		var arr: Array = b.call("MapCanvasSize", sz.x, sz.y, margin) as Array
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
	return Vector2(sz.x * (1.0 + 2.0 * margin), sz.y * (1.0 + 2.0 * margin))


## 编辑器相机最大拉远距离：规则在 Model/Map/MapBoard.CameraDistMax（随画布放大）。
## 非 .NET 编辑器拿不到内核时按同一条口径手算一遍，数值一致，不会"换个编辑器就拉不远"。
static func camera_dist_max_of(shell: Dictionary) -> float:
	var canvas := canvas_size_of(shell)
	var b := bridge()
	if b != null:
		return float(b.call("MapCameraDistMax", canvas.x, canvas.y))
	return maxf(200.0, canvas.length() * 0.9)


## 底板参数校验（Model 的唯一实现）。
static func board_validate(shell: Dictionary) -> Array:
	var sz := size_of(shell)
	var d := board_of(shell)
	var b := bridge()
	if b == null:
		return ["model bridge unavailable"]
	return b.call("MapBoardValidate", sz.x, sz.y, float(d["depth"]), float(d["bevel"]),
		float(d["margin"]), float(d["tile_scale"])) as Array


## 某个格子的"原始尺寸"：拖动/缩放都从它算，倍率才是幂等的。
static func tile_base(tile: Dictionary) -> Vector2:
	var w := float(tile.get("base_w", tile.get("w", TILE_SIZE_DEFAULT)))
	var d := float(tile.get("base_d", tile.get("d", TILE_SIZE_DEFAULT)))
	return Vector2(w, d)


## 让**所有**格子按 tile_scale 缩放（幂等：从 base_w/base_d 算，不叠乘）。
## 放不下的极端倍率由 Model 的 MaxScaleFor 收回来，绝不产生非法格子。
static func apply_tile_scale(shell: Dictionary, scale: float) -> void:
	var b := bridge()
	var board := board_of(shell)
	board["tile_scale"] = scale
	shell["board"] = board
	for t in tiles(shell):
		var td: Dictionary = t
		var base := tile_base(td)
		if not td.has("base_w"):
			td["base_w"] = base.x
			td["base_d"] = base.y
		var use := scale
		if b != null:
			var cap := float(b.call("MapMaxTileScale", base.x, base.y))
			if cap > 0.0:
				use = minf(use, cap)
		td["w"] = clampf(snappedf(base.x * use, 0.05), 2.0, 24.0)
		td["d"] = clampf(snappedf(base.y * use, 0.05), 2.0, 24.0)
	shell["board"] = board


## 地图扩容 / 改形：高度场与地表重采样，区域 / 脊线 / 装饰 / 格子按比例联动。
## 返回 [] = 成功；非空 = 拒绝（**整份底壳原样不动**，不做半成品）。
static func apply_map_size(shell: Dictionary, new_size: Vector2, scale_tiles: bool) -> Array:
	var old := size_of(shell)
	if new_size.x < 40.0 or new_size.y < 40.0 or new_size.x > 400.0 or new_size.y > 400.0:
		return ["size %.0fx%.0f outside 40..400" % [new_size.x, new_size.y]]
	if is_equal_approx(old.x, new_size.x) and is_equal_approx(old.y, new_size.y):
		return []
	var ratio := Vector2(new_size.x / maxf(old.x, 0.001), new_size.y / maxf(old.y, 0.001))

	# ---- 1. 高度场 / 地表：按归一化坐标重采样（形状不变，密度随尺寸走）----
	var old_heights := heights_or_procedural(shell)
	var old_surface := surface_index(shell)
	var old_grid := grid_of(shell)
	var old_cols := int(old_grid["cols"])
	var old_rows := int(old_grid["rows"])

	var resized: Dictionary = shell.duplicate(true)
	resized["size"] = {"x": snappedf(new_size.x, 0.01), "z": snappedf(new_size.y, 0.01)}
	var new_grid := grid_of(resized)
	var cols := int(new_grid["cols"])
	var rows := int(new_grid["rows"])
	var out_h := PackedFloat32Array()
	out_h.resize(cols * rows)
	var out_s: Array = []
	out_s.resize(cols * rows)
	for row in rows:
		for col in cols:
			var w := world_of_cell(resized, col, row)
			var u := (w.x + new_size.x * 0.5) / maxf(new_size.x, 0.001)
			var v := (w.y + new_size.y * 0.5) / maxf(new_size.y, 0.001)
			var ox := -old.x * 0.5 + u * old.x
			var oz := -old.y * 0.5 + v * old.y
			var i := row * cols + col
			out_h[i] = _height_of_arrays(old_grid, old_heights, ox, oz)
			out_s[i] = _surface_of_arrays(old_grid, old_surface, ox, oz)
	var terrain: Dictionary = resized.get("terrain", {})
	terrain["heights"] = _floats_to_array(out_h)
	resized["terrain"] = terrain
	var surf: Dictionary = resized.get("surface", {})
	surf["index"] = out_s
	resized["surface"] = surf

	# ---- 2. 区域 / 脊线：顶点按同一比例缩放（相对关系不丢）----
	var regions: Dictionary = resized.get("regions", {})
	for kind in REGION_IDS:
		var pts := region_points(resized, kind)
		var moved := PackedVector2Array()
		for p in pts:
			moved.append(Vector2(p.x * ratio.x, p.y * ratio.y))
		set_region_points(resized, kind, moved)
	resized["regions"] = regions
	var spine: Dictionary = resized.get("spine", {})
	var spts: Array = spine.get("points", [])
	for p in spts:
		var row: Dictionary = p
		row["x"] = snappedf(float(row.get("x", 0.0)) * ratio.x, 0.01)
		row["z"] = snappedf(float(row.get("z", 0.0)) * ratio.y, 0.01)
	spine["points"] = spts
	spine["width_m"] = snappedf(float(spine.get("width_logic", 420.0)) * R1, 0.001)
	resized["spine"] = spine

	# ---- 3. 装饰：位置跟着走（y 由视口按新地形重贴）----
	var decor_list: Array = resized.get("decorations", [])
	for dec in decor_list:
		var dd: Dictionary = dec
		dd["x"] = snappedf(float(dd.get("x", 0.0)) * ratio.x, 0.01)
		dd["z"] = snappedf(float(dd.get("z", 0.0)) * ratio.y, 0.01)
	resized["decorations"] = decor_list

	# ---- 4. 格子：位置按比例 + 宽深按"同步缩放"开关 ----
	var scale := float(board_of(resized)["tile_scale"]) if scale_tiles else 1.0
	var b := bridge()
	var tile_list: Array = resized.get("tiles", [])
	for t in tile_list:
		var td: Dictionary = t
		var base := tile_base(td)
		if not td.has("base_w"):
			td["base_w"] = base.x
			td["base_d"] = base.y
		var nx := snappedf(float(td.get("x", 0.0)) * ratio.x, 0.05)
		var nz := snappedf(float(td.get("z", 0.0)) * ratio.y, 0.05)
		var nw := base.x
		var nd := base.y
		if scale_tiles:
			var use := scale
			if b != null:
				var cap := float(b.call("MapMaxTileScale", base.x, base.y))
				if cap > 0.0:
					use = minf(use, cap)
			nw = clampf(snappedf(base.x * use, 0.05), 2.0, 24.0)
			nd = clampf(snappedf(base.y * use, 0.05), 2.0, 24.0)
		td["x"] = nx
		td["z"] = nz
		td["w"] = nw
		td["d"] = nd
		td["side"] = side_at(resized, nx, nz)
	resized["tiles"] = tile_list
	if scale_tiles:
		var board := board_of(resized)
		board["tile_scale"] = scale
		resized["board"] = board

	# ---- 5. 一次性替换（保持 shell 引用不变，dev_data 里那份才认得）----
	shell.clear()
	for k in resized.keys():
		shell[k] = resized[k]
	return []


static func _height_of_arrays(g: Dictionary, heights: PackedFloat32Array, x: float, z: float) -> float:
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	if heights.size() != cols * rows:
		return 0.0
	var fx := clampf((x - float(g["origin_x"])) / cell, 0.0, float(cols - 1))
	var fz := clampf((z - float(g["origin_z"])) / cell, 0.0, float(rows - 1))
	var c0 := int(floor(fx))
	var r0 := int(floor(fz))
	var c1 := mini(c0 + 1, cols - 1)
	var r1 := mini(r0 + 1, rows - 1)
	var tx := fx - float(c0)
	var tz := fz - float(r0)
	var a := lerpf(heights[r0 * cols + c0], heights[r0 * cols + c1], tx)
	var b := lerpf(heights[r1 * cols + c0], heights[r1 * cols + c1], tx)
	return lerpf(a, b, tz)


static func _surface_of_arrays(g: Dictionary, surface: Array, x: float, z: float) -> int:
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var cell := float(g["cell"])
	var col := clampi(int(round((x - float(g["origin_x"])) / cell)), 0, cols - 1)
	var row := clampi(int(round((z - float(g["origin_z"])) / cell)), 0, rows - 1)
	var i := row * cols + col
	return int(surface[i]) if i >= 0 and i < surface.size() else 0


static func _floats_to_array(values: PackedFloat32Array) -> Array:
	var out: Array = []
	out.resize(values.size())
	for i in values.size():
		out[i] = snappedf(values[i], 0.001)
	return out


# ===========================================================================
# 脊线（行军通道，只做视觉与通道宽度；分区改由多边形负责）
# ===========================================================================
static func spine_points(shell: Dictionary) -> Array:
	var spine: Dictionary = shell.get("spine", {})
	var pts: Array = spine.get("points", [])
	if pts.size() < 2:
		return [{"x": -30.0, "z": 0.0}, {"x": 30.0, "z": 0.0}]
	return pts


## 采样平滑曲线（Catmull-Rom），返回 [{x,z,dist}]；总长 = 采样弧长。
static func sample_spine(shell: Dictionary, steps: int = 96) -> Array:
	var pts := spine_points(shell)
	var out: Array = []
	var dist := 0.0
	var prev := Vector2.ZERO
	for i in steps + 1:
		var f := float(i) / float(maxi(steps, 1))
		var p := _catmull(pts, f)
		if i > 0:
			dist += p.distance_to(prev)
		out.append({"x": p.x, "z": p.y, "dist": dist})
		prev = p
	return out


static func _catmull(pts: Array, f: float) -> Vector2:
	var n := pts.size()
	if n < 2:
		return Vector2.ZERO
	var scaled := f * float(n - 1)
	var i := clampi(int(floor(scaled)), 0, n - 2)
	var t := scaled - float(i)
	var p0 := _pt(pts[maxi(i - 1, 0)])
	var p1 := _pt(pts[i])
	var p2 := _pt(pts[mini(i + 1, n - 1)])
	var p3 := _pt(pts[mini(i + 2, n - 1)])
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


static func _pt(row: Dictionary) -> Vector2:
	return Vector2(float(row.get("x", 0.0)), float(row.get("z", 0.0)))


static func point_at_t(shell: Dictionary, t: int) -> Vector2:
	var samples := sample_spine(shell, 96)
	if samples.is_empty():
		return Vector2.ZERO
	var total := float(samples[samples.size() - 1]["dist"])
	var want := float(clampi(t, 0, 999)) / T_DENOM * total
	for i in range(1, samples.size()):
		var a: Dictionary = samples[i - 1]
		var b: Dictionary = samples[i]
		if float(b["dist"]) >= want:
			var span := maxf(float(b["dist"]) - float(a["dist"]), 0.0001)
			var k := (want - float(a["dist"])) / span
			return Vector2(lerpf(float(a["x"]), float(b["x"]), k), lerpf(float(a["z"]), float(b["z"]), k))
	return Vector2(float(samples[samples.size() - 1]["x"]), float(samples[samples.size() - 1]["z"]))


static func direction_at_t(shell: Dictionary, t: int) -> Vector2:
	var a := point_at_t(shell, maxi(t - 4, 0))
	var b := point_at_t(shell, mini(t + 4, 999))
	var d := b - a
	return d.normalized() if d.length() > 0.0001 else Vector2.RIGHT


# ===========================================================================
# 势力区域（XZ 多边形）
# ===========================================================================
## JSON 里的顶点是 [x, z] 数组（Vector2 会被 JSON 序列化成字符串，不能用）。
static func region_points(shell: Dictionary, kind: String) -> PackedVector2Array:
	var out := PackedVector2Array()
	var regions: Dictionary = shell.get("regions", {})
	var arr: Array = regions.get(kind, [])
	for row in arr:
		if row is Array and (row as Array).size() >= 2:
			out.append(Vector2(float(row[0]), float(row[1])))
		elif row is Vector2:
			out.append(row)
		elif row is Dictionary:
			out.append(Vector2(float((row as Dictionary).get("x", 0.0)), float((row as Dictionary).get("z", 0.0))))
	return out


static func set_region_points(shell: Dictionary, kind: String, points: PackedVector2Array) -> void:
	var regions: Dictionary = shell.get("regions", {})
	var arr: Array = []
	for p in points:
		arr.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01)])
	regions[kind] = arr
	shell["regions"] = regions


## 新建底壳的默认三块矩形（几何在 Model 里算，这里只做 JSON 装换）。
static func default_regions(shell: Dictionary) -> Dictionary:
	var sz := size_of(shell)
	var b := bridge()
	if b == null:
		return {"player": [], "neutral": [], "enemy": []}
	var raw: Dictionary = b.call("RegionDefaults", sz.x, sz.y)
	var out: Dictionary = {}
	for kind in REGION_IDS:
		var pts: PackedVector2Array = raw.get(kind, PackedVector2Array())
		var arr: Array = []
		for p in pts:
			arr.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01)])
		out[kind] = arr
	return out


## 确保 regions 三个 kind 都有合法多边形（缺的就补默认矩形）。
static func ensure_regions(shell: Dictionary) -> bool:
	var regions: Dictionary = shell.get("regions", {})
	var changed := false
	var defaults := {}
	for kind in REGION_IDS:
		var pts := region_points(shell, kind)
		if pts.size() < 3:
			if defaults.is_empty():
				defaults = default_regions(shell)
			regions[kind] = (defaults.get(kind, []) as Array).duplicate(true)
			changed = true
	if changed:
		shell["regions"] = regions
	return changed


static func region_centroid(points: PackedVector2Array) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size())


## 点是否在区域多边形内（**Model 的唯一实现**；桥不可用返回 false）。
static func region_contains(points: PackedVector2Array, x: float, z: float) -> bool:
	var b := bridge()
	if b == null:
		return false
	var arr: Array = []
	for p in points:
		arr.append(p)
	return bool(b.call("RegionContains", arr, x, z))


static func region_validate(kind: String, points: PackedVector2Array) -> Array:
	var b := bridge()
	if b == null:
		return ["model bridge unavailable"]
	var arr: Array = []
	for p in points:
		arr.append(p)
	return b.call("RegionValidate", kind, arr) as Array


# ===========================================================================
# 战术格子（TacticalTile）
# ===========================================================================
static func tiles(shell: Dictionary) -> Array:
	return shell.get("tiles", []) as Array


static func tile_by_index(shell: Dictionary, index: int) -> Dictionary:
	for t in tiles(shell):
		if int((t as Dictionary).get("index", -1)) == index:
			return t as Dictionary
	return {}


static func next_index(shell: Dictionary) -> int:
	var best := 0
	for t in tiles(shell):
		best = maxi(best, int((t as Dictionary).get("index", 0)))
	return best + 1


## 格子的本地→世界锚点（建筑位 = 左上角，出兵位 = 正中心）。唯一实现在 Model。
static func tile_anchors(tile: Dictionary) -> Dictionary:
	var b := bridge()
	if b == null:
		return {}
	return b.call("TileAnchors", tile) as Dictionary


## 四个世界角点（视觉用；与 Model 的旋转口径一致：x' = x·cos + z·sin，z' = -x·sin + z·cos）。
static func tile_corners(tile: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	var x := float(tile.get("x", 0.0))
	var z := float(tile.get("z", 0.0))
	var hw := float(tile.get("w", TILE_SIZE_DEFAULT)) * 0.5
	var hd := float(tile.get("d", TILE_SIZE_DEFAULT)) * 0.5
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)
	for local in [Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd), Vector2(-hw, hd)]:
		out.append(Vector2(x + local.x * c + local.y * s, z - local.x * s + local.y * c))
	return out


static func tile_center_y(shell: Dictionary, tile: Dictionary) -> float:
	return float(tile.get("terrain_y", height_at(shell, float(tile.get("x", 0.0)), float(tile.get("z", 0.0)))))


## 点是否在这个格子里（编辑器拾取用；旋转按 yaw 反向还原到本地）。
static func tile_contains(tile: Dictionary, x: float, z: float) -> bool:
	var dx := x - float(tile.get("x", 0.0))
	var dz := z - float(tile.get("z", 0.0))
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)
	var lx := dx * c - dz * s
	var lz := dx * s + dz * c
	return absf(lx) <= float(tile.get("w", TILE_SIZE_DEFAULT)) * 0.5 \
		and absf(lz) <= float(tile.get("d", TILE_SIZE_DEFAULT)) * 0.5


## 两个格子的边到边间隙（米，负=重叠）。与 Model/TacticalTile.EdgeGap 同口径。
static func tile_gap(a: Dictionary, b: Dictionary) -> float:
	var ba := _tile_bounds(a)
	var bb := _tile_bounds(b)
	var dx := maxf(float(ba[0]) - float(bb[2]), float(bb[0]) - float(ba[2]))
	var dz := maxf(float(ba[1]) - float(bb[3]), float(bb[1]) - float(ba[3]))
	if dx < 0.0 and dz < 0.0:
		return maxf(dx, dz)
	return sqrt(maxf(dx, 0.0) * maxf(dx, 0.0) + maxf(dz, 0.0) * maxf(dz, 0.0))


static func _tile_bounds(tile: Dictionary) -> Array:
	var pts := tile_corners(tile)
	var min_x := float(pts[0].x)
	var max_x := min_x
	var min_z := float(pts[0].y)
	var max_z := min_z
	for p in pts:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return [min_x, min_z, max_x, max_z]


static func min_gap_meters(shell: Dictionary) -> float:
	var list := tiles(shell)
	var best := 99999.0
	for i in list.size():
		for j in range(i + 1, list.size()):
			best = minf(best, tile_gap(list[i] as Dictionary, list[j] as Dictionary))
	return best


## 纯 x 正负的兜底归属（只在地块外/区域多边形缺失时用）。
static func side_of(x: float) -> String:
	return "player" if x < 0.0 else "enemy"


## 一个点属于哪块势力区（返回 player / neutral / enemy）。
##
## **为什么不能只看 x 正负**：底壳是三列布局（玩家 / 中立 / 敌方），中立区跨 x=0，
## 只按 x 正负分会把中立格判成敌方格 —— 2026-11-22 扩容重生成时真踩到了。
## （当年的"据点玩法"已在 2026-11-25 Phase 3 整条删除，现在中立格只影响可建造区域。）
##
## 这里只做**三块区域外包矩形**的归属（编辑器摆格子的即时分类）。
## 多边形级的"点在区域内"判定仍然只有 Model/Map/RegionPolygon 一份实现。
static func side_at(shell: Dictionary, x: float, z: float) -> String:
	for kind in REGION_IDS:
		var pts := region_points(shell, kind)
		if pts.size() < 3:
			continue
		var lo := pts[0]
		var hi := pts[0]
		for p in pts:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		if x >= lo.x - 0.001 and x <= hi.x + 0.001 and z >= lo.y - 0.001 and z <= hi.y + 0.001:
			return kind
	return side_of(x)


## 局内规则：布局卡激活的格子才可建造，未激活的渲染成碎石遗迹。
static func is_active(layout: Dictionary, index: int) -> bool:
	for v in (layout.get("active_tiles", []) as Array):
		if int(v) == index:
			return true
	return false


static func slot_at(layout: Dictionary, index: int) -> Dictionary:
	for row in (layout.get("slots", []) as Array):
		if int((row as Dictionary).get("tile", -1)) == index:
			return row as Dictionary
	return {}


# ===========================================================================
# 装饰注册表（资产路径只写在 JSON；见 Content/docs/asset_manifest.md）
# ===========================================================================
static func decor_rows() -> Array:
	if _decor_loaded:
		return _decor_rows
	_decor_loaded = true
	_decor_rows = []
	var f := FileAccess.open(DECOR_TABLE, FileAccess.READ)
	if f == null:
		return _decor_rows
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_decor_rows = (parsed as Dictionary).get("kinds", []) as Array
	return _decor_rows


static func decor_row(kind: String) -> Dictionary:
	for row in decor_rows():
		if String((row as Dictionary).get("id", "")) == kind:
			return row as Dictionary
	return {}


# ===========================================================================
# 棋盘皮肤（可换皮：路径只写在 Content/data/shell_board.json）
#
# 为什么要有这张表：格子顶面 A/B、收边、地块侧壁、底面一共 5 个材质，
# 制作人换主题（草坪 → 石砖 → 沙地）时**只改这 5 条**，编辑器和局内一起换；
# 路径放 JSON 而不是源码常量，源码才能保持 ASCII（编辑器零写死中文体检）。
# ===========================================================================
const BOARD_TABLE := "res://Content/data/shell_board.json"
## 缺表时的兜底（空 = 调用方自己退回纯色，不至于崩）
const BOARD_KEYS := ["tile_a", "tile_b", "rim", "block_side", "block_bottom"]
static var _board_paths: Dictionary = {}
static var _board_loaded := false


static func board_material_paths() -> Dictionary:
	if _board_loaded:
		return _board_paths
	_board_loaded = true
	_board_paths = {}
	var f := FileAccess.open(BOARD_TABLE, FileAccess.READ)
	if f == null:
		return _board_paths
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var mats: Variant = (parsed as Dictionary).get("materials", {})
		if mats is Dictionary:
			_board_paths = mats as Dictionary
	return _board_paths


## 某个皮肤槽位的材质路径（找不到 = 空串，调用方退回纯色材质）。
static func board_material_path(key: String) -> String:
	return String(board_material_paths().get(key, ""))


## 皮肤表是否齐（校验用：少一条就报出来，别静默变灰块）。
static func board_table_errors() -> Array:
	var errs: Array = []
	for k in BOARD_KEYS:
		var p := board_material_path(k)
		if p.is_empty():
			errs.append("board_skin: missing " + k)
		elif not ResourceLoader.exists(p):
			errs.append("board_skin: " + k + " -> " + p + " not found")
	return errs


# ===========================================================================
# 校验（结构 + Model 转发）
# ===========================================================================
static func validate_shell(shell: Dictionary) -> Array:
	var bad: Array = []
	var id := String(shell.get("id", ""))
	if id.is_empty():
		bad.append("id empty")
	if String(shell.get("display_name", "")).is_empty():
		bad.append(id + " display_name empty")
	var sz := size_of(shell)
	if sz.x <= 0.0 or sz.y <= 0.0:
		bad.append(id + " size <= 0")
	var g := grid_of(shell)
	var need := int(g["cols"]) * int(g["rows"])
	var heights := heights_or_procedural(shell)
	if heights.size() != need:
		bad.append(id + " heights=%d != %d" % [heights.size(), need])
	var surf := surface_index(shell)
	if surf.size() != need:
		bad.append(id + " surface=%d != %d" % [surf.size(), need])
	var pal := palette(shell)
	if pal.size() != 4:
		bad.append(id + " palette=%d (need 4)" % pal.size())
	for i in mini(surf.size(), need):
		if int(surf[i]) < 0 or int(surf[i]) >= 4:
			bad.append(id + " surface[%d]=%d out of range" % [i, int(surf[i])])
			break
	# 底板：厚度 / 倒角 / 四周冗余 / 格子倍率（唯一实现 Model/Map/MapBoard.cs）
	for msg in board_validate(shell):
		bad.append(id + " " + String(msg))
	var amb: Dictionary = (shell.get("terrain", {}) as Dictionary).get("ambient", {})
	for k in ["energy", "tint", "fog_density"]:
		if not amb.has(k):
			bad.append(id + " ambient." + k + " missing")

	var spine: Dictionary = shell.get("spine", {})
	var length_logic := float(spine.get("length_logic", 0.0))
	if length_logic <= 0.0:
		bad.append(id + " spine.length_logic <= 0")
	if (spine.get("points", []) as Array).size() < 2:
		bad.append(id + " spine points < 2")
	var width_logic := float(spine.get("width_logic", 0.0))
	if width_logic < 100.0 or width_logic > 999.0:
		bad.append(id + " width_logic=%.0f not 3-digit" % width_logic)

	# 区域：结构 + Model 的 Point-in-Polygon 校验（顶点不足 3 个会在这里报出来）
	for kind in REGION_IDS:
		var pts := region_points(shell, kind)
		if pts.size() < 3:
			bad.append("%s region %s has %d vertices" % [id, kind, pts.size()])
			continue
		for msg in region_validate(kind, pts):
			bad.append("%s region %s: %s" % [id, kind, String(msg)])

	# 战术格子：唯一索引 / 每边最多一个主堡 / 格间留缝 / 不出图（全部在 Model 里判）
	var b := bridge()
	if b == null:
		bad.append(id + " model bridge unavailable")
	else:
		var rows: Array = []
		for t in tiles(shell):
			rows.append(t)
		for msg in (b.call("TileValidate", rows, sz.x, sz.y, MIN_GAP_M) as Array):
			bad.append(id + " tile: " + String(msg))

	for dcr in (shell.get("decorations", []) as Array):
		var dd: Dictionary = dcr
		var kind := String(dd.get("kind", ""))
		if not (kind in DECOR_KINDS):
			bad.append(id + " decor kind=" + kind + " not in registry")
		var dx := float(dd.get("x", 0.0))
		var dz := float(dd.get("z", 0.0))
		if absf(dx) > sz.x * 0.5 or absf(dz) > sz.y * 0.5:
			bad.append(id + " decor out of map")
		var sc := float(dd.get("scale", 1.0))
		if sc < 0.4 or sc > 3.0:
			bad.append(id + " decor scale=%.2f" % sc)
	return bad
