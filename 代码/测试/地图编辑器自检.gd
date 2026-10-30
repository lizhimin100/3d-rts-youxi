extends Node
## **地图编辑器自检**：不开编辑器 UI，直接验数据层 + 存读往返 + 五关校验。
## 跑法：godot --headless --path . -- --map-editor-test
##
## 验的东西（对应验收第 2/3/4 条）：
##   · 新建 160×160 地图、抬高地形、放树/金矿/兵营，存 .tres 再读回来一个都不少；
##   · JSON 导入导出往返；
##   · MapValidator 能分别报出「出生点在水里 / 金矿不可达 / 玩家重叠」。
##
## 跑完自己退出，不留临时文件。

const TMP_TRES := "user://_地图自检.tres"
const TMP_JSON := "user://_地图自检.json"

var _fails: PackedStringArray = PackedStringArray()
var _passes: int = 0


func _ready() -> void:
	await get_tree().process_frame
	print("========== 地图编辑器自检 ==========")
	_test_new_map()
	_test_new_map_building_grid()
	_test_spawn_standard()
	_test_splat_overlay()
	_test_roundtrip_tres()
	_test_roundtrip_json()
	_test_validate_ok()
	_test_validate_water_spawn()
	_test_validate_unreachable_mine()
	_test_validate_overlap()
	_cleanup()
	print("------------------------------------")
	if _fails.is_empty():
		print("地图编辑器自检：全部通过（%d 项）" % _passes)
	else:
		print("地图编辑器自检：%d 项失败" % _fails.size())
		for f in _fails:
			print("  ✘ ", f)
	get_tree().quit(0 if _fails.is_empty() else 1)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
	else:
		_fails.append(msg)
		print("  ✘ ", msg)


# ===========================================================================
# 用例
# ===========================================================================

func _test_new_map() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	_ok(m != null, "新建地图返回空")
	if m == null:
		return
	_ok(m.size == 160, "新建地图尺寸不是 160（%d）" % m.size)
	_ok(m.heightmap.size() == m.expected_height_count(), "高度场尺寸不对")
	_ok(m.splatmap.size() == m.expected_splat_count(), "地表层尺寸不对")
	_ok(m.players.size() == 2, "玩家槽位不是 2 个")
	_ok(not m.objects.is_empty(), "新建地图一个对象都没有")

	# 模拟笔刷：把出生点旁边抬 3m
	var cx: int = m.height_resolution / 2
	var cz: int = m.height_resolution / 2
	var h0: float = m.grid_height(cx, cz)
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			m.set_grid_height(cx + dx, cz + dz, h0 + 3.0)
	var w: Vector2 = m.grid_to_world(cx, cz)
	_ok(absf(m.height_at(w.x, w.y) - (h0 + 3.0)) < 0.05, "抬高地形后 height_at 没变（笔刷没生效）")

	# 放一棵树 / 一个金矿 / 一座兵营
	var res_before: int = m.objects_of(MapObject.Category.RESOURCE).size()
	var bld_before: int = m.objects_of(MapObject.Category.BUILDING).size()
	m.objects.append(MapObject.make(&"tree", MapObject.Category.RESOURCE,
		Vector3(w.x + 6.0, m.height_at(w.x + 6.0, w.y), w.y), 0.0, 1.0, -1))
	m.objects.append(MapObject.make(&"goldmine", MapObject.Category.RESOURCE,
		Vector3(w.x - 8.0, m.height_at(w.x - 8.0, w.y), w.y), 0.0, 1.0, -1))
	m.objects.append(MapObject.make(&"barracks", MapObject.Category.BUILDING,
		Vector3(w.x, m.height_at(w.x, w.y), w.y), 0.0, 1.0, 0))
	_ok(m.objects_of(MapObject.Category.RESOURCE).size() == res_before + 2, "放资源对象没进列表")
	_ok(m.objects_of(MapObject.Category.BUILDING).size() == bld_before + 1, "放建筑对象没进列表")
	print("  · 新建 + 刷地形 + 摆对象：OK（%d 对象）" % m.objects.size())


