@tool
extends RefCounted
## **编辑会话**：编辑器的唯一状态中心。
##
## 主屏（3D 视口）、停靠面板（工具/对象/属性/校验）都只跟这个对象说话：
##   · 所有编辑都改 `def`（MapDef），改完发 `def_changed(reason)` 让视口重建对应那一层；
##   · 所有可撤销操作都走 EditorUndoRedoManager（编辑器自带的那套，不自己造轮子）；
##   · 地形笔刷按"一笔一条"合并：按下时快照，松开时提交一条 action。

signal def_changed(reason: String)
signal selection_changed()
signal status_changed(text: String)
signal validation_changed(result: Dictionary)
signal dirty_changed()
signal map_loaded()
signal mode_changed(mode: int)
signal category_changed(category: int)
## 工具状态变了（切了工具 / 收起工具 / 笔刷参数）—— 停靠面板与视口徽标都吃这个
signal tool_changed()
## 撤销栈变了（提交/撤销/重做/跳转/换图）—— 历史面板刷新用
signal history_changed()
## "这次摆放归属于哪一家"变了（魔兽式：先选玩家，再选摆什么）
signal place_owner_changed(owner_id: int)

enum Mode { TERRAIN, OBJECT, REGION, SELECT }
enum Tool {
	RAISE, LOWER, SMOOTH, FLATTEN,
	PAINT_GRASS, PAINT_DIRT, PAINT_ROCK, PAINT_SAND,
	WATER, ERASE_SPLAT,
}

## 自动保存间隔（秒）
const AUTOSAVE_INTERVAL: float = 120.0
## 没存过盘时的自动保存路径（项目内「地图」文件夹）
const AUTOSAVE_PATH := "res://地图/_自动保存.tres"
## 建筑网格唯一实现（@tool 纯函数；编辑器不碰 Game/RtsWorld）
const GRID := preload("res://代码/单位/建筑网格.gd")
## 建筑落点用寻路格宽（唯一真相在 建筑网格.CELL）。

var plugin: EditorPlugin = null
## 主屏的 3D 视口 / Dock 面板（插件装配时塞进来，省得靠名字到处找节点）
var viewport = null
var dock = null
var def: MapDef = null
var path: String = ""
var dirty: bool = false

# --- 工具状态 ---
var mode: int = Mode.TERRAIN
var tool: int = Tool.RAISE
## **是否手持工具**（交互链路的唯一开关）
## false = 手型/浏览：左键点选 / 空地拖动框选；对象可拖走。转视角走右键拖 / 中键 / Alt+左键
## true  = 手持工具：左键按下就按当前 mode 干活（刷地形 / 放对象 / 画区域）
## 默认 false —— 刚打开编辑器不该"左键一动就改地高"。
var armed: bool = false
var brush_radius: float = 10.0
var brush_strength: float = 0.9
var brush_square: bool = false
var snap_grid: bool = true
## 区域工具：形状 + 用途
var region_shape: int = RegionDef.Shape.CIRCLE
var region_purpose: int = RegionDef.Purpose.ATTACK
## 编辑器放置建筑时的朝向（90° 档；视口里按 R 旋转）。
## 默认 180°：模型正门在 -Z，镜头从南往北看，0° 会一直对着建筑屁股。
## 放置朝向：默认读 建筑网格 的唯一常量（和游戏内建造同一套口径）
var place_yaw: float = GRID.DEFAULT_YAW

## 摆放随机（程序化树的种子/朝向/缩放）用。用固定种子的 RNG 而不是全局 randi()：
## 同一个会话里连续摆树不会因为别处调用了 randi() 而"跳号"，调试时更好复现。
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# --- 选择 ---
var selection: Array[MapObject] = []
var selected_region: RegionDef = null
var selected_player_index: int = 0
var selected_wave_index: int = 0
var clipboard: Array[MapObject] = []

# --- 资产面板 ---
var asset_category: int = MapObject.Category.UNIT
var asset_id: StringName = &"footman"
## **当前摆放归属**（魔兽编辑器的"玩家 N"页签）：0 = 槽位 0，-1 = 中立。
##
## 为什么要有它：以前 add_object 把单位/建筑的 owner 写死成 1（= 槽位 1 = 玩家 2），
## 摆谁都是"别人的兵"，还得再选中改一次归属 —— 两遍活。
## 现在先在这个下拉里选玩家，之后连点十只兵全归那一家。
var place_owner: int = 0

# --- 校验 ---
var validation: Dictionary = {"ok": true, "errors": PackedStringArray(), "warnings": PackedStringArray()}

# --- 内部 ---
var _stroke_open: bool = false
var _stroke_tool: int = Tool.RAISE
var _stroke_before_heights: PackedFloat32Array = PackedFloat32Array()
var _stroke_before_splat: PackedByteArray = PackedByteArray()
## 地块格点表快照（泥土/草丛笔刷真改的就是这张表 —— 和游戏里同一份数据）
var _stroke_before_mat: PackedByteArray = PackedByteArray()
var _stroke_mat_cells: int = 0
var _stroke_before_water: Dictionary = {}
var _stroke_flatten_h: float = 0.0
var _stroke_painted: bool = false
var _drag_before: Array = []
var _drag_open: bool = false
## 拖动起点位置：松手时判断"到底动没动"（只点一下不该产生撤销记录）
var _drag_before_pos: Array[Vector3] = []
## 按下鼠标那一刻**射线打在地面上的点** —— 拖动的唯一原点。
##
## ⚠ 这个成员**必须在这里声明**。曾经只在 `begin_drag()`/`drag_selection_by()` 里
##   直接赋值使用（忘记声明），于是整个 编辑会话.gd 编译失败 →
##   `主屏._process` 每帧刷 "Nonexistent function 'autosave_tick'"，
##   编辑器里所有拖动/笔刷全部失灵。**新增成员一定先写 var**。
##   Vector3.INF = "没有在拖"，见 `drag_selection_by()`。
var _drag_grab_g: Vector3 = Vector3.INF
var _autosave_clock: float = 0.0
var _history_busy: bool = false
## 连续跳转历史时先压住逐步刷新，最后统一刷一次
var _history_jumping: bool = false
## 改过之后校验结果就过期了（校验不自动跑，保存时/点按钮才跑）
var _validation_stale: bool = false


