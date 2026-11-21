extends Node
## **布局运行时（短局固定基础布局 + 槽位 + 血量继承 + 损毁态）**
##
## 属于：Game/core（引擎耦合层；纯逻辑在 Model/layout/布局卡.gd）
## 对外：setup(level) / boot(path) / is_active() / card_path() /
##       slot_entity(id) / slot_ids() / slot_state(id) / slot_count() /
##       capture() / capture_and_save() / revive_slot(id, hp) / destroyed_count()
##
## 一句话：进短局时读布局卡 → 清掉我方旧布阵（可选）→ 按槽位生成建筑/单位 →
##         把 slot_id 绑到实体 meta 上 → 血量/损毁从上一局存档继承；
##         短局结束（每回合结束 / 胜负）把每个槽位的当前血量写回存档。
##
## 三条硬纪律（对应玩家任务书 §3/§4）：
##   ① **静态/动态分离**：布局卡只有 initial_hp；current_hp 只在存档里；
##   ② **损毁不释放槽位**：建筑血量归零 → 槽位 destroyed=true、node_id=0，
##      槽位仍被占用、不可生产/训练、不提供任何加成；模型隐藏（节点随死亡释放）；
##   ③ **复活唯一入口**：revive_slot()，长局火堆节点以后直接调它。
##
## 为什么槽位记 instance_id 而不是 Node 引用：建筑会被 free，持有引用会在
## 下一帧变成"freed object"（旧版踩过：每帧几十条 cast 错误）。

const CARD := preload("res://Game/adapters/layout_card.gd")
const JsonFile := preload("res://Engine/util/json_file.gd")
## 短局布局存档（跟 SaveSvc.root() 走：测试模式自动隔离到 res://.test_profile/）
const STATE_FILE := "skirmish_layout.json"
const STATE_VERSION := 1

var _level: Node3D = null
var _card: Dictionary = {}
var _card_path: String = ""
## slot_id → {slot_id, type, id, owner_slot, pos(Array), yaw, initial_hp, destroyed, node_id}
var _slots: Dictionary = {}
## 上一局存档里的槽位条目：slot_id → {hp, destroyed}
var _saved: Dictionary = {}
## 实例化前的基地锚点（origin = townhall 时用；清场前一定要先抓）
var _anchors: Dictionary = {}
var _site_anchors: Dictionary = {}
var _active: bool = false
var _spawned: int = 0


func _ready() -> void:
	# 短局规划阶段整棵树 paused；布局运行时要在两个阶段都能响应死亡/保存。
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "LayoutRuntime"


func _exit_tree() -> void:
	# 关游戏/切场景也留一份 —— 但只在关卡还活着时写：
	# 场景卸载时子节点可能已经先被 free，这时候 capture 会把"节点没了"误记成"损毁"。
	if _active and _level != null and is_instance_valid(_level):
		capture_and_save()


## 是否要求"按第一局处理"：自检 / 显式 QA 开关（真实玩家不会带这两个参数）。
func _reset_requested() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--round-test" or a == "--layout-reset":
			return true
	return false


func setup(level: Node3D) -> void:
	_level = level


func is_active() -> bool:
	return _active


func card_path() -> String:
	return _card_path


