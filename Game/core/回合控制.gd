extends Node
## **回合控制器（短局）**：准备阶段 ⇄ 执行阶段。
##
## 职责：
##   · 准备阶段：世界 `paused`，玩家排命令 / 放建筑 / 排队训练；
##   · 开始执行：把 `CommandSystem.planned` 里的命令一次性发给单位，解冻世界；
##   · 执行阶段：倒计时；清波或时间到 → 回准备阶段；
##   · 3 个执行回合一局，清完最后一波判胜。
##
## 明确不做：
##   · 不做经济 AI（敌方波次是脚本生成的，避免"没金币/没农民"的空转）；
##   · 不做士气（用户明确要求）；
##   · 不接管单位行为（命令仍走 RtsUnit.order_*）。
##
## 长局不挂这个节点（主场景只在 Game.short_match 时挂）。

## 每回合执行时长（秒）的兜底；优先读 Cfg.game.short_execution_seconds
const EXEC_FALLBACK := 60.0
## 清波后停留多久再回准备（让玩家看清战场）
const CLEAR_GRACE := 2.0
## 波次编成（下标 = 回合-1；不够就复用最后一档）
## 只放已存在的 id；数量别太大，先保证 3 回合能跑完。
const WAVES: Array = [
	{"footman": 3, "archer": 2},
	{"footman": 4, "archer": 2, "mage": 1},
	{"footman": 4, "archer": 3, "mage": 1, "golem": 1},
]
## 出兵环半径（米）
const SPAWN_RADIUS := 8.0

## 当前回合（1 起；0 = 还没开始）
var round_index: int = 0
## 执行阶段剩余秒数
var execution_left: float = 0.0
## 上一次结束原因（诊断/自检）
var last_reason: String = ""
## 本回合脚本生成的单位（清波判定只认它们，不误判地图上预置的敌人）
var _wave_units: Array = []
var _clear_timer: float = 0.0
var _level: Node3D = null


func _ready() -> void:
	# 准备阶段整棵树 paused，但本节点要负责"开始执行/结束执行"，必须常驻。
	process_mode = Node.PROCESS_MODE_ALWAYS
	Game.round_control = self


func setup(level: Node3D) -> void:
	_level = level
	round_index = 0
	execution_left = 0.0
	_wave_units.clear()
	_clear_timer = 0.0


func rounds() -> int:
	return maxi(int(Cfg.game.short_rounds), 1)


func execution_total() -> float:
	return maxf(float(Cfg.game.short_execution_seconds), 5.0) if Cfg.game != null else EXEC_FALLBACK


## HUD 用：当前阶段一句话
func phase_text() -> String:
	if Game.is_prepare():
		return "准备阶段 · 第 %d / %d 回合" % [mini(round_index + 1, rounds()), rounds()]
	if Game.is_executing():
		return "执行阶段 · 剩余 %02d 秒" % int(ceil(execution_left))
	if Game.phase == RtsConst.Phase.VICTORY:
		return "胜利"
	if Game.phase == RtsConst.Phase.DEFEAT:
		return "战败"
	return ""


func wave_alive_count() -> int:
	var n: int = 0
	for u in _wave_units:
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		if (u as RtsUnit).is_alive():
			n += 1
	return n


## **开始执行**（HUD 按钮唯一入口）。
## 顺序很重要：先把计划命令发出去（此时世界还冻着），再解冻。
func begin_execution() -> bool:
	if not Game.is_prepare():
		return false
	if Game.player_faction == null:
		return false
	# 已打完所有回合：直接判胜（防止玩家点开始后无限空转）
	if round_index >= rounds() and wave_alive_count() == 0:
		Game.trigger_victory()
		return false
	var cs := _command_system()
	if cs != null and cs.has_method("execute_planned"):
		cs.call("execute_planned")
	round_index += 1
	_clear_timer = 0.0
	execution_left = execution_total()
	Game.set_phase(RtsConst.Phase.RUNNING)
	_spawn_wave()
	Game.toast("执行阶段开始（第 %d / %d 回合）" % [round_index, rounds()], Cfg.game.hud_accent)
	return true


## **结束执行**：回到准备阶段（世界重新冻结）。清完最后一波则判胜。
func end_execution(reason: String = "") -> void:
	if not Game.is_executing():
		return
	last_reason = reason
	if round_index >= rounds() and wave_alive_count() == 0:
		Game.trigger_victory()
		return
	Game.set_phase(RtsConst.Phase.PREPARE)
	Game.toast("准备阶段 · 第 %d / %d 回合" % [mini(round_index + 1, rounds()), rounds()],
			Cfg.game.hud_accent)


func _process(delta: float) -> void:
	if Game.is_executing():
		execution_left = maxf(execution_left - delta, 0.0)
		# 玩家没有兵也没有建筑 = 彻底出局
		var pf := Game.player_faction
		if pf != null and pf.count_units() == 0 and pf.count_buildings() == 0:
			Game.trigger_defeat()
			return
		# 清波：脚本波次全灭后停留 CLEAR_GRACE 秒，让玩家看清再回准备
		if round_index > 0 and wave_alive_count() == 0:
			_clear_timer += delta
			if _clear_timer >= CLEAR_GRACE:
				end_execution("清波")
				return
		else:
			_clear_timer = 0.0
		if execution_left <= 0.0:
			end_execution("时间到")
	elif Game.is_prepare():
		var pf2 := Game.player_faction
		if pf2 != null and round_index > 0 and pf2.count_units() == 0 and pf2.count_buildings() == 0:
			Game.trigger_defeat()


## 生成当前回合的敌方波次。上一波没清完就不刷，避免无限叠兵。
func _spawn_wave() -> void:
	if wave_alive_count() > 0:
		Game.toast("上一波还没清完，本回合不增援", Cfg.game.enemy_color)
		return
	var foe := _enemy_faction()
	if foe == null:
		return
	var pack: Dictionary = WAVES[clampi(round_index - 1, 0, WAVES.size() - 1)]
	var base: Vector3 = _base_of(foe)
	var target: Vector3 = _base_of(Game.player_faction)
	var i: int = 0
	var ids: Array = pack.keys()
	for id in ids:
		var n: int = int(pack[id])
		for k in n:
			var ang: float = TAU * float(i) / 12.0 + float(round_index) * 0.7
			var pos := base + Vector3(cos(ang) * SPAWN_RADIUS, 0.0, sin(ang) * SPAWN_RADIUS)
			pos = RtsWorld.snap_y(RtsWorld.walkable_pos(pos))
			var u: Node3D = Game.spawn_unit(foe, StringName(id), pos, _level)
			if u != null:
				_wave_units.append(u)
				if u.has_method("order_attack_move"):
					u.call("order_attack_move", target)
				elif u.has_method("order_move"):
					u.call("order_move", target)
			i += 1


func _base_of(f: RtsFaction) -> Vector3:
	if f == null:
		return Vector3.ZERO
	if _level != null and _level.has_method("base_center"):
		return _level.call("base_center", f)
	if f.slot == 0:
		return Vector3(Cfg.game.player_base_pos.x, 0.0, Cfg.game.player_base_pos.y)
	return Vector3(Cfg.game.enemy_base_pos.x, 0.0, Cfg.game.enemy_base_pos.y)


func _enemy_faction() -> RtsFaction:
	if Game.player_faction == null:
		return null
	for f in Game.factions:
		if f != null and Game.player_faction.is_enemy_of(f):
			return f
	return null


func _command_system() -> Node:
	var p := get_parent()
	if p == null:
		return null
	var n := p.get("command_system") as Node
	if n == null:
		n = p.get_node_or_null("指令系统")
	return n
