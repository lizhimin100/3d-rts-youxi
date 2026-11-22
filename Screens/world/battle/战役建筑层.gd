extends Node3D
## 职责：把战场上的建筑（玩家布局卡 + 敌人遭遇卡 + 规划期新建）实例化成**工程里真实的 3D 模型**，
##       并按 `TacticalTile` 的规范把它们摆到格子的**左上角建筑位**。
## 属于：Screens/world/battle（表现层）
##
## 纪律：
##   · 只用 `planning.json` 里已有的 model_path（大本营 / 兵营 / 农场 / 哨塔…），不造占位盒；
##   · 贴地靠"模型自身 AABB 的最低点"，不靠猜高度 —— 换模型不用改代码；
##   · 阵营换色统一走 `ArtKit.apply_team_color`（铁誓资产包只染 team / team_trim）；
##   · 建筑在战斗期**不参与寻路**，这里也不做任何碰撞体。

const KEEP := &"keep"

var _arena: Dictionary = {}
var _defs: Dictionary = {}          # def_id -> {model_path, model_scale}
var _built := {}                    # "side:tile" -> Node3D
var _player_color := Color(0.30, 0.62, 1.00)
var _enemy_color := Color(1.00, 0.32, 0.26)


func _ready() -> void:
	set_process(false)


func configure(defs: Dictionary, player_color: Color, enemy_color: Color) -> void:
	_defs = defs
	_player_color = player_color
	_enemy_color = enemy_color


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
	# 用它把"footprint 左上角"对到格子的建筑锚点（TacticalTile 的唯一口径）。
	var box := _bounds_of(holder)
	# 模型比格子大就等比缩到格子里：建筑必须是"占一格"，不能压到邻格去。
	var tw := float(tile.get("w", 7.0)) * 0.92
	var td := float(tile.get("d", 7.0)) * 0.92
	var k := 1.0
	if box.size.x > tw or box.size.z > td:
		k = minf(tw / maxf(box.size.x, 0.01), td / maxf(box.size.z, 0.01))
		holder.scale = Vector3(k, k, k)
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var ax := float(tile.get("building_x", tile.get("x", 0.0)))
	var az := float(tile.get("building_z", tile.get("z", 0.0)))
	# 左上角对齐：把包围盒左上角（-X/-Z）搬到锚点，等价于中心偏移 (+w/2, +d/2)
	var off := Vector3(box.size.x * 0.5 * k, 0.0, box.size.z * 0.5 * k).rotated(Vector3.UP, yaw)
	holder.position = Vector3(ax + off.x, float(tile.get("terrain_y", 0.0)) - box.position.y * k, az + off.z)
	holder.rotation.y = yaw
	ArtKit.apply_team_color(holder, team_color)
	_built["%s:%d" % [side, tile_index]] = holder


func _tile(index: int) -> Dictionary:
	for t in _arena.get("tiles", []):
		var d: Dictionary = t
		if int(d.get("index", 0)) == index:
			return d
	return {}


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
