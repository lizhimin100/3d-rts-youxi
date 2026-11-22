extends Node3D
## 职责：把战场上的建筑（玩家布局卡 + 敌人遭遇卡 + 规划期新建）实例化成**工程里真实的 3D 模型**，
##       并按 `TacticalTile` 的规范把它们摆到格子的**左上象限建筑位**。
## 属于：Screens/world/battle（表现层）
##
## 纪律：
##   · 只用 `planning.json` 里已有的 model_path（大本营 / 兵营 / 农场 / 哨塔…），不造占位盒；
##   · **尺寸靠 AABB 归一化**：水平占地 = 单格边长的 38%~44%（唯一实现在 `RtsTileSpec`）。
##     不是"缩到格子的 92%"—— 那会把出兵位和邻格一起吃掉；
##   · 贴地靠"模型自身 AABB 的最低点"，不靠猜高度 —— 换模型不用改代码；
##   · 玩家侧建筑正面朝 +Z（面向游玩镜头），朝向增量在 `planning.json` 的 board.building 里；
##   · 阵营换色统一走 `ArtKit.apply_team_color`（铁誓资产包只染 team / team_trim）；
##   · 建筑在战斗期**不参与寻路**，这里也不做任何碰撞体。

const KEEP := &"keep"

var _arena: Dictionary = {}
var _defs: Dictionary = {}          # def_id -> {model_path, model_scale}
var _spec: Dictionary = {}          # RtsTileSpec.spec_from(planning) 的产物
var _built := {}                    # "side:tile" -> Node3D
var _measured: Array = []           # 每次 rebuild 的实测值（自检/截图断言读它）
var _player_color := Color(0.30, 0.62, 1.00)
var _enemy_color := Color(1.00, 0.32, 0.26)


func _ready() -> void:
	set_process(false)


func configure(defs: Dictionary, player_color: Color, enemy_color: Color,
		spec: Dictionary = {}) -> void:
	_defs = defs
	_player_color = player_color
	_enemy_color = enemy_color
	_spec = spec if not spec.is_empty() else RtsTileSpec.spec_from({})


func set_arena(arena: Dictionary) -> void:
	_arena = arena
	rebuild()


## 全量重建（进规划期、建筑变动时调）。数量很小（<20），不做增量。
func rebuild() -> void:
	for k in _built.keys():
		var n: Node3D = _built[k]
		if is_instance_valid(n):
			n.queue_free()
	_built.clear()
	_measured.clear()
	for b in _arena.get("player_buildings", []):
		_add(b as Dictionary, "player", _player_color)
	for b in _arena.get("enemy_buildings", []):
		_add(b as Dictionary, "enemy", _enemy_color)


func _add(row: Dictionary, side: String, team_color: Color) -> void:
	var def_id := String(row.get("building", ""))
	var tile_index := int(row.get("tile", 0))
	var tile := _tile(tile_index)
	if tile.is_empty() or def_id.is_empty():
		return
	var def: Dictionary = _defs.get(def_id, {})
	var path := String(def.get("model_path", ""))
	if path.is_empty():
		# 没有模型就不硬塞方块 —— 记一笔，界面层会把它显示成"缺模型"
		push_warning("[buildings] no model_path for " + def_id)
		return
	var scale := float(def.get("model_scale", 1.0))
	var model: Node3D = ArtKit.build_model(path, scale, Vector3(6.0, 5.0, 6.0))
	if model == null:
		return
	var holder := Node3D.new()
	holder.name = "B_%s_%d" % [def_id, tile_index]
	holder.add_child(model)
	add_child(holder)

	# 模型自身 AABB（holder 局部空间，不含 holder 自己的变换）→
	# 用它把"占地"归一化到单格边长的 38%~44%，再把底面贴到格子高度。
	var box := _bounds_of(holder)
	var ratio := float(def.get("footprint_ratio", _spec.get("footprint_ratio", RtsTileSpec.FOOTPRINT_DEFAULT)))
	var k := RtsTileSpec.fit_scale(box.size, float(tile.get("w", 7.0)), float(tile.get("d", 7.0)), ratio)
	holder.scale = Vector3(k, k, k)
	# 底座中心 → 格子左上象限；锚点仍以 Model 的左上角角点为准
	var ax := float(tile.get("building_x", tile.get("x", 0.0)))
	var az := float(tile.get("building_z", tile.get("z", 0.0)))
	var c := RtsTileSpec.center(tile, Vector2(ax, az), _spec)
	holder.position = Vector3(c.x, float(tile.get("terrain_y", 0.0)) - box.position.y * k, c.y)
	holder.rotation.y = deg_to_rad(RtsTileSpec.yaw_deg(tile, _spec, side))
	ArtKit.apply_team_color(holder, team_color)
	_built["%s:%d" % [side, tile_index]] = holder
	_record(side, def_id, tile, holder, box, k)


func _tile(index: int) -> Dictionary:
	for t in _arena.get("tiles", []):
		var d: Dictionary = t
		if int(d.get("index", 0)) == index:
			return d
	return {}


