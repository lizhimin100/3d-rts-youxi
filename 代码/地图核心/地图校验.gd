@tool
class_name MapValidator
extends RefCounted
## **地图校验**：保存前自动跑，五道硬关 + 若干提醒。
##
## 五关（一条都不能少）：
##   1. 出生点可走：不在水里、不在陡坡上、附近有可站立格；
##   2. 金矿 / 树可达：从玩家 0 出生点 BFS，资源旁边那一格必须连通；
##   3. 玩家不重叠：两个出生点不能贴在一起；
##   4. 边界合法：对象 / 区域 / 出生点 / 相机边界都在地图内；
##   5. 至少一个敌方出生点（不同队伍）。
##
## 返回：{"ok": bool, "errors": PackedStringArray, "warnings": PackedStringArray, "stats": Dictionary}
## errors 非空 = 这张图不能玩，界面上红字列出来；warnings = 能跑但建议改。

## 出生点之间最小距离（米）：两个基地的营区半径各 12m 左右，再近就互相压建筑
const MIN_PLAYER_DISTANCE: float = 26.0
## 出生点"偏近"提醒阈值
const NEAR_PLAYER_DISTANCE: float = 42.0
## 出生点附近找可走格的最远搜索半径（格）
const SPAWN_SEARCH_CELLS: int = 10