## 出生点标配：**八座建筑一个不少 / 金矿固定距离 / 树 12~17 棵 / 全图生态色块**
## 这是"玩家一进图就骂娘"的那几条，必须每次自检都验。
func _test_spawn_standard() -> void:
	var need := {"townhall": 1, "barracks": 1, "blacksmith": 1, "farm": 2, "tower": 3}
	var tmin: int = 999
	var tmax: int = 0
	for cfg in [[128, 2], [160, 2], [192, 3], [256, 4], [384, 4]]:
		var np: int = int(cfg[1])
		var m: MapDef = MapLoader.new_map(int(cfg[0]), np, 20261024)
		var biome_ok: bool = true
		for v in m.splatmap:
			if v != MapDef.SPLAT_BIOME:
				biome_ok = false
				break
		_ok(biome_ok, "%d 人图地表没有铺满生态色块" % np)
		# 和生成器同口径：树环半径随地图尺寸等比
		var kk: float = clampf(m.half_size() / 100.0, 1.0, 1.2)
		var tree_ring: float = minf(34.0 * kk, m.half_size() * 0.36)
		var gold_dists: Array[float] = []
		for p in m.players:
			var counts := {}
			var trees: int = 0
			var gmin: float = 1e9
			# 同一玩家的建筑朝向必须**完全一致**（不允许"随机朝向"混进来）
			var yaw_ref: float = 1e9
			var yaw_bad: int = 0
			for o in m.objects:
				if o == null:
					continue
				var d: float = Vector2(o.position.x, o.position.z).distance_to(p.start_pos)
				if int(o.category) == MapObject.Category.BUILDING and o.owner == p.id:
					var k: String = String(o.type_id)
					counts[k] = int(counts.get(k, 0)) + 1
					if yaw_ref > 1e8:
						yaw_ref = o.rotation
					elif absf(angle_difference(yaw_ref, o.rotation)) > 0.001:
						yaw_bad += 1
				if o.type_id == &"goldmine" and d < 45.0 and d < gmin:
					gmin = d
				if o.type_id == &"tree" and d <= tree_ring * 1.30:
					# 只算**这家自己的**树（离它比离别人近），否则 4 人图会互相借数
					var mine: bool = true
					for pj in m.players:
						if pj == p:
							continue
						if Vector2(o.position.x, o.position.z).distance_to(pj.start_pos) < d:
							mine = false
							break
					if mine:
						trees += 1
			_ok(yaw_bad == 0, "%d 人图 玩家 %d 有 %d 座建筑朝向不一致（应全部相同）"
				% [np, p.id + 1, yaw_bad])
			gold_dists.append(gmin)
			for k2 in need:
				_ok(int(counts.get(k2, 0)) == int(need[k2]),
					"%d 人图 玩家 %d 的 %s 数量是 %d（应为 %d）"
					% [np, p.id + 1, k2, int(counts.get(k2, 0)), int(need[k2])])
			_ok(trees >= 12 and trees <= 17,
				"%d 人图 玩家 %d 的树是 %d 棵（应为 12~17）" % [np, p.id + 1, trees])
			tmin = mini(tmin, trees)
			tmax = maxi(tmax, trees)
		if gold_dists.size() >= 2:
			_ok(gold_dists.max() - gold_dists.min() <= 1.5,
				"%d 人图金矿距离不一致（%.1f ~ %.1f）"
				% [np, gold_dists.min(), gold_dists.max()])
	print("  · 出生点标配（八建筑 / 金矿定距 / 树 %d~%d 棵 / 生态色块）：OK" % [tmin, tmax])


