@tool
extends RefCounted
## 地图底壳（MapShell）的几何与契约：R1 换算、脊线分割环、石台锚点、地形高度场、校验。
## 属于：Screens/editor（开发工具，不进发行版）
##
## 纪律：
##   · 这里是底壳几何的唯一实现：三维底壳编辑器、数据工作台、生成脚本都调它，不各写一份；
##   · 只做纯函数，不读文件（读写统一走 dev_data.gd）；
##   · 源码零写死中文：显示名一律来自 Content/data/*.json 或 ui.csv。
##
## 方位：x 向右（-size.x/2 .. +size.x/2），z 向玩家（-size.z/2 .. +size.z/2），y 向上。
## 玩家区在左（x < 0），敌方区在右（x > 0）。

const R1 := 0.015
const CELL := 1.5
const WATER_DEFAULT := 0.2
const BASE_H := 0.9
const MIN_GAP_M := 1.5
const T_DENOM := 1000.0

const DIVIDER_IDS := ["player_zone_end", "neutral_center", "push_line", "base_cross_line"]
const DIVIDER_KEYS := {
	"player_zone_end": "shell.divider.player_end",
	"neutral_center": "shell.divider.neutral",
	"push_line": "shell.divider.push",
	"base_cross_line": "shell.divider.base_cross",
}
const PLATFORM_SIDES := ["player", "enemy"]
const PLATFORM_ROLES := ["keep", "build"]
const DECOR_KINDS := ["tree", "rock", "fence", "flag", "stump", "crate"]
const DECOR_TINT := {
	"tree": Color("#4C6B3C"),
	"rock": Color("#6E7480"),
	"fence": Color("#8A6A42"),
	"flag": Color("#C8A34D"),
	"stump": Color("#7A5C36"),
	"crate": Color("#8C6B3F"),
}
const PALETTE_FALLBACK := [
	{"id": "grass", "color": "#5D6B3F"},
	{"id": "dirt", "color": "#6B5A43"},
	{"id": "rock", "color": "#5A5F68"},
	{"id": "sand", "color": "#8A7A56"},
]


# ===========================================================================
# R1 与分割环
# ===========================================================================
static func logic_of(meters: float) -> float:
	return roundf(meters / R1)


static func meters_of(logic: float) -> float:
	return logic * R1


static func t_of_logic(logic: float, length_logic: float) -> int:
	if length_logic <= 0.0:
		return 0
	return clampi(int(floor(logic / length_logic * T_DENOM)), 0, 999)


static func logic_of_t(t: int, length_logic: float) -> float:
	return roundf(float(clampi(t, 0, 999)) / T_DENOM * length_logic)


static func divider(shell: Dictionary, id: String) -> Dictionary:
	var spine: Dictionary = shell.get("spine", {})
	var divs: Dictionary = spine.get("dividers", {})
	return divs.get(id, {}) as Dictionary


static func set_divider_t(shell: Dictionary, id: String, t: int) -> void:
	var spine: Dictionary = shell.get("spine", {})
	if not spine.has("dividers"):
		spine["dividers"] = {}
	var divs: Dictionary = spine.get("dividers", {})
	if not divs.has(id):
		divs[id] = {"display_name": ""}
	var length_logic := float(spine.get("length_logic", 4000.0))
	var row: Dictionary = divs[id]
	row["t"] = clampi(t, 0, 999)
	row["length_logic"] = logic_of_t(int(row["t"]), length_logic)
	row["meters"] = meters_of(float(row["length_logic"]))


static func sorted_dividers(shell: Dictionary) -> Array:
	var out: Array = []
	for id in DIVIDER_IDS:
		var d := divider(shell, id)
		if not d.is_empty():
			out.append({"id": id, "t": int(d.get("t", 0)), "logic": float(d.get("length_logic", 0.0))})
	out.sort_custom(func(a, b): return int(a["t"]) < int(b["t"]))
	return out


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


## 未雕刻时的初始起伏：通道两侧抬成坡，走廊本身基本平（0.9 m 上下）。
static func procedural_height(seed_value: int, x: float, z: float) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var p1 := rng.randf_range(0.0, TAU)
	var p2 := rng.randf_range(0.0, TAU)
	var p3 := rng.randf_range(0.0, TAU)
	var ridge := 0.45 * sin(x * 0.13 + p1) + 0.35 * cos(z * 0.17 + p2) + 0.20 * sin((x + z) * 0.09 + p3)
	var bank := smoothstep(2.0, 14.0, absf(z))
	var h := 0.9 + 2.4 * (0.35 + ridge) * bank
	return clampf(h, -1.2, 4.5)


static func heights_or_procedural(shell: Dictionary) -> PackedFloat32Array:
	var g := grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var have: Array = (shell.get("terrain", {}) as Dictionary).get("heights", [])
	var out := PackedFloat32Array()
	out.resize(cols * rows)
	var seed_value := int(shell.get("seed", 1))
	if have.size() == cols * rows:
		for i in cols * rows:
			out[i] = float(have[i])
		return out
	for row in rows:
		for col in cols:
			var w := world_of_cell(shell, col, row)
			out[row * cols + col] = procedural_height(seed_value, w.x, w.y)
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
	var out: Array = []
	out.resize(cols * rows)
	for row in rows:
		for col in cols:
			var w := world_of_cell(shell, col, row)
			var idx := 0
			if absf(w.y) <= 5.0:
				idx = 1
			out[row * cols + col] = idx
	return out


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
# 脊线
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
# 石台锚点
# ===========================================================================
static func platforms(shell: Dictionary) -> Array:
	return shell.get("platforms", []) as Array


