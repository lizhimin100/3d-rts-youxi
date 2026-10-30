class_name Adjutant
extends SimpleAI
## **副官（玩家侧指挥官）** —— 只在游戏里跑，**不进地图编辑器**。
##
## 和敌方 `SimpleAI` **是同一套大脑**（同一个脚本继承下来的），所以不会出现
## "人机会配合、副官只会挖矿"这种两套逻辑打架的情况。副官只覆盖三件事：
##   1. 指挥**玩家**阵营（`command_faction = Game.player_faction`）；
##   2. 反应比一般中等 AI 更快（`think_scale = 0.8`）、农民上限更高（18）；
##   3. 只从**闲着的**农民里抽人盖房 —— 玩家正在指挥的农民一个都不动。
##
## 因此副官也会做：补农 / 采金伐木 / 造农场·兵营·铁匠铺·箭塔 /
## 按波次出兵 / 分兵出击 / 残血撤退 / 家门口巡逻 / 建筑被打回防。
##
## 玩家随时接管：选中任意单位下命令，副官看到 `order != NONE` 就不会再碰它。

## 副官的反应倍率（比一般中等 AI 快 20%）
const ADJ_THINK_SCALE: float = 0.8
## 农民上限：比敌方 AI 高（农民不占人口，多造不吃亏）
const PEASANT_MAX: int = 18

## 是否启用（HUD 小地图下方的「副官 · 开/关」按钮控制；`--no-adjutant` 启动即关）
var enabled: bool = true


func _ready() -> void:
	log_prefix = "[副官]"
	think_scale = ADJ_THINK_SCALE
	command_faction = Game.player_faction
	# 注册进组：HUD 靠组名找人，不依赖"HUD 是不是主场景的直接子节点"
	add_to_group("adjutant")
	if "--no-adjutant" in OS.get_cmdline_user_args():
		enabled = false
		set_process(false)
		print("%s 已关闭（--no-adjutant）" % log_prefix)
		return
	_faction = command_faction
	if _faction != null:
		_init_wave_clock()


## 开关（HUD 按钮调用）：关掉就彻底不动手，玩家的每个单位都归自己
func set_enabled(on: bool) -> void:
	enabled = on
	set_process(on)
	_log("已开启" if on else "已关闭")


## 覆盖：农民上限按副官口径，而且钱少时只保底到 8 个（其余留给军队）
func _manage_peasants(diff: DifficultyDef) -> void:
	var peasants: int = _faction.count_units(&"peasant")
	if peasants >= PEASANT_MAX:
		return
	var townhall: RtsBuilding = _first_building(&"townhall")
	if townhall == null:
		return
	if townhall.train_count() >= MAX_QUEUE_PEASANT:
		return
	# 农民不占人口，但**占金币**：军队快凑齐时先别把最后一点钱砸进农民
	var army: int = _army_units().size()
	if peasants >= 8 and _faction.gold < 90 and army < diff.max_army:
		return
	if townhall.queue_train(&"peasant"):
		_log("补农民（现有 %d / 上限 %d）" % [peasants, PEASANT_MAX])


## 覆盖：**只挑闲着的农民**盖房。父类会从采集队里抽人，
## 那在"玩家自己管经济"的场景下就是抢人，必须改。
func _pick_builder() -> RtsUnit:
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
			continue
		if u.order == RtsConst.Order.BUILD:
			return null  # 已经在盖了
		if bool(u.call("is_idle_like")):
			return u
	return null


## 覆盖：副官带队**更稳**——留 30% 守家（人机只留 18%），
## 而且不会在"兵力刚刚够"的时候就把人送出去。
func _manage_waves(diff: DifficultyDef) -> void:
	if Game.elapsed < _next_wave_at:
		return
	var army: Array = _army_units()
	if army.size() < maxi(diff.min_wave_size, 3):
		return
	# 比人机更愿意出击（+0.15），但也更会留人
	if randf() > clampf(diff.aggression + 0.15, 0.0, 1.0):
		return
	var push_n: int = clampi(int(ceil(float(army.size()) * 0.70)), 1, army.size())
	var target_pos: Vector3 = _push_target()
	var home: Vector3 = RtsWorld.base_center(_faction)
	for i in range(army.size()):
		var u: RtsUnit = army[i]
		if u == null or not is_instance_valid(u):
			continue
		if i < push_n:
			u.order_attack_move(target_pos)
		else:
			var ang: float = randf() * TAU
			u.order_move(home + Vector3(cos(ang) * 15.0, 0.0, sin(ang) * 15.0))
	_wave_index += 1
	var interval: float = maxf(
		diff.wave_interval - diff.wave_interval_decay * float(_wave_index),
		diff.wave_interval_min)
	_next_wave_at = Game.elapsed + interval
	_log("带队推进：%d 出击 / %d 留守 → %s（下一波 +%.0fs）" % [
		push_n, army.size() - push_n, _foe_name(), interval])