## 地表层：**必须是随机色块**（亮度要有明显落差），而且不能慢到卡手
func _test_splat_overlay() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	var t0: int = Time.get_ticks_msec()
	var ov: MeshInstance3D = MapLoader.build_splat_overlay(m)
	var dt: int = Time.get_ticks_msec() - t0
	_ok(ov != null, "生态底色地表层没生成出来")
	if ov == null:
		return
	var arrays: Array = ov.mesh.surface_get_arrays(0)
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_ok(cols.size() > 1000, "地表层顶点太少（%d）" % cols.size())
	var lo: float = 9.0
	var hi: float = -9.0
	var step: int = maxi(1, cols.size() / 4000)
	for i in range(0, cols.size(), step):
		var c: Color = cols[i]
		var lum: float = c.r * 0.30 + c.g * 0.59 + c.b * 0.11
		lo = minf(lo, lum)
		hi = maxf(hi, lum)
	# 只要有人把它改回"一格一个纯色/一张纯色贴图"，这条就会炸
	_ok(hi - lo > 0.10, "地表层颜色几乎没变化（亮度 %.3f~%.3f），又成塑料布了" % [lo, hi])
	_ok(dt < 900, "地表层生成太慢（%d ms），编辑器打开地图会卡" % dt)
	var t1: int = Time.get_ticks_msec()
	var ov2: MeshInstance3D = MapLoader.build_splat_overlay(m, 2)
	var dt2: int = Time.get_ticks_msec() - t1
	_ok(dt2 < 300, "拖动中的粗档地表层太慢（%d ms），笔刷会卡" % dt2)
	if ov2 != null:
		ov2.free()
	print("  · 地表层色块：%d 顶点 ｜ 亮度 %.3f~%.3f ｜ 精细 %d ms / 粗档 %d ms"
		% [cols.size(), lo, hi, dt, dt2])
	ov.free()


## 新建地图里的建筑必须落 1m 寻路格 + 90° 朝向（和游戏内建造共用 建筑网格）
func _test_new_map_building_grid() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	var bad_pos: int = 0
	var bad_yaw: int = 0
	var n: int = 0
	for o in m.objects:
		if o == null or int(o.category) != MapObject.Category.BUILDING:
			continue
		var d: UnitDef = MapLoader.type_def(o.type_id)
		if d == null:
			continue
		n += 1
		if not 建筑网格.is_snapped(o.position, d.footprint, m.half_size(), 建筑网格.CELL):
			bad_pos += 1
		if not 建筑网格.yaw_is_snapped(o.rotation):
			bad_yaw += 1
	_ok(bad_pos == 0, "新建地图的建筑全部压在 1m 网格锚点上（%d 座，偏离 %d 座）"
		% [n, bad_pos])
	_ok(bad_yaw == 0, "新建地图的建筑朝向全部在 90° 档（%d 座，偏 %d 座）"
		% [n, bad_yaw])
	print("  · 建筑网格：%d 座建筑全部对齐（1m 格 + 90°）" % n)


func _test_roundtrip_tres() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 424242)
	_ok(MapStore.save_tres(m, TMP_TRES) == OK, "保存 .tres 失败")
	var back: MapDef = MapStore.load_tres(TMP_TRES)
	_ok(back != null, "读回 .tres 失败")
	if back == null:
		return
	_ok(back.size == m.size, "读回后尺寸变了（%d → %d）" % [m.size, back.size])
	_ok(back.objects.size() == m.objects.size(),
		"读回后对象丢了（%d → %d）" % [m.objects.size(), back.objects.size()])
	_ok(back.players.size() == m.players.size(), "读回后玩家槽位丢了")
	_ok(back.regions.size() == m.regions.size(), "读回后区域丢了")
	_ok(back.waves.size() == m.waves.size(), "读回后波次丢了")
	_ok(back.heightmap.size() == m.heightmap.size(), "读回后高度场尺寸变了")
	_ok(back.splatmap.size() == m.splatmap.size(), "读回后地表层尺寸变了")
	var bad: int = 0
	for i in range(0, m.heightmap.size(), 97):
		if absf(back.heightmap[i] - m.heightmap[i]) > 0.0001:
			bad += 1
	_ok(bad == 0, "读回后高度场有 %d 个采样点对不上" % bad)
	var types_ok: bool = true
	for i in range(mini(back.objects.size(), m.objects.size())):
		if back.objects[i].type_id != m.objects[i].type_id:
			types_ok = false
			break
	_ok(types_ok, "读回后对象类型顺序对不上")
	print("  · .tres 存读往返：OK（%d 对象 / %d 格高度）" % [back.objects.size(), back.heightmap.size()])