static func platform_by_index(shell: Dictionary, index: int) -> Dictionary:
	for p in platforms(shell):
		if int((p as Dictionary).get("index", -1)) == index:
			return p as Dictionary
	return {}


static func next_index(shell: Dictionary) -> int:
	var best := 0
	for p in platforms(shell):
		best = maxi(best, int((p as Dictionary).get("index", 0)))
	return best + 1


static func platform_top_y(platform: Dictionary) -> float:
	return float(platform.get("terrain_y", 0.0)) + float(platform.get("base_h", BASE_H))


static func min_gap_meters(shell: Dictionary) -> float:
	var list := platforms(shell)
	var best := 99999.0
	for i in list.size():
		var a: Dictionary = list[i]
		for j in range(i + 1, list.size()):
			var b: Dictionary = list[j]
			var dx := float(a.get("x", 0.0)) - float(b.get("x", 0.0))
			var dz := float(a.get("z", 0.0)) - float(b.get("z", 0.0))
			var edge := sqrt(dx * dx + dz * dz) - float(a.get("radius", 0.0)) - float(b.get("radius", 0.0))
			best = minf(best, edge)
	return best


static func side_of(x: float) -> String:
	return "player" if x < 0.0 else "enemy"


## 局内规则：布局卡激活的石台才可建造，未激活的渲染成碎石遗迹。
static func is_active(layout: Dictionary, index: int) -> bool:
	for v in (layout.get("active_platforms", []) as Array):
		if int(v) == index:
			return true
	return false


static func slot_at(layout: Dictionary, index: int) -> Dictionary:
	for row in (layout.get("slots", []) as Array):
		if int((row as Dictionary).get("platform", -1)) == index:
			return row as Dictionary
	return {}


# ===========================================================================
# 校验
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
	var water := float((shell.get("terrain", {}) as Dictionary).get("water_level", WATER_DEFAULT))
	if water < -5.0 or water > 10.0:
		bad.append(id + " water_level out of range")
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
	var last_t := -1
	for did in DIVIDER_IDS:
		var d := divider(shell, did)
		if d.is_empty():
			bad.append(id + " divider " + did + " missing")
			continue
		var t := int(d.get("t", -1))
		if t < 100 or t > 999:
			bad.append(id + " divider " + did + " t=%d not 3-digit" % t)
			continue
		if t <= last_t:
			bad.append(id + " divider " + did + " t=%d out of order" % t)
		last_t = t
		var logic := float(d.get("length_logic", -1.0))
		var meters := float(d.get("meters", -1.0))
		if absf(logic - logic_of_t(t, length_logic)) > 0.5:
			bad.append(id + " divider " + did + " logic=%.0f != t-derived %.0f" % [logic, logic_of_t(t, length_logic)])
		if absf(meters - meters_of(logic)) > 0.0001:
			bad.append(id + " divider " + did + " meters=%.3f != logic×R1" % meters)

	var seen := {}
	var keep_by_side := {"player": 0, "enemy": 0}
	for p in platforms(shell):
		var pd: Dictionary = p
		var idx := int(pd.get("index", -1))
		if idx < 1:
			bad.append(id + " platform index=" + str(idx))
			continue
		if seen.has(idx):
			bad.append(id + " platform index dup " + str(idx))
		seen[idx] = true
		var side := String(pd.get("side", ""))
		if not (side in PLATFORM_SIDES):
			bad.append(id + " p%d side=%s" % [idx, side])
		var role := String(pd.get("role", ""))
		if not (role in PLATFORM_ROLES):
			bad.append(id + " p%d role=%s" % [idx, role])
		if role == "keep":
			keep_by_side[side] = int(keep_by_side.get(side, 0)) + 1
		var radius := float(pd.get("radius", 0.0))
		if radius < 1.0 or radius > 6.0:
			bad.append(id + " p%d radius=%.2f" % [idx, radius])
		var bh := float(pd.get("base_h", 0.0))
		if bh < 0.4:
			bad.append(id + " p%d base_h=%.2f (floating)" % [idx, bh])
		var px := float(pd.get("x", 0.0))
		var pz := float(pd.get("z", 0.0))
		if absf(px) > sz.x * 0.5 or absf(pz) > sz.y * 0.5:
			bad.append(id + " p%d out of map" % idx)
		if side_of(px) != side:
			bad.append(id + " p%d x=%.1f contradicts side=%s" % [idx, px, side])
		var ty := float(pd.get("terrain_y", 0.0))
		if absf(ty - height_at(shell, px, pz)) > 0.3:
			bad.append(id + " p%d terrain_y=%.2f != height %.2f" % [idx, ty, height_at(shell, px, pz)])
	if keep_by_side["player"] != 1:
		bad.append(id + " player keep anchors=%d (need 1)" % keep_by_side["player"])
	if keep_by_side["enemy"] != 1:
		bad.append(id + " enemy keep anchors=%d (need 1)" % keep_by_side["enemy"])
	var gap := min_gap_meters(shell)
	if gap < MIN_GAP_M:
		bad.append(id + " min gap=%.2f m < %.1f" % [gap, MIN_GAP_M])

	for dcr in (shell.get("decorations", []) as Array):
		var dd: Dictionary = dcr
		var kind := String(dd.get("kind", ""))
		if not (kind in DECOR_KINDS):
			bad.append(id + " decor kind=" + kind + " not visual-only")
		var dx := float(dd.get("x", 0.0))
		var dz := float(dd.get("z", 0.0))
		if absf(dx) > sz.x * 0.5 or absf(dz) > sz.y * 0.5:
			bad.append(id + " decor out of map")
		var sc := float(dd.get("scale", 1.0))
		if sc < 0.4 or sc > 3.0:
			bad.append(id + " decor scale=%.2f" % sc)
	return bad