static func validate(m: MapDef) -> Dictionary:
	var errors := PackedStringArray()
	var warnings := PackedStringArray()
	var stats: Dictionary = {}
	if m == null:
		errors.append("地图数据为空")
		return _result(errors, warnings, stats)
	m.ensure_arrays()

	var mask: PackedByteArray = MapLoader.build_walkable_mask(m)
	var w: int = maxi(8, m.size)
	stats["size"] = m.size
	stats["objects"] = m.objects.size()
	stats["walkable_cells"] = _count_nonzero(mask)
	var hb: Vector2 = m.height_bounds()
	stats["height_min"] = hb.x
	stats["height_max"] = hb.y

	# ------------------------------------------------------------------
	# 1. 出生点可走
	# ------------------------------------------------------------------
	if m.players.is_empty():
		errors.append("没有任何玩家槽位（至少要有 1 个己方 + 1 个敌方出生点）")
	for p in m.players:
		if p == null:
			continue
		var tag: String = "玩家 %d" % p.id
		var sp: Vector2 = p.start_pos
		if not m.in_bounds(sp, 1.0):
			errors.append("%s 的出生点在边界外（%.1f, %.1f）" % [tag, sp.x, sp.y])
			continue
		if m.is_water_at(sp):
			errors.append("%s 的出生点在水里（%.1f, %.1f）" % [tag, sp.x, sp.y])
		var slope: float = m.slope_degrees_at(sp.x, sp.y)
		if slope > MapLoader.WALK_SLOPE_LIMIT_DEG:
			errors.append("%s 的出生点在陡坡上（%.0f° > %.0f°）"
				% [tag, slope, MapLoader.WALK_SLOPE_LIMIT_DEG])
		var cell: Vector2i = MapLoader.world_cell(m, sp)
		var near: Vector2i = MapLoader.nearest_walkable(mask, w, cell, SPAWN_SEARCH_CELLS)
		if near.x < 0:
			errors.append("%s 的出生点周围 %.0fm 内没有可站立的地面"
				% [tag, float(SPAWN_SEARCH_CELLS)])
		else:
			var d: float = Vector2(float(near.x) + 0.5 - float(w) * 0.5,
				float(near.y) + 0.5 - float(w) * 0.5).distance_to(sp)
			# 出生点中心通常被大本营占地压着（10×10 + 净空），吸附到营地门口是正常的；
			# 只有连营地外圈都找不到地面（>12m）才值得提醒。
			if d > 12.0:
				warnings.append("%s 的出生点周围可站立地面离得较远（%.1fm），部队会被挤到远处"
					% [tag, d])

	# ------------------------------------------------------------------
	# 2. 金矿 / 树可达
	# ------------------------------------------------------------------
	var start_cell := Vector2i(-1, -1)
	if not m.players.is_empty() and m.players[0] != null:
		start_cell = MapLoader.nearest_walkable(mask, w,
			MapLoader.world_cell(m, m.players[0].start_pos), SPAWN_SEARCH_CELLS)
	var seen := PackedByteArray()
	if start_cell.x >= 0:
		seen = MapLoader.reachable_mask(mask, w, start_cell)
	stats["reachable_cells"] = _count_nonzero(seen)

	var mines: int = 0
	var trees: int = 0
	var unreachable_res: PackedStringArray = PackedStringArray()
	var sealed_res: PackedStringArray = PackedStringArray()
	for o in m.objects:
		if o == null or int(o.category) != MapObject.Category.RESOURCE:
			continue
		var is_mine: bool = o.type_id == &"goldmine"
		var is_tree: bool = o.type_id == &"tree"
		if is_mine:
			mines += 1
		elif is_tree:
			trees += 1
		if start_cell.x < 0:
			continue
		var rp := Vector2(o.position.x, o.position.z)
		var rc: Vector2i = MapLoader.world_cell(m, rp)
		var near_r: Vector2i = MapLoader.nearest_walkable(mask, w, rc, 10)
		if near_r.x < 0:
			sealed_res.append("%s@(%.1f,%.1f)" % [String(o.type_id), rp.x, rp.y])
		elif seen[near_r.y * w + near_r.x] == 0:
			unreachable_res.append("%s@(%.1f,%.1f)" % [String(o.type_id), rp.x, rp.y])
	stats["mines"] = mines
	stats["trees"] = trees
	if mines == 0:
		errors.append("地图上没有任何金矿（玩家采集不到金子，打不下去）")
	if trees == 0:
		warnings.append("地图上没有任何树木（木材只能靠初始资源）")
	if not sealed_res.is_empty():
		errors.append("有 %d 个资源被完全封死（四周无可走格）：%s"
			% [sealed_res.size(), _head(sealed_res, 4)])
	if not unreachable_res.is_empty():
		errors.append("有 %d 个资源从玩家 0 出生点不可达：%s"
			% [unreachable_res.size(), _head(unreachable_res, 4)])

	# ------------------------------------------------------------------
	# 3. 玩家不重叠
	# ------------------------------------------------------------------
	for i in range(m.players.size()):
		for j in range(i + 1, m.players.size()):
			var a: PlayerSlot = m.players[i]
			var b: PlayerSlot = m.players[j]
			if a == null or b == null:
				continue
			var dist: float = a.start_pos.distance_to(b.start_pos)
			if dist < MIN_PLAYER_DISTANCE:
				errors.append("玩家 %d 与玩家 %d 出生点重叠（相距 %.1fm < %.0fm）"
					% [a.id, b.id, dist, MIN_PLAYER_DISTANCE])
			elif dist < NEAR_PLAYER_DISTANCE:
				warnings.append("玩家 %d 与玩家 %d 出生点偏近（相距 %.1fm）"
					% [a.id, b.id, dist])

	# ------------------------------------------------------------------
	# 4. 边界合法
	# ------------------------------------------------------------------
	var out_objs: int = 0
	for o in m.objects:
		if o == null:
			continue
		if not m.in_bounds(Vector2(o.position.x, o.position.z), 0.0):
			out_objs += 1
	if out_objs > 0:
		errors.append("有 %d 个对象摆在地图边界外" % out_objs)
	for r in m.regions:
		if r == null:
			continue
		for pt in r.points:
			if not m.in_bounds(pt, -0.5):
				errors.append("区域「%s」有顶点越界（%.1f, %.1f）" % [r.id, pt.x, pt.y])
				break
	if m.camera_bounds.size.x <= 0.0 or m.camera_bounds.size.y <= 0.0:
		warnings.append("镜头边界尺寸为 0，进游戏会被夹到一个点上")
	else:
		var cb: Rect2 = m.camera_bounds
		var limit: Rect2 = Rect2(Vector2(-m.half_size(), -m.half_size()),
			Vector2(m.size, m.size))
		if not limit.encloses(cb):
			warnings.append("镜头边界超出地图范围（进游戏会被夹回地图内）")

	# ------------------------------------------------------------------
	# 5. 至少一个敌方出生点
	# ------------------------------------------------------------------
	var enemy_found: bool = false
	if not m.players.is_empty() and m.players[0] != null:
		var own_team: int = m.players[0].team
		for p in m.players:
			if p != null and p.id != m.players[0].id and p.team != own_team:
				enemy_found = true
				break
	if not enemy_found:
		errors.append("没有敌方出生点（至少要有一个不同队伍的玩家槽位）")

	# ------------------------------------------------------------------
	# 附加提醒（不拦保存）
	# ------------------------------------------------------------------
	var grid_off: int = 0
	var yaw_off: int = 0
	var scaled_buildings: int = 0
	for o in m.objects:
		if o == null:
			continue
		if int(o.category) in [MapObject.Category.UNIT, MapObject.Category.BUILDING]:
			var d: UnitDef = MapLoader.type_def(o.type_id)
			if d == null:
				warnings.append("未知单位/建筑类型 id：%s" % String(o.type_id))
			elif int(o.category) == MapObject.Category.BUILDING:
				# 建筑必须和寻路网格共用同一套 1m 格 + 90° 朝向（旧图会在这里被点出来）
				if not 建筑网格.is_snapped(o.position, d.footprint, m.half_size(),
						GridPathfinder.CELL):
					grid_off += 1
				if not 建筑网格.yaw_is_snapped(o.rotation):
					yaw_off += 1
				if absf(o.scale - 1.0) > 0.01:
					scaled_buildings += 1
	if grid_off > 0:
		warnings.append("有 %d 座建筑没对齐 1m 建造网格（打开编辑器保存时会自动修正）" % grid_off)
	if yaw_off > 0:
		warnings.append("有 %d 座建筑朝向不是 90° 的整数倍（打开编辑器保存时会自动修正）" % yaw_off)
	if scaled_buildings > 0:
		warnings.append("有 %d 座建筑用了非 1.0 缩放（占地仍按原始 footprint 算，可能和寻路格错位）"
			% scaled_buildings)
	# 野怪营地锚点：**必须是中立**（owner = -1）。
	# 营地系统只扫中立阵营的建筑；锚点挂到玩家 1 身上 → 进图一只怪都不刷，
	# 而且玩家完全看不出原因（玩家口径 2026-11-06「摆了营地但不刷怪」）。
	var CAMP_TABLE := preload("res://代码/配置/野怪营地表.gd")
	var wrong_owner: PackedStringArray = PackedStringArray()
	for o in m.objects:
		if o == null or int(o.category) != MapObject.Category.BUILDING:
			continue
		if CAMP_TABLE.for_den(o.type_id) == null:
			continue
		if o.owner >= 0:
			wrong_owner.append("%s@(%.0f,%.0f)" % [String(o.type_id), o.position.x, o.position.z])
	if not wrong_owner.is_empty():
		warnings.append("有 %d 个野怪营地锚点不是中立（进图不会刷怪）：%s"
			% [wrong_owner.size(), _head(wrong_owner, 4)])

	# 旧版本编辑器曾把单位/建筑类型错放进「装饰」类：这里点出来（不拦保存，打开编辑器会自动分好层）
	var misplaced_doodads: PackedStringArray = PackedStringArray()
	for o in m.objects:
		if o == null or int(o.category) != MapObject.Category.DOODAD:
			continue
		var ud: UnitDef = MapLoader.type_def(o.type_id)
		if ud != null and ud.kind in [RtsConst.Kind.UNIT, RtsConst.Kind.BUILDING]:
			misplaced_doodads.append(String(o.type_id))
	if not misplaced_doodads.is_empty():
		warnings.append("有 %d 个装饰其实是单位/建筑类型（旧版本遗留）：%s"
			% [misplaced_doodads.size(), _head(misplaced_doodads, 4)])

	var region_ids: Dictionary = {}
	for r in m.regions:
		if r != null:
			region_ids[r.id] = true
	for wv in m.waves:
		if wv == null:
			continue
		if not wv.spawn_region.is_empty() and not region_ids.has(wv.spawn_region):
			warnings.append("波次 %.0fs 引用了不存在的出生区域「%s」" % [wv.time, wv.spawn_region])
		if not wv.target_region.is_empty() and not region_ids.has(wv.target_region):
			warnings.append("波次 %.0fs 引用了不存在的目标区域「%s」" % [wv.time, wv.target_region])
		if wv.total_units() <= 0:
			warnings.append("波次 %.0fs 的兵种组成为空" % wv.time)
	if hb.y - hb.x > 60.0:
		warnings.append("地形高差 %.0fm 偏大，单位可能走到奇怪的地方" % (hb.y - hb.x))

	return _result(errors, warnings, stats)


static func _result(errors: PackedStringArray, warnings: PackedStringArray,
		stats: Dictionary) -> Dictionary:
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"stats": stats,
	}


static func _count_nonzero(a: PackedByteArray) -> int:
	var n: int = 0
	for v in a:
		if v != 0:
			n += 1
	return n


static func _head(arr: PackedStringArray, n: int) -> String:
	var out: PackedStringArray = PackedStringArray()
	for i in range(mini(n, arr.size())):
		out.append(arr[i])
	var s: String = ", ".join(out)
	if arr.size() > n:
		s += " …"
	return s