func _test_roundtrip_json() -> void:
	var m: MapDef = MapLoader.new_map(128, 2, 777)
	_ok(MapStore.save_json(m, TMP_JSON) == OK, "导出 JSON 失败")
	var back: MapDef = MapStore.load_json(TMP_JSON)
	_ok(back != null, "导入 JSON 失败")
	if back == null:
		return
	_ok(back.size == m.size, "JSON 读回尺寸不对")
	_ok(back.objects.size() == m.objects.size(),
		"JSON 读回对象数量不对（%d → %d）" % [m.objects.size(), back.objects.size()])
	_ok(back.heightmap.size() == m.heightmap.size(), "JSON 读回高度场尺寸不对")
	_ok(back.version == MapDef.CURRENT_VERSION, "JSON 读回版本号不是当前版本")
	print("  · JSON 导入导出：OK")


func _test_validate_ok() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	var v: Dictionary = MapValidator.validate(m)
	var errs: PackedStringArray = v.get("errors", PackedStringArray())
	_ok(bool(v.get("ok", false)), "干净地图校验没过：" + ", ".join(errs))
	print("  · 干净地图：错误 %d 条 / 提醒 %d 条" % [errs.size(),
		(v.get("warnings", PackedStringArray()) as PackedStringArray).size()])
	for w in (v.get("warnings", PackedStringArray()) as PackedStringArray):
		print("      ⚠ ", w)


func _test_validate_water_spawn() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	var p: PlayerSlot = m.players[0]
	var h: float = m.height_at(p.start_pos.x, p.start_pos.y)
	# 出生点浇一潭水：水面高于地面 → is_water_at = true
	m.set_water_spot(p.start_pos, 14.0, h + 1.5)
	var v: Dictionary = MapValidator.validate(m)
	_ok(_has_error(v, "水"), "出生点在水里没有被报出来（errors=%s）"
		% str(v.get("errors", PackedStringArray())))
	print("  · 出生点在水里：OK")


func _test_validate_unreachable_mine() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	# 找一个离玩家 0 较远的金矿，用一圈陡墙把它围死（坡度 > 40° → 不可走）
	var target: MapObject = null
	var spawn: Vector2 = m.players[0].start_pos
	for o in m.objects:
		if o != null and o.type_id == &"goldmine":
			if Vector2(o.position.x, o.position.z).distance_to(spawn) > 30.0:
				target = o
				break
	_ok(target != null, "找不到可用于测试的金矿")
	if target == null:
		return
	var c := Vector2(target.position.x, target.position.z)
	var mine_h: float = m.height_at(c.x, c.y)
	var cell: float = m.cell_size()
	var half: float = m.half_size()
	for gz in range(m.row_points()):
		for gx in range(m.row_points()):
			var p := m.grid_to_world(gx, gz)
			var d: float = p.distance_to(c)
			if d >= 7.0 and d <= 11.0:
				m.set_grid_height(gx, gz, mine_h + 24.0)
	var v: Dictionary = MapValidator.validate(m)
	_ok(_has_error(v, "不可达") or _has_error(v, "封死"),
		"被围墙围死的金矿没有被报出来（errors=%s）"
		% str(v.get("errors", PackedStringArray())))
	print("  · 金矿不可达：OK")


func _test_validate_overlap() -> void:
	var m: MapDef = MapLoader.new_map(160, 2, 20261024)
	m.players[1].start_pos = m.players[0].start_pos
	var v: Dictionary = MapValidator.validate(m)
	_ok(_has_error(v, "重叠"), "玩家重叠没有被报出来（errors=%s）"
		% str(v.get("errors", PackedStringArray())))
	print("  · 玩家重叠：OK")


# ===========================================================================
# 工具
# ===========================================================================

func _has_error(v: Dictionary, keyword: String) -> bool:
	var errs: PackedStringArray = v.get("errors", PackedStringArray())
	for e in errs:
		if e.contains(keyword):
			return true
	return false


func _cleanup() -> void:
	for p in [TMP_TRES, TMP_JSON]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))