func setup(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin


## 校验结果是否已过期（界面上提示"改过了，建议重新校验"）
func validation_is_stale() -> bool:
	return _validation_stale


# ===========================================================================
# 地图生命周期
# ===========================================================================

## 新建地图（opts.flat = 纯平地；opts.biome = 生态，决定地表色带）
## 建完立刻整理建筑网格 + 跑一次校验，保证"新建即能玩"。
func new_map(map_size: int, player_count: int, map_seed: int, blank: bool = false,
		opts: Dictionary = {}) -> void:
	def = MapLoader.new_map(map_size, player_count, map_seed, blank, opts)
	path = ""
	dirty = true
	selection.clear()
	selected_region = null
	selected_player_index = 0
	selected_wave_index = 0
	place_yaw = GRID.DEFAULT_YAW
	_normalize_buildings()
	var flat: bool = bool(opts.get("flat", blank))
	_emit_all("新建地图：%d×%d，%d 人，%s，%s，种子 %d" % [map_size, map_size, player_count,
		MapDef.biome_name(def.biome), "平地" if flat else "随机地形", map_seed])
	map_loaded.emit()
	dirty_changed.emit()
	validate()


## 打开地图
func open_path(p: String) -> bool:
	var loaded: MapDef = MapStore.load_any(p)
	if loaded == null:
		_emit_status("打不开地图：%s" % p)
		return false
	def = loaded
	path = MapStore.normalize_path(p)
	dirty = false
	selection.clear()
	selected_region = null
	place_yaw = GRID.DEFAULT_YAW
	var fixed: int = _normalize_buildings()
	MapStore.recent_add(path)
	_emit_all("已打开 %s（%d×%d，对象 %d）%s" % [path.get_file(), def.size, def.size,
		def.objects.size(), "，修正 %d 座建筑的网格对齐" % fixed if fixed > 0 else ""])
	map_loaded.emit()
	dirty_changed.emit()
	history_changed.emit()
	validate()
	return true


## 保存（没有路径就当“另存为”）
func save() -> bool:
	if def == null:
		return false
	if path.is_empty():
		return false
	var err: int = MapStore.save_any(def, path)
	if err != OK:
		_emit_status("保存失败：%s（错误码 %d）" % [path, err])
		return false
	dirty = false
	MapStore.recent_add(path)
	dirty_changed.emit()
	var v: Dictionary = validate()
	var tail: String = "校验通过" if bool(v.get("ok", false)) else "校验 %d 条错误" % (v["errors"] as PackedStringArray).size()
	_emit_status("已保存 %s（%s）" % [path.get_file(), tail])
	return true


## 另存为
func save_as(p: String) -> bool:
	if def == null:
		return false
	path = MapStore.normalize_path(p)
	var ok: bool = save()
	if ok:
		MapStore.recent_add(path)
	return ok


## 自动保存（由主屏按帧驱动）
func autosave_tick(delta: float) -> void:
	_autosave_clock += delta
	if _autosave_clock < AUTOSAVE_INTERVAL:
		return
	_autosave_clock = 0.0
	if def == null or not dirty:
		return
	var target: String = path if not path.is_empty() else AUTOSAVE_PATH
	var err: int = MapStore.save_any(def, target)
	if err == OK:
		if path.is_empty():
			_emit_status("已自动保存到 %s" % AUTOSAVE_PATH)
		else:
			dirty = false
			dirty_changed.emit()
			_emit_status("已自动保存 %s" % target.get_file())


## 校验（结果同时发信号，停靠面板与状态栏都吃这一份）
func validate() -> Dictionary:
	if def == null:
		validation = {"ok": false, "errors": PackedStringArray(["还没有打开地图"]),
			"warnings": PackedStringArray(), "stats": {}}
		validation_changed.emit(validation)
		return validation
	validation = MapValidator.validate(def)
	_validation_stale = false
	validation_changed.emit(validation)
	return validation


## 静默校验（打开地图时预热一次，不弹状态）
func validate_quiet() -> void:
	if def == null:
		return
	validation = MapValidator.validate(def)
	_validation_stale = false
	validation_changed.emit(validation)


## Test Map：存临时地图 → 起一个独立游戏进程（不阻塞编辑器）
func test_map() -> void:
	if def == null:
		return
	var v: Dictionary = validate()
	if not bool(v.get("ok", false)):
		_emit_status("校验没过，仍然启动测试（先看校验面板）")
	var err: int = MapStore.save_tres(def, MapStore.TEST_MAP_PATH)
	if err != OK:
		_emit_status("临时地图保存失败（错误码 %d）" % err)
		return
	var exe: String = OS.get_executable_path()
	var proj: String = ProjectSettings.globalize_path("res://")
	var args: PackedStringArray = PackedStringArray([
		"--path", proj, "--", "--map=" + MapStore.TEST_MAP_PATH,
	])
	var pid: int = OS.create_process(exe, args)
	if pid > 0:
		_emit_status("已启动游戏进程（pid %d），编辑器继续干活" % pid)
	else:
		_emit_status("启动游戏进程失败：%s" % exe)


## 换生态：只改整张图的地表色带（splatmap 的值不动），保存后游戏里一致
func set_biome(id: String) -> void:
	if def == null or def.biome == id:
		return
	var before: String = def.biome
	_push_action("地形类型：%s → %s" % [MapDef.biome_name(before), MapDef.biome_name(id)],
		[{"prop": "biome", "before": before, "after": id}],
		UndoRedo.MERGE_DISABLE, "splat")
	_emit_status("地形类型改为 %s" % MapDef.biome_name(id))


# ===========================================================================
# 撤销 / 重做
# ===========================================================================

func _undo() -> EditorUndoRedoManager:
	if plugin == null:
		return null
	return plugin.get_undo_redo()


## 本图专属的撤销历史。
## EditorUndoRedoManager 本身没有 has_undo/undo 这类实例方法（那是 UndoRedo 的），
## 每个对象/上下文各有一份历史，必须按 def 的 history id 取出来再操作。
func _history_undo_redo() -> UndoRedo:
	var urd: EditorUndoRedoManager = _undo()
	if urd == null or def == null:
		return null
	return urd.get_history_undo_redo(urd.get_object_history_id(def))


func undo() -> void:
	var h: UndoRedo = _history_undo_redo()
	if h != null and h.has_undo():
		h.undo()
		def.ensure_arrays()
		_after_history("all")


func redo() -> void:
	var h: UndoRedo = _history_undo_redo()
	if h != null and h.has_redo():
		h.redo()
		def.ensure_arrays()
		_after_history("all")


## 历史面板的数据（不直接把 UndoRedo 暴露给 UI）
## 返回 {"available", "count", "current", "names", "undo_names", "redo_names"}
func history_info() -> Dictionary:
	var h: UndoRedo = _history_undo_redo()
	if h == null:
		return {"available": false, "count": 0, "current": -1, "names": PackedStringArray()}
	var n: int = h.get_history_count()
	var cur: int = h.get_current_action()
	var names := PackedStringArray()
	for i in range(n):
		names.append(String(h.get_action_name(i)))
	return {"available": true, "count": n, "current": cur, "names": names}


## 跳到某一步（-1 = 回到初始状态，0 = 第一步之后）。和魔兽编辑器的历史列表一样：
## 点一条就撤销/重做到那一步，而不是只能一步步入。
func jump_history(target: int) -> void:
	var h: UndoRedo = _history_undo_redo()
	if h == null:
		return
	var goal: int = clampi(target, -1, h.get_history_count() - 1)
	var guard: int = 0
	_history_jumping = true
	while h.get_current_action() > goal and h.has_undo() and guard < 4096:
		h.undo()
		guard += 1
	while h.get_current_action() < goal and h.has_redo() and guard < 4096:
		h.redo()
		guard += 1
	_history_jumping = false
	def.ensure_arrays()
	# 这里要绕过 _history_busy：上面的 undo/redo 已经逐个调用过 _after_history 了，
	# 但每个都因 _history_jumping 只更新数据、不发信号；最后统一刷一次。
	_history_busy = false
	_after_history("all")


## 提交一条"属性型"撤销记录。pairs = [{prop, before, after}]
## reason 决定撤销/重做落地后重建哪一层（terrain / objects / regions / all）。
func _push_action(name: String, pairs: Array,
		merge: int = UndoRedo.MERGE_DISABLE, reason: String = "all") -> void:
	var urd: EditorUndoRedoManager = _undo()
	if urd == null or def == null:
		return
	urd.create_action(name, merge, def)
	for pair in pairs:
		urd.add_do_property(def, String(pair["prop"]), pair["after"])
		urd.add_undo_property(def, String(pair["prop"]), pair["before"])
	urd.add_do_method(self, "_after_history", reason)
	urd.add_undo_method(self, "_after_history", reason)
	urd.commit_action()


## 撤销/重做落地后：只重建受影响的那一层；校验按需跑（别每笔都卡一次）
func _after_history(reason: String = "all") -> void:
	if def == null:
		return
	dirty = true
	_validation_stale = true
	# 连续跳转时：只更新数据，信号统一在 jump_history() 末尾发一次
	if _history_jumping:
		return
	if _history_busy:
		return
	_history_busy = true
	# 撤销会用克隆数组替换 objects/regions，选中项如果已经不在数据里就丢掉（避免野指针）
	var keep: Array[MapObject] = []
	for o in selection:
		if o != null and def.objects.find(o) >= 0:
			keep.append(o)
	selection = keep
	if selected_region != null and def.regions.find(selected_region) < 0:
		selected_region = def.region_by_id(selected_region.id)
	dirty_changed.emit()
	def_changed.emit(reason)
	selection_changed.emit()
	if not _history_jumping:
		history_changed.emit()
	_history_busy = false


# ===========================================================================
# 地形笔刷
# ===========================================================================

## 开始一笔（按下鼠标）：只做快照，不提交
func begin_stroke(world_pos: Vector3) -> void:
	if def == null:
		return
	_stroke_open = true
	_stroke_tool = tool
	_stroke_painted = false
	_stroke_flatten_h = world_pos.y
	if tool in [Tool.RAISE, Tool.LOWER, Tool.SMOOTH, Tool.FLATTEN, Tool.WATER]:
		_stroke_before_heights = def.heightmap.duplicate()
	if tool in [Tool.PAINT_GRASS, Tool.PAINT_DIRT, Tool.PAINT_ROCK, Tool.PAINT_SAND, Tool.ERASE_SPLAT]:
		_stroke_before_splat = def.splatmap.duplicate()
		_stroke_before_mat = def.mat_nodes.duplicate()
		_stroke_mat_cells = def.mat_cells
	if tool == Tool.WATER:
		_stroke_before_water = def.water.duplicate(true)


## 笔刷推进（按帧调用；dt 为真实帧间隔，用来让"按住越久越高"）
func stroke_to(world_pos: Vector3, dt: float) -> void:
	if def == null or not _stroke_open:
		return
	var step: float = clampf(dt, 0.0, 0.1)
	match _stroke_tool:
		Tool.RAISE, Tool.LOWER, Tool.SMOOTH, Tool.FLATTEN:
			_apply_height_brush(world_pos, step)
			_stroke_painted = true
		Tool.PAINT_GRASS, Tool.PAINT_DIRT, Tool.PAINT_ROCK, Tool.PAINT_SAND:
			_apply_splat_brush(world_pos, _splat_value_for(_stroke_tool))
			_stroke_painted = true
		Tool.ERASE_SPLAT:
			_apply_splat_brush(world_pos, MapDef.SPLAT_NONE)
			_stroke_painted = true
		Tool.WATER:
			_apply_water_brush(world_pos)
			_stroke_painted = true
	if _stroke_painted:
		# 轻量信号：只让视口重建地形网格，不动对象/区域（画的时候要跟手）
		def_changed.emit("terrain_live")


## 结束一笔：整笔记成一条撤销记录（一笔一条，不是一帧一条）
func end_stroke() -> void:
	if not _stroke_open:
		return
	_stroke_open = false
	if def == null or not _stroke_painted:
		return
	var pairs: Array = []
	if _stroke_tool == Tool.WATER:
		pairs.append({"prop": "heightmap", "before": _stroke_before_heights,
			"after": def.heightmap.duplicate()})
		pairs.append({"prop": "water", "before": _stroke_before_water,
			"after": def.water.duplicate(true)})
	elif _stroke_tool in [Tool.PAINT_GRASS, Tool.PAINT_DIRT, Tool.PAINT_ROCK,
			Tool.PAINT_SAND, Tool.ERASE_SPLAT]:
		pairs.append({"prop": "splatmap", "before": _stroke_before_splat,
			"after": def.splatmap.duplicate()})
		# 地块格点表（泥土/草丛笔刷真改的那张表）也进撤销，否则"刷了泥路又撤销"会半截
		if def.mat_nodes != _stroke_before_mat:
			if def.mat_cells != _stroke_mat_cells:
				pairs.append({"prop": "mat_cells", "before": _stroke_mat_cells,
					"after": def.mat_cells})
			pairs.append({"prop": "mat_nodes", "before": _stroke_before_mat,
				"after": def.mat_nodes.duplicate()})
	else:
		pairs.append({"prop": "heightmap", "before": _stroke_before_heights,
			"after": def.heightmap.duplicate()})
	var name: String = "地形：%s（半径 %.0fm）" % [tool_name(_stroke_tool), brush_radius]
	_push_action(name, pairs, UndoRedo.MERGE_DISABLE, "terrain")
	def_changed.emit("terrain")
	_validation_stale = true
	dirty = true
	dirty_changed.emit()
	_emit_status("%s 完成" % name)


## 高度笔刷：圆的柔化权重，格子级修改
func _apply_height_brush(center: Vector3, dt: float) -> void:
	var r: float = maxf(0.5, brush_radius)
	var c: float = def.cell_size()
	var half: float = def.half_size()
	var gx0: int = clampi(floori((center.x - r + half) / c), 0, def.height_resolution)
	var gx1: int = clampi(ceili((center.x + r + half) / c), 0, def.height_resolution)
	var gz0: int = clampi(floori((center.z - r + half) / c), 0, def.height_resolution)
	var gz1: int = clampi(ceili((center.z + r + half) / c), 0, def.height_resolution)
	var row: int = def.row_points()
	var amp: float = brush_strength * dt * 6.0
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var p: Vector2 = def.grid_to_world(gx, gz)
			var w: float = _brush_weight(p, Vector2(center.x, center.z), r)
			if w <= 0.001:
				continue
			var i: int = gz * row + gx
			match _stroke_tool:
				Tool.RAISE:
					def.heightmap[i] += amp * w
				Tool.LOWER:
					def.heightmap[i] -= amp * w
				Tool.SMOOTH:
					var avg: float = 0.0
					var cnt: int = 0
					for dz in [-1, 0, 1]:
						for dx in [-1, 0, 1]:
							var nx: int = gx + dx
							var nz: int = gz + dz
							if nx < 0 or nz < 0 or nx > def.height_resolution or nz > def.height_resolution:
								continue
							avg += def.heightmap[nz * row + nx]
							cnt += 1
					if cnt > 0:
						avg /= float(cnt)
						def.heightmap[i] = lerpf(def.heightmap[i], avg,
							clampf(brush_strength * 6.0 * w * dt, 0.0, 1.0))
				Tool.FLATTEN:
					def.heightmap[i] = lerpf(def.heightmap[i], _stroke_flatten_h,
						clampf(brush_strength * 6.0 * w * dt, 0.0, 1.0))
	_raise_max_height_clamp()


## 高度上限保护：别让笔刷把地形抬到天上（也没必要压到地心）
func _raise_max_height_clamp() -> void:
	for i in range(def.heightmap.size()):
		if def.heightmap[i] > 60.0:
			def.heightmap[i] = 60.0
		elif def.heightmap[i] < -40.0:
			def.heightmap[i] = -40.0


## 地表笔刷：**泥土 / 草丛直接改地块格点表**（8m，草=0 泥=255）。
##
## 为什么不能只画一层彩色覆盖网格：游戏里的地面观感来自地形材质的 mat_map（图集硬边 + 8m 格），
## 覆盖层画的 1m 色块在游戏里对应不到任何地块，于是就变成"编辑器里有泥、游戏里没泥"。
## 现在两边的数据是同一条：这里改 mat_nodes，编辑器材质和游戏材质读到的是同一张表。
## 岩石/沙地在地块体系里没有对应材质，仍旧走覆盖层贴花。
func _apply_splat_brush(center: Vector3, value: int) -> void:
	match value:
		MapDef.SPLAT_DIRT:
			_apply_mat_brush(center, 255)
		MapDef.SPLAT_GRASS:
			_apply_mat_brush(center, 0)
		MapDef.SPLAT_NONE:
			# 橡皮擦：先擦回草地（地块），再把覆盖层贴花一起清掉
			_apply_mat_brush(center, 0)
			_apply_decal_brush(center, MapDef.SPLAT_NONE)
		_:
			_apply_decal_brush(center, value)


## 地块格点刷的**等效半径**：笔刷圈"碰到"的格子都算（格子中心落在外扩半格以内）。
## 这是唯一出口 —— 预览圈画的就是这个值，玩家看到多大就刷多大。
## 以前写 `step * 0.72` + 权重 0.35，10m 的笔刷实际能糊出 31m 直径，
## 玩家原话"刷地形有时感觉刷的太大"就是这个偏差。
func mat_brush_radius() -> float:
	var step: float = 8.0
	if def != null and def.mat_cells > 0:
		step = float(def.size) / float(def.mat_cells)
	return maxf(0.5, brush_radius) + step * 0.5


## 光标该画多大：材质/地块笔刷用等效半径（预览 = 结果），其它工具就是笔刷半径
func cursor_radius() -> float:
	match tool:
		Tool.PAINT_GRASS, Tool.PAINT_DIRT, Tool.ERASE_SPLAT:
			return mat_brush_radius()
		_:
			return brush_radius


## 地块格点刷：写 def.mat_nodes（和 主场景 的地块完全同一套数据）
func _apply_mat_brush(center: Vector3, node_value: int) -> void:
	_ensure_mat_grid()
	if def.mat_cells <= 0 or def.mat_nodes.is_empty():
		return
	var r: float = maxf(0.5, brush_radius)
	var n: int = def.mat_cells + 1
	var step: float = float(def.size) / float(def.mat_cells)
	var half: float = def.half_size()
	# ★ **格点中心可能在笔刷圈外**：地块是 8m 一格、笔刷默认半径只有 10m，
	#   而格点间距 8m —— 圈里可能一个格点都没有（最坏情况离最近格点 5.7m）。
	#   只按 `dist <= r` 判定就会出现"点了/拖了半天一点反应都没有"，
	#   也就是用户说的"编辑器无法刷地形"。
	#   所以判定半径外扩半格（0.72×step 刚好覆盖"格点落在格子里"的极值），
	#   语义变成"笔刷圈碰到的格子都算"：任何一次点击至少改到最近的格点。
	var rr: float = mat_brush_radius()
	var i0: int = clampi(floori((center.x - rr + half) / step), 0, n - 1)
	var i1: int = clampi(ceili((center.x + rr + half) / step), 0, n - 1)
	var j0: int = clampi(floori((center.z - rr + half) / step), 0, n - 1)
	var j1: int = clampi(ceili((center.z + rr + half) / step), 0, n - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := Vector2(-half + float(i) * step, -half + float(j) * step)
			var w: float = _brush_weight(p, Vector2(center.x, center.z), rr)
			if w < 0.5:
				continue
			def.mat_nodes[j * n + i] = node_value
	# 同一片区域里旧的"泥土/草丛/生态"覆盖色块要清掉，否则会有两层地面打架
	_clear_splat_in(center, rr, [MapDef.SPLAT_DIRT, MapDef.SPLAT_GRASS, MapDef.SPLAT_BIOME])


## 老地图可能没有地块表（mat_cells = 0）：第一次刷就地建成 8m 格，全草。
func _ensure_mat_grid() -> void:
	if def.mat_cells > 0 and def.mat_nodes.size() == (def.mat_cells + 1) * (def.mat_cells + 1):
		return
	var cells: int = maxi(4, int(round(float(def.size) / 8.0)))
	def.mat_cells = cells
	def.mat_tile = float(def.size) / float(cells)
	def.mat_nodes.resize((cells + 1) * (cells + 1))
	def.mat_nodes.fill(0)


## 覆盖层贴花刷（岩石 / 沙地）
func _apply_decal_brush(center: Vector3, value: int) -> void:
	var r: float = maxf(0.5, brush_radius)
	var c: float = def.cell_size()
	var half: float = def.half_size()
	var res: int = def.height_resolution
	var gx0: int = clampi(floori((center.x - r + half) / c), 0, res - 1)
	var gx1: int = clampi(floori((center.x + r + half) / c), 0, res - 1)
	var gz0: int = clampi(floori((center.z - r + half) / c), 0, res - 1)
	var gz1: int = clampi(floori((center.z + r + half) / c), 0, res - 1)
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var cell_center := def.grid_to_world(gx, gz) + Vector2(c, c) * 0.5
			var w: float = _brush_weight(cell_center, Vector2(center.x, center.z), r)
			if w < 0.35:
				continue
			def.splatmap[gz * res + gx] = value


## 只清掉指定值的地表色块（不碰岩石/沙地贴花）
func _clear_splat_in(center: Vector3, r: float, kinds: Array) -> void:
	if def.splatmap.is_empty():
		return
	var c: float = def.cell_size()
	var half: float = def.half_size()
	var res: int = def.height_resolution
	var gx0: int = clampi(floori((center.x - r + half) / c), 0, res - 1)
	var gx1: int = clampi(ceili((center.x + r + half) / c), 0, res - 1)
	var gz0: int = clampi(floori((center.z - r + half) / c), 0, res - 1)
	var gz1: int = clampi(ceili((center.z + r + half) / c), 0, res - 1)
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var i: int = gz * res + gx
			if i < 0 or i >= def.splatmap.size():
				continue
			if kinds.has(int(def.splatmap[i])):
				def.splatmap[i] = MapDef.SPLAT_NONE


## 水面笔刷：挖一个碗 + 放一片水。一次点击一笔（不跟手连续挖，免得越描越深）
func _apply_water_brush(center: Vector3) -> void:
	var r: float = maxf(2.0, brush_radius)
	var level: float = center.y - 0.25
	var c: float = def.cell_size()
	var half: float = def.half_size()
	var row: int = def.row_points()
	var gx0: int = clampi(floori((center.x - r + half) / c), 0, def.height_resolution)
	var gx1: int = clampi(ceili((center.x + r + half) / c), 0, def.height_resolution)
	var gz0: int = clampi(floori((center.z - r + half) / c), 0, def.height_resolution)
	var gz1: int = clampi(ceili((center.z + r + half) / c), 0, def.height_resolution)
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var p: Vector2 = def.grid_to_world(gx, gz)
			var w: float = _brush_weight(p, Vector2(center.x, center.z), r)
			if w <= 0.001:
				continue
			var i: int = gz * row + gx
			var bowl: float = level - 1.2
			def.heightmap[i] = lerpf(def.heightmap[i], minf(def.heightmap[i], bowl), w)
	def.set_water_spot(Vector2(center.x, center.z), r * 0.92, level)


func _splat_value_for(t: int) -> int:
	match t:
		Tool.PAINT_DIRT:
			return MapDef.SPLAT_DIRT
		Tool.PAINT_ROCK:
			return MapDef.SPLAT_ROCK
		Tool.PAINT_SAND:
			return MapDef.SPLAT_SAND
		Tool.PAINT_GRASS:
			return MapDef.SPLAT_GRASS
	return MapDef.SPLAT_NONE


## 笔刷权重（0~1）：圆形柔化 / 方形硬边
func _brush_weight(p: Vector2, center: Vector2, r: float) -> float:
	if brush_square:
		var d: Vector2 = (p - center).abs()
		if d.x > r or d.y > r:
			return 0.0
		return 1.0 - smoothstep(r * 0.75, r, maxf(d.x, d.y)) * 0.5
	var dist: float = p.distance_to(center)
	if dist > r:
		return 0.0
	return 1.0 - smoothstep(0.0, r, dist)


func tool_name(t: int = -1) -> String:
	var tt: int = tool if t < 0 else t
	match tt:
		Tool.RAISE:
			return "抬升"
		Tool.LOWER:
			return "降低"
		Tool.SMOOTH:
			return "平滑"
		Tool.FLATTEN:
			return "压平"
		Tool.PAINT_GRASS:
			return "草地"
		Tool.PAINT_DIRT:
			return "泥土"
		Tool.PAINT_ROCK:
			return "岩石"
		Tool.PAINT_SAND:
			return "沙地"
		Tool.WATER:
			return "水面"
		Tool.ERASE_SPLAT:
			return "擦除地表层"
	return "?"


func mode_name() -> String:
	match mode:
		Mode.TERRAIN:
			return "地形"
		Mode.OBJECT:
			return "对象"
		Mode.REGION:
			return "区域"
		Mode.SELECT:
			return "选择"
	return "?"


# ===========================================================================
# 工具状态（交互链路的总闸）
# ===========================================================================
#
# 为什么要有这一节：停靠面板里每一个工具按钮都在调 set_tool / set_mode /
# set_category，但之前这三个方法**根本不存在** → 运行时全是 Invalid call，
# 点按钮等于点石头。这里把它们补齐，并且顺手把"手持工具 / 手型浏览"分开，
# 让左键不再无脑改地高。

## 切层（地形/对象/区域/选择）。点层 = 顺手拿起这一层的工具。
## 不做"状态没变就提前返回"：多一次信号无害，
## 少一次信号会让 UI 高亮和真实状态对不上（踩过一次）。
func set_mode(m: int) -> void:
	mode = clampi(m, Mode.TERRAIN, Mode.SELECT)
	armed = true
	mode_changed.emit(mode)
	tool_changed.emit()
	_emit_status("当前：%s" % tool_hint())


## 选工具（同时保证在手形层，不然点了"抬升"还在区域层就诡异了）
func set_tool(t: int) -> void:
	tool = clampi(t, Tool.RAISE, Tool.ERASE_SPLAT)
	armed = true
	mode = Mode.TERRAIN
	mode_changed.emit(mode)
	tool_changed.emit()
	_emit_status("当前：%s" % tool_hint())


## 选放置分类（对象层）
func set_category(c: int) -> void:
	asset_category = clampi(c, MapObject.Category.UNIT, MapObject.Category.RESOURCE)
	armed = true
	mode = Mode.OBJECT
	mode_changed.emit(mode)
	category_changed.emit(asset_category)
	tool_changed.emit()
	_emit_status("当前：%s" % tool_hint())


## 拿起工具（显式）
func arm() -> void:
	if armed:
		return
	armed = true
	tool_changed.emit()


## 收起工具 → 回到手型：左键 = 点选 / 框选，右键拖 = 平移，Alt+左键 / 中键 = 转视角。
## Esc、右键空地、点"手型"按钮都走这里。
func disarm() -> void:
	if not armed:
		return
	armed = false
	tool_changed.emit()
	_emit_status("已收起工具：左键点选 / 框选，右键拖平移，Alt+左键转视角")


func is_armed() -> bool:
	return armed


## 选"这次摆放归谁"（魔兽式：先选玩家几，再选摆什么）。
## 只影响之后新放的对象；已选中的对象要改归属请用归属卡（set_selection_owner）。
func set_place_owner(owner_id: int) -> void:
	# -1 = 中立（和平） / -2 = 中立敌对（野怪） / 0..N-1 = 玩家槽位
	var v: int = owner_id
	if v >= 0:
		v = clampi(v, 0, maxi(0, (def.players.size() if def != null else 1) - 1))
	elif v < -2:
		v = -1
	if v == place_owner:
		return
	place_owner = v
	place_owner_changed.emit(place_owner)
	tool_changed.emit()
	_emit_status("摆放归属：%s（之后放的兵和楼都归它）" % owner_display_name(place_owner))


## 放置建筑时按 R：朝向转 90°（编辑器与游戏建造共用同一个吸附档）
func rotate_place_yaw(step_deg: float = 90.0) -> void:
	place_yaw = GRID.snap_yaw(place_yaw + deg_to_rad(step_deg))
	tool_changed.emit()
	var deg: int = int(round(rad_to_deg(place_yaw)))
	_emit_status("建筑朝向：%d°（按 R 继续转）" % deg)


## 状态栏 / 视口徽标用的一句话
func tool_hint() -> String:
	if not armed:
		return "手型 · 左键点选 / 框选（Alt+左键转视角）"
	match mode:
		Mode.TERRAIN:
			return "地形 · %s（笔刷 %.0fm %s）" % [
				tool_name(), brush_radius, "方形" if brush_square else "圆形"]
		Mode.OBJECT:
			# 归属写进状态栏：魔兽的"当前玩家页签"也是常驻可见的，
			# 不然连着摆十只兵之后才发现全归错了家。
			if asset_category == MapObject.Category.UNIT \
					or asset_category == MapObject.Category.BUILDING:
				return "放置 · %s · %s → %s" % [
					MapAssets.category_name(asset_category), String(asset_id),
					owner_display_name(place_owner)]
			return "放置 · %s · %s" % [
				MapAssets.category_name(asset_category), String(asset_id)]
		Mode.REGION:
			return "区域 · %s" % RegionDef.shape_name_of(region_shape)
		Mode.SELECT:
			return "选择 · 左键点选 / 框选"
	return "手型"


## 笔刷参数变了（滑块拖动）：只发信号，别触发层重建
func notify_tool_params() -> void:
	tool_changed.emit()


# ===========================================================================
# 对象操作
# ===========================================================================

func _snapshot_objects() -> Array:
	var out: Array = []
	for o in def.objects:
		out.append(o.clone_obj() if o != null else null)
	return out


func _objects_from(arr: Array) -> Array[MapObject]:
	var typed: Array[MapObject] = []
	for o in arr:
		if o is MapObject:
			typed.append(o)
	return typed


# --- 建筑网格（编辑器侧，和游戏/寻路共用 1m 格）---

## 建筑的占地（单位定义里的 footprint；未知类型退化成 2×2）
func building_footprint(type_id: StringName) -> Vector2i:
	var d: UnitDef = MapLoader.type_def(type_id)
	if d != null and d.footprint.x > 0 and d.footprint.y > 0:
		return d.footprint
	return Vector2i(2, 2)


## 建筑落点吸附（纯函数 + 贴地）。**所有**建筑放置/拖动/粘贴都走这里。
func snap_building_pos(pos: Vector3, footprint: Vector2i) -> Vector3:
	if def == null:
		return pos
	var p: Vector3 = GRID.snap_point_in(pos, footprint, def.half_size(), GRID.CELL)
	p.y = def.height_at(p.x, p.z)
	return p


## 编辑器里的建造合法性预览（不扣钱、不落工地）。
## 判据和游戏侧同口径：地图边界 / 水面 / 陡坡 / 与其他建筑占地重叠。
## 注意：这里不查寻路器的动态可走格（编辑器不持有游戏关卡），只做几何层判断。
func can_place_building_editor(pos: Vector3, footprint: Vector2i,
		exclude: MapObject = null) -> bool:
	if def == null:
		return false
	var fp := Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	if not def.in_bounds(Vector2(pos.x, pos.z), float(maxi(fp.x, fp.y)) * 0.5):
		return false
	var cells: Array[Vector2i] = GRID.cells_of_in(pos, fp, def.half_size(), GRID.CELL)
	for c in cells:
		var cc: Vector3 = GRID.cell_center_in(c, def.half_size(), GRID.CELL)
		if def.is_water_at(Vector2(cc.x, cc.z)):
			return false
		if def.slope_degrees_at(cc.x, cc.z) > MapLoader.WALK_SLOPE_LIMIT_DEG:
			return false
	for o in def.objects:
		if o == null or o == exclude or int(o.category) != MapObject.Category.BUILDING:
			continue
		var ofp: Vector2i = building_footprint(o.type_id)
		if absf(o.position.x - pos.x) < float(fp.x + ofp.x) * 0.5 \
				and absf(o.position.z - pos.z) < float(fp.y + ofp.y) * 0.5:
			return false
	return true


## 把一栋建筑吸到网格 + 90° 朝向；返回是否真的改了
func _normalize_building(o: MapObject) -> bool:
	if o == null or int(o.category) != MapObject.Category.BUILDING:
		return false
	var fp: Vector2i = building_footprint(o.type_id)
	var p: Vector3 = snap_building_pos(o.position, fp)
	var yaw: float = GRID.snap_yaw(o.rotation)
	var changed: bool = absf(p.x - o.position.x) > 0.001 or absf(p.z - o.position.z) > 0.001 		or absf(p.y - o.position.y) > 0.01 or absf(angle_difference(yaw, o.rotation)) > 0.001
	o.position = p
	o.rotation = yaw
	return changed


## 打开/新建地图时统一整理（修旧图/手改 JSON 的歪斜）
func _normalize_buildings() -> int:
	if def == null:
		return 0
	var n: int = 0
	for o in def.objects:
		if _normalize_building(o):
			n += 1
	return n


## 提交一次对象改动。**after 用活引用**（def.objects 里的同一批实例），
## 这样提交后选中项不会变成"已经不在数组里的野指针"；before 用克隆，撤销时整体回滚。
func _push_objects(name: String, before: Array, after: Array, merge: bool = false) -> void:
	_push_action(name, [{
		"prop": "objects",
		"before": _objects_from(before),
		"after": _objects_from(def.objects),
	}], UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, "objects")
	_validation_stale = true
	def_changed.emit("objects")
	dirty = true
	dirty_changed.emit()


## 放一个对象（自动贴地 + 网格吸附）
func add_object(type_id: StringName, category: int, world_pos: Vector3) -> MapObject:
	if def == null:
		return null
	var before: Array = _snapshot_objects()
	var pos: Vector3 = world_pos
	var yaw: float = 0.0
	if category == MapObject.Category.BUILDING:
		# 建筑：唯一入口 = 建筑网格（1m 寻路格 + 90° 朝向）
		pos = snap_building_pos(pos, building_footprint(type_id))
		yaw = GRID.snap_yaw(place_yaw)
	else:
		if snap_grid:
			pos.x = roundf(pos.x)
			pos.z = roundf(pos.z)
		pos.y = def.height_at(pos.x, pos.z)
	# 单位 / 建筑**必须**有归属（加载器要按 owner 找阵营）；下拉里选了"中立"也回落到槽位 0，
	# 只在状态栏提示一句，别让"中立步兵"这种没有阵营的怪东西进地图文件。
	# 同时按当前地图的槽位数夹一下：换图后 place_owner 可能还停在上一张图的"玩家 4"。
	#
	# ★ **例外机制保留、名单当前为空**（`MapAssets.allows_neutral()`）：
	#   白名单里的 id 允许以"中立"身份放下。以前只有 `dungeon` 在里面，
	#   2026-11-01 地牢删除后名单清空 —— 玩家以后自己做地牢时把它加进去即可。
	# 归属：-2 中立敌对 / -1 中立（和平，需白名单）/ 0..N 玩家槽位
	var own: int = -1
	if category == MapObject.Category.UNIT or category == MapObject.Category.BUILDING:
		var max_slot: int = maxi(0, (def.players.size() if def != null else 1) - 1)
		if place_owner == -2:
			own = -2
		elif place_owner == -1:
			own = -1 if MapAssets.allows_neutral(type_id) else 0
		else:
			own = clampi(place_owner, 0, max_slot)
	var obj := MapObject.make(type_id, category, pos, yaw, 1.0, own)
	if category == MapObject.Category.DOODAD:
		var info: Dictionary = _asset_info(type_id)
		if info.has("model"):
			obj.properties["model"] = String(info["model"])
	elif category == MapObject.Category.RESOURCE and MapAssets.is_proc_tree(type_id):
		# ★ 程序化树：摆一棵 = 掷一次骰子（种子 + 朝向 + 缩放）。
		#   三样都写进 properties / transform，存进 .tres —— 之后每次打开都是同一棵。
		MapAssets.roll_proc_tree(obj, type_id, _rng)
		obj.position.y = def.height_at(pos.x, pos.z)
	obj.category = category
	def.objects.append(obj)
	selection = [obj]
	_push_objects("放置 %s" % String(type_id), before, _snapshot_objects())
	selection_changed.emit()
	return obj


func delete_selection() -> void:
	if def == null or selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	var ids: Array = []
	for o in selection:
		ids.append(o.get_instance_id())
	var keep: Array = []
	for o in def.objects:
		if o != null and not ids.has(o.get_instance_id()):
			keep.append(o)
	def.objects = _objects_from(keep)
	var n: int = selection.size()
	selection.clear()
	_push_objects("删除 %d 个对象" % n, before, _snapshot_objects())
	selection_changed.emit()


## 拖动前记一份快照（视口里拖拽开始/结束调用）。
## `grab_g` 是按下鼠标那一刻**射线打在地面上的点** —— 拖动全程都用它当原点，
## 见 `drag_selection_by()` 的注释（这是"移动跟不跟手"的根）。
func begin_drag(grab_g: Vector3 = Vector3.INF) -> void:
	if def == null or _drag_open:
		return
	_drag_before = _snapshot_objects()
	_drag_before_pos.clear()
	for o in selection:
		_drag_before_pos.append(o.position if o != null else Vector3.ZERO)
	_drag_grab_g = grab_g
	_drag_open = true


## 拖动：**绝对位移** = 当前鼠标地面点 − 按下时的地面点，作用在"按下时的位置"上。
##
## 为什么不是"每帧把 delta 累加到当前位置"（老实现）：
##   ① 开了网格吸附时每个 delta 都被 roundf 过一次，0.3m 的移动被放大成 0.5m，
##      按住拖 10 帧就漂出去 2 米 —— 手感就是"物体不跟着鼠标走、越拖越跑"；
##   ② 累加误差还会让"点一下不拖"也产生位移。
## 现在全程用同一个原点算绝对位置，鼠标在哪物体就在哪（吸附只发生在落点上）。
func drag_selection_by(g: Vector3, y_of: Callable = Callable()) -> void:
	if def == null or selection.is_empty() or not _drag_open:
		return
	if _drag_grab_g == Vector3.INF or g == Vector3.INF:
		return
	var delta: Vector3 = g - _drag_grab_g
	# 按住 Shift 时**不吸附**（微调）；平时按 1m 格/建筑占地格吸附
	var do_snap: bool = snap_grid and not Input.is_key_pressed(KEY_SHIFT)
	for i in range(selection.size()):
		var o: MapObject = selection[i]
		if o == null:
			continue
		var base: Vector3 = _drag_before_pos[i] if i < _drag_before_pos.size() else o.position
		var np: Vector3 = base + delta
		if int(o.category) == MapObject.Category.BUILDING:
			# 建筑必须压 1m 寻路格（占地 = 整数格），和游戏内建造同一套口径
			np = snap_building_pos(np, building_footprint(o.type_id))
		else:
			if do_snap:
				np.x = roundf(np.x)
				np.z = roundf(np.z)
			np.y = def.height_at(np.x, np.z)
		o.position = np
	def_changed.emit("objects_move")


## 返回"是否真的移动过"（视口用它区分"点选"和"拖动"：
## 框选一堆之后点住其中一个松手，没动 → 塌成单选；动了 → 保持整组）
func end_drag() -> bool:
	if not _drag_open:
		return false
	_drag_open = false
	if selection.is_empty():
		return false
	# 只是"点了一下"没有实际位移：不提交撤销记录。
	# 否则每点一次单位，历史里就多一条"移动 1 个对象"，撤销栈很快被点满。
	var moved: bool = false
	for i in range(mini(selection.size(), _drag_before_pos.size())):
		var o2: MapObject = selection[i]
		if o2 != null and o2.position.distance_to(_drag_before_pos[i]) > 0.02:
			moved = true
			break
	if not moved:
		return false
	_push_objects("移动 %d 个对象" % selection.size(), _drag_before, _snapshot_objects())
	selection_changed.emit()
	return true


## 拖动过程中直接改数据（不提交撤销）
func move_selection_to(world_pos: Vector3, obj: MapObject) -> void:
	if def == null or obj == null:
		return
	var p: Vector3 = world_pos
	if int(obj.category) == MapObject.Category.BUILDING:
		p = snap_building_pos(p, building_footprint(obj.type_id))
	elif snap_grid:
		p.x = roundf(p.x)
		p.z = roundf(p.z)
		p.y = def.height_at(p.x, p.z)
	obj.position = p
	def_changed.emit("objects_move")


func rotate_selection(delta_deg: float) -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	# 建筑只吃 90° 档：±15° 落到建筑上会变成"原地不动"，不如直接转一整档。
	var bstep: float = deg_to_rad(90.0 if delta_deg >= 0.0 else -90.0)
	for o in selection:
		if int(o.category) == MapObject.Category.BUILDING:
			o.rotation = GRID.snap_yaw(o.rotation + bstep)
		else:
			o.rotation = fposmod(o.rotation + deg_to_rad(delta_deg), TAU)
	_push_objects("旋转 %d 个对象" % selection.size(), before, _snapshot_objects())


func randomize_rotation() -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for o in selection:
		if int(o.category) == MapObject.Category.BUILDING:
			o.rotation = GRID.snap_yaw(float(rng.randi_range(0, 3)) * GRID.YAW_STEP)
		else:
			o.rotation = rng.randf() * TAU
	_push_objects("随机朝向 %d 个对象" % selection.size(), before, _snapshot_objects())


func scale_selection(mult: float) -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	var done: int = 0
	for o in selection:
		if int(o.category) == MapObject.Category.BUILDING:
			continue   # 建筑缩放会破坏占地/寻路格，禁止
		o.scale = clampf(o.scale * mult, 0.05, 20.0)
		done += 1
	if done == 0:
		_emit_status("建筑不能缩放：占地必须和寻路格严格对齐")
		return
	_push_objects("缩放 %d 个对象" % done, before, _snapshot_objects())


func copy_selection() -> void:
	clipboard.clear()
	for o in selection:
		clipboard.append(o.clone_obj())
	_emit_status("已复制 %d 个对象" % clipboard.size())


func paste_clipboard() -> void:
	if def == null or clipboard.is_empty():
		_emit_status("剪贴板是空的")
		return
	var before: Array = _snapshot_objects()
	var pasted: Array[MapObject] = []
	for c in clipboard:
		var o := c.clone_obj()
		o.position += Vector3(2.0, 0.0, 2.0)
		if int(o.category) == MapObject.Category.BUILDING:
			o.position = snap_building_pos(o.position, building_footprint(o.type_id))
			o.rotation = GRID.snap_yaw(o.rotation)
		else:
			o.position.y = def.height_at(o.position.x, o.position.z)
		def.objects.append(o)
		pasted.append(o)
	# 粘贴后再次粘贴继续偏移，所见即所得
	for c in clipboard:
		c.position += Vector3(2.0, 0.0, 2.0)
	selection = pasted
	_push_objects("粘贴 %d 个对象" % pasted.size(), before, _snapshot_objects())
	selection_changed.emit()


## 把所有选中对象换成另一个类型（保留位置/朝向/归属）
func replace_selection(type_id: StringName, category: int) -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	for o in selection:
		o.type_id = type_id
		o.category = category
		if category == MapObject.Category.BUILDING:
			o.scale = 1.0
			o.position = snap_building_pos(o.position, building_footprint(type_id))
			o.rotation = GRID.snap_yaw(o.rotation)
		elif category == MapObject.Category.DOODAD:
			var info: Dictionary = _asset_info(type_id)
			if info.has("model"):
				o.properties["model"] = String(info["model"])
	_push_objects("替换为 %s（%d 个）" % [String(type_id), selection.size()],
		before, _snapshot_objects())


## 把某份营地配置指派给**选中的锚点建筑**（逐实例，2026-11-07）。
## 同时按配置里的 owner_slot 改锚点归属：
##   -2 中立敌对（野怪）/ -1 中立（和平）/ N 归玩家 N。
## 返回改了几座；没有选中建筑返回 0（界面据此提示）。
func assign_camp_to_selection(camp_id: String, owner_slot: int) -> int:
	var targets: Array = []
	for o in selection:
		if o != null and int(o.category) == MapObject.Category.BUILDING:
			targets.append(o)
	if targets.is_empty() or camp_id.is_empty():
		return 0
	var before: Array = _snapshot_objects()
	for o in targets:
		o.properties["camp_id"] = camp_id
		o.owner = owner_slot
	_push_action("指派营地「%s」给 %d 座锚点" % [camp_id, targets.size()],
		[{"prop": "objects", "before": _objects_from(before),
			"after": _objects_from(def.objects)}],
		UndoRedo.MERGE_DISABLE, "objects_owner")
	_emit_status("已把营地「%s」指派给 %d 座锚点（归属 %s）"
		% [camp_id, targets.size(), owner_display_name(owner_slot)])
	return targets.size()


## 设置归属。**走轻量 reason**（objects_owner）：视口只刷选中环/归属色，
## 不重建对象节点 —— 归属是个高频切换的属性，绝不能让点一下等三秒。
func set_selection_owner(owner_id: int) -> void:
	if selection.is_empty():
		return
	var changed: bool = false
	for o in selection:
		if o.owner != owner_id:
			changed = true
			break
	if not changed:
		return
	var before: Array = _snapshot_objects()
	for o in selection:
		o.owner = owner_id
	_push_action("设置归属（%d 个）→ %s" % [selection.size(), owner_display_name(owner_id)],
		[{"prop": "objects", "before": _objects_from(before), "after": _objects_from(def.objects)}],
		UndoRedo.MERGE_DISABLE, "objects_owner")
	_emit_status("归属已改为 %s（%d 个）" % [owner_display_name(owner_id), selection.size()])


# ===========================================================================
# 归属（对象/区域颜色与选项的唯一出口）
# ===========================================================================

## 归属选项：中立 + 地图上**每一个**玩家槽位（2 人图 3 项 / 3 人图 4 项 / 4 人图 5 项）
## 返回 [{id:int, name:String, color:Color, tag:String}]
func owner_choices() -> Array:
	var out: Array = [
		{"id": -1, "name": "中立", "color": Color(0.64, 0.70, 0.78), "tag": "和平"},
		{"id": -2, "name": "中立敌对", "color": Color(0.78, 0.34, 0.30), "tag": "野怪"},
	]
	if def == null:
		return out
	for p in def.players:
		if p == null:
			continue
		out.append({
			"id": p.id,
			"name": "玩家 %d" % (p.id + 1),
			"color": p.color,
			"tag": faction_tag(p.faction),
		})
	return out


## 归属颜色（取玩家槽位色；中立/未知给冷灰）
func owner_color(owner_id: int) -> Color:
	if def != null and owner_id >= 0:
		for p in def.players:
			if p != null and p.id == owner_id:
				return p.color
	return Color(0.64, 0.70, 0.78)


## 归属显示名（「玩家 1（你）」/「玩家 2（人机）」/「中立」）
## 玩家 0 就是你在游戏里操控的那一家；其余都是电脑。
func owner_display_name(owner_id: int) -> String:
	if owner_id == -2:
		return "中立敌对"
	if owner_id < 0:
		return "中立"
	if def != null:
		for p in def.players:
			if p != null and p.id == owner_id:
				var who: String = "你" if p.faction == "player" else "人机"
				return "玩家 %d（%s）" % [p.id + 1, who]
	return "玩家 %d" % (owner_id + 1)


static func faction_tag(faction: String) -> String:
	match faction:
		"player":
			return "己方"
		"enemy":
			return "敌方"
		"neutral":
			return "中立"
	return faction if not faction.is_empty() else "未设定"


## 属性面板：精确改位置（连续拖动自动合并成一条撤销）
func set_selection_position(p: Vector3) -> void:
	if def == null or selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	for o in selection:
		var np := p
		if int(o.category) == MapObject.Category.BUILDING:
			np = snap_building_pos(np, building_footprint(o.type_id))
		else:
			np.y = def.height_at(np.x, np.z)
		o.position = np
	_push_objects("修改位置（%d 个）" % selection.size(), before, _snapshot_objects(), true)
	selection_changed.emit()


func set_selection_rotation(rad: float) -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	for o in selection:
		o.rotation = GRID.snap_yaw(rad) if int(o.category) == MapObject.Category.BUILDING else rad
	_push_objects("修改朝向（%d 个）" % selection.size(), before, _snapshot_objects(), true)
	selection_changed.emit()


func set_selection_scale(s: float) -> void:
	if selection.is_empty():
		return
	var before: Array = _snapshot_objects()
	var done: int = 0
	for o in selection:
		if int(o.category) == MapObject.Category.BUILDING:
			continue
		o.scale = clampf(s, 0.05, 20.0)
		done += 1
	if done == 0:
		_emit_status("建筑不能缩放：占地必须和寻路格严格对齐")
		return
	_push_objects("修改缩放（%d 个）" % done, before, _snapshot_objects(), true)
	selection_changed.emit()


func select_only(o: MapObject) -> void:
	selection.clear()
	if o != null:
		selection.append(o)
	selected_region = null
	selection_changed.emit()


func clear_selection() -> void:
	selection.clear()
	selected_region = null
	selection_changed.emit()


# ===========================================================================
# 区域 / 玩家 / 波次
# ===========================================================================

func add_region(shape: int, points: PackedVector2Array, purpose: int) -> RegionDef:
	if def == null:
		return null
	var before: int = def.regions.size()
	var r := RegionDef.new()
	r.shape = shape
	r.points = points
	r.purpose = purpose
	var idx: int = 1
	var base_name: String = r.purpose_name()
	while def.region_by_id("%s_%d" % [base_name, idx]) != null:
		idx += 1
	r.id = "%s_%d" % [base_name, idx]
	def.regions.append(r)
	_push_action("新增区域 %s" % r.id, [{
		"prop": "regions",
		"before": _regions_copy(before),
		"after": _regions_copy(def.regions.size()),
	}], UndoRedo.MERGE_DISABLE, "regions")
	selected_region = r
	def_changed.emit("regions")
	dirty = true
	dirty_changed.emit()
	return r


func _regions_copy(count: int = -1) -> Array[RegionDef]:
	var out: Array[RegionDef] = []
	var n: int = def.regions.size() if count < 0 else mini(count, def.regions.size())
	for i in range(n):
		var r: RegionDef = def.regions[i]
		out.append(r.clone_region() if r != null else null)
	return out


func delete_region(r: RegionDef) -> void:
	if def == null or r == null:
		return
	var before: Array[RegionDef] = _regions_copy()
	var idx: int = def.regions.find(r)
	if idx < 0:
		return
	def.regions.remove_at(idx)
	if selected_region == r:
		selected_region = null
	_push_action("删除区域 %s" % r.id, [{
		"prop": "regions", "before": before, "after": _regions_copy(),
	}], UndoRedo.MERGE_DISABLE, "regions")
	def_changed.emit("regions")
	dirty = true
	dirty_changed.emit()


func update_region_props(r: RegionDef, new_id: String, purpose: int) -> void:
	if r == null:
		return
	var before: Array[RegionDef] = _regions_copy()
	r.id = new_id
	r.purpose = purpose
	_push_action("修改区域 %s" % r.id, [{
		"prop": "regions", "before": before, "after": _regions_copy(),
	}], UndoRedo.MERGE_DISABLE, "regions")
	def_changed.emit("regions")
	dirty = true
	dirty_changed.emit()


func _players_copy() -> Array[PlayerSlot]:
	var out: Array[PlayerSlot] = []
	for p in def.players:
		out.append(p.clone_slot() if p != null else null)
	return out


## 一键排队伍（玩家页的三个预设按钮）。kind：solo = 各自为战 / two = 两队 / all = 全同盟。
## 走的是同一条 update 路径（同样进撤销栈、同样标脏），不是"直接改内存"的野路子。
func set_team_layout(kind: String) -> void:
	if def == null or def.players.is_empty():
		return
	var before: Array[PlayerSlot] = _players_copy()
	var n: int = def.players.size()
	for i in n:
		var p: PlayerSlot = def.players[i]
		if p == null:
			continue
		match kind:
			"solo":
				p.team = i + 1
			"two":
				p.team = 1 if i < int(ceil(float(n) * 0.5)) else 2
			"all":
				p.team = 1
			_:
				pass
	_push_action("排队伍（%s）" % kind, [{
		"prop": "players", "before": before, "after": _players_copy(),
	}], UndoRedo.MERGE_DISABLE)
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()
	_emit_status("队伍已重排：%s" % team_summary())


## 加一个玩家槽位（魔兽式：地图最多 12 家）。
## 新槽位落在圆心朝外的圆周上（避让已有出生点），队伍接到最后一队，
## 颜色取 `_spawn_colors` 里还没用过的一档。
func add_player() -> void:
	if def == null:
		return
	if def.players.size() >= 12:
		_emit_status("最多 12 个玩家槽位（魔兽也是这个上限）")
		return
	var before: Array[PlayerSlot] = _players_copy()
	var id: int = 0
	var used: Dictionary = {}
	for p in def.players:
		if p != null:
			used[int(p.id)] = true
			id = maxi(id, int(p.id) + 1)
	var ang: float = TAU * float(id) / 12.0
	var r: float = float(def.size) * 0.30
	var pos := Vector2(cos(ang) * r, sin(ang) * r)
	var colors: Array = MapLoader.spawn_colors_static()
	var col: Color = colors[id % colors.size()] if not colors.is_empty() else Color.WHITE
	var nid: int = int(id)
	var slot := PlayerSlot.make(nid, "enemy", col,
		(1 if def.players.size() % 2 == 0 else 2), pos, 620, 380)
	slot.start_yaw = ang
	def.players.append(slot)
	_push_action("添加玩家 %d" % (nid + 1), [{
		"prop": "players", "before": before, "after": _players_copy(),
	}], UndoRedo.MERGE_DISABLE)
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()
	_emit_status("已添加玩家 %d（共 %d 家）" % [nid + 1, def.players.size()])


## 删掉最后一个玩家槽位（至少留 2 家）
func remove_player() -> void:
	if def == null or def.players.size() <= 2:
		_emit_status("至少要留 2 个玩家槽位")
		return
	var before: Array[PlayerSlot] = _players_copy()
	var gone: PlayerSlot = def.players[def.players.size() - 1]
	def.players.remove_at(def.players.size() - 1)
	# 删掉的槽位上的对象归还给 0 号玩家（不然它们会指向不存在的阵营）
	if gone != null:
		for o in def.objects:
			if o != null and o.owner == gone.id:
				o.owner = 0
	_push_action("删除玩家 %d" % (gone.id + 1 if gone != null else 0), [{
		"prop": "players", "before": before, "after": _players_copy(),
	}], UndoRedo.MERGE_DISABLE)
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()
	_emit_status("已删除最后一个玩家槽位（剩 %d 家）" % def.players.size())


## 队伍一览（"队伍 1：玩家1、玩家2"），玩家页与状态栏共用
func team_summary() -> String:
	if def == null or def.players.is_empty():
		return "无玩家"
	var groups: Dictionary = {}
	for p in def.players:
		if p == null:
			continue
		var t: int = maxi(p.team, 1)
		if not groups.has(t):
			groups[t] = []
		(groups[t] as Array).append(p.id + 1)
	var keys: Array = groups.keys()
	keys.sort()
	var parts: Array[String] = []
	for t in keys:
		var ids: Array = groups[t]
		var names: Array[String] = []
		for i in ids:
			names.append("玩家%d" % int(i))
		parts.append("队伍 %d：%s" % [int(t), "、".join(names)])
	return "　｜　".join(parts)


func update_player(index: int, key: String, value: Variant) -> void:
	if def == null or index < 0 or index >= def.players.size():
		return
	var p: PlayerSlot = def.players[index]
	if p == null:
		return
	var before: Array[PlayerSlot] = _players_copy()
	match key:
		"faction":
			p.faction = String(value)
		"color":
			p.color = value
		"team":
			p.team = int(value)
		"start_pos":
			p.start_pos = value
		"yaw":
			p.start_yaw = float(value)
		"gold":
			p.start_resources["gold"] = int(value)
		"wood":
			p.start_resources["wood"] = int(value)
	_push_action("修改玩家 %d 的 %s" % [p.id, key], [{
		"prop": "players", "before": before, "after": _players_copy(),
	}], UndoRedo.MERGE_ENDS)
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()


func _waves_copy() -> Array[WaveDef]:
	var out: Array[WaveDef] = []
	for w in def.waves:
		out.append(w.clone_wave() if w != null else null)
	return out


func add_wave(region_id: String = "") -> WaveDef:
	if def == null:
		return null
	var before: Array[WaveDef] = _waves_copy()
	var w := WaveDef.make(60.0 + 60.0 * def.waves.size(), {"footman": 4}, region_id, "", 1)
	def.waves.append(w)
	selected_wave_index = def.waves.size() - 1
	_push_action("新增波次", [{"prop": "waves", "before": before, "after": _waves_copy()}])
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()
	return w


func delete_wave(index: int) -> void:
	if def == null or index < 0 or index >= def.waves.size():
		return
	var before: Array[WaveDef] = _waves_copy()
	def.waves.remove_at(index)
	selected_wave_index = clampi(index - 1, 0, maxi(0, def.waves.size() - 1))
	_push_action("删除波次", [{"prop": "waves", "before": before, "after": _waves_copy()}])
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()


func update_wave(index: int, key: String, value: Variant) -> void:
	if def == null or index < 0 or index >= def.waves.size():
		return
	var w: WaveDef = def.waves[index]
	if w == null:
		return
	var before: Array[WaveDef] = _waves_copy()
	match key:
		"time":
			w.time = float(value)
		"difficulty":
			w.difficulty = int(value)
		"composition":
			w.composition = value
		"spawn":
			w.spawn_region = String(value)
		"target":
			w.target_region = String(value)
	_push_action("修改波次 %d" % (index + 1), [{
		"prop": "waves", "before": before, "after": _waves_copy(),
	}], UndoRedo.MERGE_ENDS)
	def_changed.emit("all")
	dirty = true
	dirty_changed.emit()


# ===========================================================================
# 资产
# ===========================================================================

static func _asset_info(type_id: StringName) -> Dictionary:
	for a in MapAssets.all_assets():
		if StringName(a["id"]) == type_id:
			return a
	return {}


# ===========================================================================
# 状态
# ===========================================================================

func _emit_status(text: String) -> void:
	status_changed.emit(text)


func _emit_all(text: String) -> void:
	status_changed.emit(text)
	def_changed.emit("all")
	selection_changed.emit()
	dirty_changed.emit()