## 读布局卡 + 实例化。path 为空时读 Cfg.game.short_layout；返回是否成功启用。
func boot(path: String = "") -> bool:
	if Game == null or not Game.short_match:
		return false
	if _active:
		return true
	var p: String = path
	if p.is_empty() and Cfg != null and Cfg.game != null:
		p = String(Cfg.game.short_layout)
	if p.is_empty():
		return false
	if not FileAccess.file_exists(p):
		push_warning("[Layout] card not found: " + p)
		return false
	var parsed: Dictionary = CARD.parse(JsonFile.read_dict(p, {}))
	if not bool(parsed.get("ok", false)):
		push_warning("[Layout] invalid card " + p + " : " + str(parsed.get("errors", [])))
		return false
	_card = parsed.get("card", {})
	_card_path = p
	if _reset_requested():
		# 自检/QA 从"第一局"开始：不清掉上一轮存档，跑第二遍就少几个兵，测试会假红。
		var abs_path: String = ProjectSettings.globalize_path(_state_path())
		if FileAccess.file_exists(_state_path()):
			DirAccess.remove_absolute(abs_path)
		_saved = {}
	else:
		_saved = _load_state(p)
	_capture_anchors()
	_active = true
	if Cfg != null and Cfg.game != null and bool(Cfg.game.short_layout_replace):
		for s in _card.get("replace_owner_slots", []):
			_clear_faction(int(s))
	_instantiate_all()
	if not Game.unit_died.is_connected(_on_unit_died):
		Game.unit_died.connect(_on_unit_died)
	print("[Layout] state carried: %d slots" % _saved.size())
	print("[Layout] booted %s: slots=%d spawned=%d" % [p, _slots.size(), _spawned])
	var th := slot_entity(_slot_id_of("townhall"))
	if th != null:
		print("[Layout] townhall hp=%.0f" % float(th.get("hp")))
	return true


# ===========================================================================
# 实例化
# ===========================================================================

func _capture_anchors() -> void:
	_anchors.clear()
	_site_anchors.clear()
	var bp: Variant = _level.get("_base_pos") if _level != null else null
	for f in Game.factions:
		if f == null or not is_instance_valid(f):
			continue
		var a: Vector3 = Vector3.ZERO
		if _level != null and _level.has_method("base_center"):
			a = _level.call("base_center", f)
		_anchors[f.slot] = Vector2(a.x, a.z)
		if bp is Dictionary and (bp as Dictionary).has(f.slot):
			var sp: Vector2 = (bp as Dictionary)[f.slot]
			_site_anchors[f.slot] = sp
		else:
			_site_anchors[f.slot] = Vector2(a.x, a.z)


func _faction_of(slot: int) -> RtsFaction:
	if Game == null or Game.factions.is_empty():
		return null
	return Game.factions[clampi(slot, 0, Game.factions.size() - 1)]


## 清掉某槽位已有的单位/建筑（"固定基础布局"= 布局卡说了算）。
func _clear_faction(slot: int) -> void:
	var f := _faction_of(slot)
	if f == null:
		return
	for b in f.buildings.duplicate():
		if b == null or not is_instance_valid(b):
			continue
		if _level != null and _level.has_method("clear_footprint"):
			_level.call("clear_footprint", b)
		Game.unregister(b)
		b.queue_free()
	for u in f.units.duplicate():
		if u == null or not is_instance_valid(u):
			continue
		Game.unregister(u)
		u.queue_free()
	f.units.clear()
	f.buildings.clear()
	f.batch_commits.clear()


func _anchor_for(f: RtsFaction) -> Vector2:
	var origin: String = String(_card.get("origin", "site"))
	if origin == "world":
		return Vector2.ZERO
	if origin == "townhall" and _anchors.has(f.slot):
		return _anchors[f.slot]
	if _site_anchors.has(f.slot):
		return _site_anchors[f.slot]
	return Vector2.ZERO


func _instantiate_all() -> void:
	for rec in _card.get("slots", []):
		_spawn_slot(rec as Dictionary)


## 一条卡槽位 → 一个或多个实体（unit 的 count>1 时按 _2/_3 生成独立 slot_id）。
func _spawn_slot(rec: Dictionary) -> void:
	var typ: String = String(rec.get("type", ""))
	var count: int = 1
	if typ == "unit":
		count = maxi(int(rec.get("count", 1)), 1)
	var base_id: String = String(rec.get("slot_id", ""))
	var anchor := _anchor_for(_faction_of(int(rec.get("owner_slot", 0))))
	var wp: Vector2 = CARD.world_pos(String(_card.get("origin", "site")),
			rec.get("pos", [0.0, 0.0]), anchor)
	for i in count:
		var key: String = base_id if i == 0 else "%s_%d" % [base_id, i + 1]
		var off := Vector2.ZERO
		if count > 1:
			var ang: float = TAU * float(i) / float(count)
			off = Vector2(cos(ang), sin(ang)) * 1.15
		var item := {
			"slot_id": key,
			"type": typ,
			"id": String(rec.get("id", "")),
			"owner_slot": int(rec.get("owner_slot", 0)),
			"pos": [wp.x + off.x, wp.y + off.y],
			"yaw": float(rec.get("yaw", 0.0)),
			"initial_hp": float(rec.get("initial_hp", 1.0)),
			"destroyed": false,
			"spawned": false,
			"node_id": 0,
		}
		var saved: Dictionary = _saved.get(key, {})
		_slots[key] = item
		if CARD.is_destroyed(saved):
			item["destroyed"] = true
			continue
		var node := _spawn_entity(item)
		if node == null:
			continue
		var hp: float = CARD.resolve_hp(float(item["initial_hp"]),
				float(saved.get("hp", 0.0)), saved.has("hp"))
		node.set("hp", minf(hp, _max_hp_of(node, float(item["initial_hp"]))))
		item["node_id"] = int(node.get_instance_id())
		item["spawned"] = true
		_spawned += 1