# ===========================================================================
# 实测：建筑到底多大、站哪、朝哪（自检读这里，不看配置也不看源码）
# ===========================================================================
#
# 为什么要在运行时量：`footprint_ratio` 只是"想要多少"，真正落到画面上的是
# "模型 AABB × 归一化系数"。中间任何一个环节错了（AABB 取错、缩放顺序反了、
# LOD 组把三档包围盒合并了），配置依然是 0.38，画面却是另一个尺寸 ——
# 所以断言必须量**摆上去之后的世界尺寸**。
func _record(side: String, def_id: String, tile: Dictionary, holder: Node3D,
		box: AABB, k: float) -> void:
	var tw := maxf(float(tile.get("w", 7.0)), 0.01)
	var td := maxf(float(tile.get("d", 7.0)), 0.01)
	var span_x := box.size.x * k
	var span_z := box.size.z * k
	var yaw := holder.rotation.y
	var ac := absf(cos(yaw))
	var as_ := absf(sin(yaw))
	var ex := span_x * 0.5 * ac + span_z * 0.5 * as_
	var ez := span_x * 0.5 * as_ + span_z * 0.5 * ac
	var tx := float(tile.get("x", 0.0))
	var tz := float(tile.get("z", 0.0))
	var cx := holder.position.x
	var cz := holder.position.z
	var inside := (cx - ex >= tx - tw * 0.5 - 0.02) and (cx + ex <= tx + tw * 0.5 + 0.02) \
		and (cz - ez >= tz - td * 0.5 - 0.02) and (cz + ez <= tz + td * 0.5 + 0.02)
	_measured.append({
		"def": def_id,
		"side": side,
		"tile": int(tile.get("index", 0)),
		# 水平占地 / 单格短边（口径与 RtsTileSpec.fit_scale 一致）
		"ratio": maxf(span_x, span_z) / minf(tw, td),
		# 底座中心相对格中心的本地偏移（以格边长为单位，负 = 左上）
		"off_u": (cx - tx) / tw,
		"off_v": (cz - tz) / td,
		"yaw": rad_to_deg(yaw),
		"inside": inside,
		"height": box.size.y * k,
	})


## 实测摘要（一行）：截图断言 `expect_scene_state: ["space_probe", "..."]` 读它。
func measure_text() -> String:
	if _measured.is_empty():
		return "n=0 space_ok=0"
	var lo := 9.0
	var hi := -9.0
	var inside := 0
	var yaw_p := 0.0
	var yaw_e := 0.0
	var uv := Vector2.ZERO
	for m in _measured:
		var row: Dictionary = m
		lo = minf(lo, float(row.get("ratio", 0.0)))
		hi = maxf(hi, float(row.get("ratio", 0.0)))
		if bool(row.get("inside", false)):
			inside += 1
		if String(row.get("side", "")) == "player":
			yaw_p = float(row.get("yaw", 0.0))
			uv = Vector2(float(row.get("off_u", 0.0)), float(row.get("off_v", 0.0)))
		else:
			yaw_e = float(row.get("yaw", 0.0))
	var want_u := float(_spec.get("anchor_u", RtsTileSpec.ANCHOR_U_DEFAULT))
	var want_v := float(_spec.get("anchor_v", RtsTileSpec.ANCHOR_V_DEFAULT))
	var ok := lo >= RtsTileSpec.FOOTPRINT_MIN - 0.006 and hi <= RtsTileSpec.FOOTPRINT_MAX + 0.006 \
		and absf(uv.x - want_u) <= 0.02 and absf(uv.y - want_v) <= 0.02 \
		and inside == _measured.size() \
		and absf(rad_to_deg(deg_to_rad(yaw_p)) - 180.0) <= 2.0
	return "n=%d ratio=%.3f..%.3f uv=%.2f,%.2f yaw_p=%.0f yaw_e=%.0f inside=%d/%d space_ok=%d" % [
		_measured.size(), lo, hi, uv.x, uv.y, yaw_p, yaw_e, inside, _measured.size(),
		1 if ok else 0]


## 递归合并所有 MeshInstance3D 的 AABB（换算到 root 的局部空间）
func _bounds_of(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var inv := root.global_transform.affine_inverse()
	for mi in _mesh_instances(root):
		var aabb: AABB = mi.get_aabb()
		var xf: Transform3D = inv * mi.global_transform
		var g := _xf_aabb(aabb, xf)
		if first:
			out = g
			first = false
		else:
			out = out.merge(g)
	if first:
		return AABB(Vector3(-2.0, 0.0, -2.0), Vector3(4.0, 4.0, 4.0))
	return out


## Godot 4 的 AABB 没有 transform()：换 8 个角点再重建包围盒。
func _xf_aabb(aabb: AABB, xf: Transform3D) -> AABB:
	var out := AABB(xf * aabb.position, Vector3.ZERO)
	for i in 8:
		var p := aabb.position + Vector3(
			aabb.size.x * float(i & 1),
			aabb.size.y * float((i >> 1) & 1),
			aabb.size.z * float((i >> 2) & 1))
		out = out.expand(xf * p)
	return out


func _mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_mesh_instances(c))
	return out


## 自检用：当前重建出来的建筑实例数（口径 = 真的有人站在场上）
func instance_count() -> int:
	var n := 0
	for k in _built.keys():
		if is_instance_valid(_built[k]):
			n += 1
	return n