func _spawn_entity(item: Dictionary) -> Node3D:
	var f := _faction_of(int(item.get("owner_slot", 0)))
	if f == null:
		return null
	if _level == null:
		_level = RtsWorld.level()
	if _level == null:
		return null
	var d: UnitDef = Cfg.unit(StringName(String(item.get("id", ""))))
	if d == null:
		push_warning("[Layout] unknown id: " + String(item.get("id", "")))
		return null
	var p: Array = item.get("pos", [0.0, 0.0])
	var pos := Vector3(float(p[0]), 0.0, float(p[1]))
	# 建筑：只吸格 + 贴地，**不做** walkable_pos（否则会被推到旁边一格，布局就对不上）；
	# 单位：吸到最近可走点，避免生在水里/树里。
	if d.kind == RtsConst.Kind.BUILDING:
		pos = RtsWorld.snap_y(建筑网格.snap_point(pos, d.footprint))
	else:
		pos = RtsWorld.walkable_pos(pos)
	var node: Node3D = Game.spawn_unit(f, StringName(String(item.get("id", ""))), pos, _level)
	if node == null:
		return null
	node.set_meta("slot_id", String(item.get("slot_id", "")))
	node.rotation.y = 建筑网格.snap_yaw(float(item.get("yaw", 0.0)))
	if d.kind == RtsConst.Kind.BUILDING:
		if _level != null and _level.has_method("mark_footprint"):
			_level.call("mark_footprint", node)
		if node.has_method("set_constructed"):
			node.call("set_constructed", true)
	return node


## 单位/建筑的满血：`max_hp()` 是**方法**（吃星级/改造倍率），不是属性。
func _max_hp_of(node: Node, fallback: float) -> float:
	if node != null and node.has_method("max_hp"):
		return maxf(float(node.call("max_hp")), 1.0)
	return maxf(fallback, 1.0)


# ===========================================================================
# 槽位查询（游戏侧统一从这里读；不要直接拿 node）
# ===========================================================================

func slot_ids() -> Array:
	return _slots.keys()


## 按内容 id（townhall/farm…）找第一个槽位 id；没有返回空串。
func _slot_id_of(def_id: String) -> String:
	for k in _slots.keys():
		if String((_slots[k] as Dictionary).get("id", "")) == def_id:
			return String(k)
	return ""


func slot_count() -> int:
	return _slots.size()


func destroyed_count() -> int:
	var n: int = 0
	for k in _slots.keys():
		if bool((_slots[k] as Dictionary).get("destroyed", false)):
			n += 1
	return n


func slot_entity(slot_id: String) -> Node3D:
	var rec: Variant = _slots.get(slot_id, null)
	if not (rec is Dictionary):
		return null
	var nid: int = int((rec as Dictionary).get("node_id", 0))
	if nid == 0:
		return null
	var raw: Variant = instance_from_id(nid)
	if raw == null or not is_instance_valid(raw) or not (raw is Node3D):
		return null
	var node := raw as Node3D
	if node.has_method("is_alive") and not bool(node.call("is_alive")):
		return null
	return node


func slot_state(slot_id: String) -> Dictionary:
	var rec: Variant = _slots.get(slot_id, null)
	if not (rec is Dictionary):
		return {}
	var r: Dictionary = rec
	var node := slot_entity(slot_id)
	var killed: bool = bool(r.get("destroyed", false)) or node == null
	return {
		"slot_id": slot_id,
		"id": String(r.get("id", "")),
		"type": String(r.get("type", "")),
		"owner_slot": int(r.get("owner_slot", 0)),
		"destroyed": killed,
		"hp": float(node.get("hp")) if node != null else 0.0,
		"initial_hp": float(r.get("initial_hp", 1.0)),
	}


# ===========================================================================
# 存档：每回合结束 / 胜负时把当前血量写回（静态卡 + 动态存档分离）
# ===========================================================================

func _state_path() -> String:
	return SaveSvc.root() + STATE_FILE


func _load_state(path: String) -> Dictionary:
	var data: Dictionary = JsonFile.read_dict(_state_path(), {})
	if data.is_empty():
		return {}
	# 换了一张布局卡：旧存档不是这个布局的，按第一局处理（不串血）。
	if String(data.get("layout_path", "")) != path:
		return {}
	var slots: Variant = data.get("slots", {})
	return slots if slots is Dictionary else {}


func capture() -> Dictionary:
	var out: Dictionary = {}
	for sid in _slots.keys():
		var rec: Dictionary = _slots[sid]
		var node := slot_entity(sid)
		if node != null and not bool(rec.get("destroyed", false)):
			out[sid] = CARD.state_of(float(node.get("hp")), float(rec.get("initial_hp", 1.0)))
		elif bool(rec.get("destroyed", false)):
			out[sid] = {"hp": 0.0, "destroyed": true}
		else:
			# 这一局根本没生成出来（卡错 / 地图没准备好）：**不要把"没生成"写成"损毁"**，
			# 否则一次失败会把整张布局永久锁死（2026-11-15 实测踩过）。保持上一份存档原样。
			var prev: Variant = _saved.get(sid, null)
			out[sid] = prev if prev is Dictionary else {"hp": float(rec.get("initial_hp", 1.0)), "destroyed": false}
	return out


func capture_and_save() -> Dictionary:
	if not _active:
		return {}
	_saved = capture()
	var payload := {
		"version": STATE_VERSION,
		"layout_id": String(_card.get("id", "")),
		"layout_path": _card_path,
		"saved_at": Time.get_datetime_string_from_system(true),
		"slots": _saved,
	}
	var err: int = JsonFile.write_atomic(_state_path(), payload)
	if err != OK:
		push_warning("[Layout] save failed: %d" % err)
	return _saved


# ===========================================================================
# 损毁态 / 复活
# ===========================================================================

func _on_unit_died(unit: Node3D) -> void:
	if not _active or unit == null or not is_instance_valid(unit):
		return
	var sid: String = String(unit.get_meta("slot_id", ""))
	if sid.is_empty() or not _slots.has(sid):
		return
	var rec: Dictionary = _slots[sid]
	rec["destroyed"] = true
	rec["node_id"] = 0
	_slots[sid] = rec


## **预留接口 ReviveSlot(slot_id)**：长局火堆节点调用。
## 调用后槽位恢复为可用状态（血量 = initial_hp 或显式 hp），模型与功能一起回来。
func revive_slot(slot_id: String, hp: float = -1.0) -> Node3D:
	if not _active or not _slots.has(slot_id):
		return null
	var cur := slot_entity(slot_id)
	if cur != null:
		return cur
	var rec: Dictionary = _slots[slot_id]
	var node := _spawn_entity(rec)
	if node == null:
		return null
	var use_hp: float = float(rec.get("initial_hp", 1.0)) if hp <= 0.0 else clampf(hp, 1.0, float(rec.get("initial_hp", 1.0)))
	node.set("hp", minf(use_hp, _max_hp_of(node, float(rec.get("initial_hp", 1.0)))))
	rec["destroyed"] = false
	rec["node_id"] = int(node.get_instance_id())
	_slots[slot_id] = rec
	_saved[slot_id] = CARD.state_of(use_hp, float(rec.get("initial_hp", 1.0)))
	capture_and_save()
	return node
