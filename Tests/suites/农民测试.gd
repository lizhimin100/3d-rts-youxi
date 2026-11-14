extends Node
## **农民测试**（--peasant-test，2C-4 §4.4）：**纯经济单变量**——
##   · 关掉所有 AI 脑（SimpleAI/副官 set_process(false)），测试脚本直接派工；
##   · 不建额外建筑、不出兵、不科研；
##   · 总农民 N（6~14），金木配比扫 2:1 / 1:1 / 1:2，建造农民单列；
##   · 主指标：**prod_idle_seconds（金 / 木分开）**——分到该桶的农民 order==NONE 的秒数；
##   · 附带：30 s 粒度的金收入曲线（10 min）。
##
## 用法：
##   godot --headless --fixed-fps 60 --path . -- --peasant-test \
##       --peasants=10 --gw=1:1 --builders=0 --minutes=10 --seed=1 [--speed=8]
##
## 输出：stdout 一行 `PEASANT-TEST {json}` + `_qa/peasant_test_<N>_<gw>_<seed>.json`。
## 决策用法：PEASANT_GOLD_SOFT_CAP 取"金空转低位"的下沿 N（TODO 标定），见 2C-4 报告。

const SAMPLE_STEP: float = 0.25

var n_peasants: int = 10
var gw: String = "1:1"          # 采金:采木
var n_builders: int = 0
var minutes: float = 10.0
var seed_val: int = 1

var _acc: float = 0.0
var _done: bool = false
var _t0_msec: int = 0
var _assigned: bool = false
var _gold_idle: float = 0.0     # 金桶空转（秒·人）
var _wood_idle: float = 0.0     # 木桶空转
var _builder_idle: float = 0.0  # 建造桶空转
var _buckets: Dictionary = {}   # unit instance_id → "gold"/"wood"/"build"
var _prev_gold: int = -1
var _income_curve: Array = []   # [{t, gold}]
var _faction: RtsFaction = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--peasants="):
			n_peasants = clampi(int(a.substr(10)), 4, 20)
		elif a.begins_with("--gw="):
			gw = a.substr(5)
		elif a.begins_with("--builders="):
			n_builders = clampi(int(a.substr(11)), 0, 4)
		elif a.begins_with("--minutes="):
			minutes = clampf(float(a.substr(10)), 2.0, 20.0)
		elif a.begins_with("--seed="):
			seed_val = int(a.substr(7))
	seed(seed_val)
	_t0_msec = Time.get_ticks_usec() / 1000
	_faction = Game.player_faction
	if _faction == null:
		_faction = Game.factions[0]
	# ★ 单变量：关掉所有 AI 脑（敌方也停 → 没有战斗干扰经济）
	for group in ["ai_brain", "adjutant"]:
		for n in get_tree().get_nodes_in_group(group):
			if n != null and is_instance_valid(n):
				n.set_process(false)
	print("[农民测试] N=%d 配比=%s 建造=%d 时长=%.0fmin seed=%d（AI 全停，纯经济）"
		% [n_peasants, gw, n_builders, minutes, seed_val])


func _process(delta: float) -> void:
	if _done:
		return
	if not _assigned:
		# 开局 3 农就分配（地图就这些），之后 _top_up 逐步补到 N、_sample 自动归桶
		var workers := _workers()
		if workers.size() < 3 or Game.phase != RtsConst.Phase.RUNNING:
			return
		_assign_all(workers)
		_assigned = true
		return

	# 农民还不够 → 大本营排队补（训练照常走引擎，不算"建额外建筑"）
	_top_up()
	_acc += delta
	if _acc >= SAMPLE_STEP:
		_acc -= SAMPLE_STEP
		_sample(SAMPLE_STEP)
	# 收入曲线（30 s 粒度）
	var idx: int = int(Game.elapsed / 30.0)
	if _income_curve.size() == idx and _faction != null:
		_income_curve.append({"t": idx * 30, "gold": _faction.gold})
	if Game.elapsed >= minutes * 60.0:
		_finish()


func _workers() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for u in _faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if u.def != null and RtsWorld.is_worker_def(u.def):
			out.append(u)
	return out


## 按 --gw 配比把农民分到 金/木/建造 桶并直接 order_gather
func _assign_all(workers: Array) -> void:
	var parts := gw.split(":")
	var g_ratio: float = float(parts[0]) if parts.size() > 0 else 1.0
	var w_ratio: float = float(parts[1]) if parts.size() > 1 else 1.0
	var total: float = maxf(g_ratio + w_ratio, 1.0)
	var n_gold: int = 0
	var n_wood: int = 0
	# 建造桶从头数里出（单列；开局建一座农场然后待命）
	for i in range(workers.size()):
		var bucket: String
		if i < n_builders:
			bucket = "build"
		elif float(i - n_builders) / maxf(float(workers.size() - n_builders), 1.0) < g_ratio / total:
			bucket = "gold"
			n_gold += 1
		else:
			bucket = "wood"
			n_wood += 1
		_buckets[workers[i].get_instance_id()] = bucket
		if bucket == "build":
			continue
		_send(workers[i], bucket == "gold")
	print("[农民测试] 分配：金 %d / 木 %d / 建造 %d" % [n_gold, n_wood, n_builders])
	# 建造桶：建一座农场（用引擎的 order_build，落点吸附与游戏同一实现）
	if n_builders > 0:
		var farm_def: UnitDef = Cfg.unit(&"farm")
		var b: RtsUnit = workers[0]
		if farm_def != null and b != null:
			var raw := RtsWorld.base_center(_faction) + Vector3(8, 0, 6)
			var p: Vector3 = 建筑网格.snap_point(raw, farm_def.footprint)
			if 建筑网格.can_place(p, farm_def.footprint):
				b.order_build(farm_def, p, 建筑网格.snap_yaw(建筑网格.default_yaw()))


func _send(u, want_gold: bool) -> void:
	var kind: int = RtsConst.Harvest.GOLD if want_gold else RtsConst.Harvest.WOOD
	var base: Vector3 = RtsWorld.base_center(_faction)
	var node: Node3D = Game.find_nearest_harvestable(u.global_position, kind, base,
			Cfg.game.map_size * 0.75)
	if node == null and want_gold:
		node = Game.find_nearest_harvestable(u.global_position, RtsConst.Harvest.WOOD, base,
				Cfg.game.map_size * 0.75)
	if node != null:
		u.order_gather(node)


func _top_up() -> void:
	var workers := _workers()
	if workers.size() >= n_peasants:
		return
	var th: RtsBuilding = null
	for b in _faction.buildings:
		if b != null and is_instance_valid(b) and b.is_alive() and b.def != null \
				and b.def.trains.has(&"peasant") and b is RtsBuilding \
				and (b as RtsBuilding).is_constructed:
			th = b
			break
	if th != null and th.train_count() < 2:
		th.queue_train(&"peasant")


## 采样：每桶空转秒数（is_idle_like = order NONE）+ 采集中的资源桶归属
func _sample(step: float) -> void:
	for u in _workers():
		var bucket: String = _buckets.get(u.get_instance_id(), "")
		if bucket.is_empty():
			# 新补的农民：默认按"金桶未满则金，否则木"
			var gold_n: int = 0
			for id in _buckets.keys():
				if _buckets[id] == "gold":
					gold_n += 1
			bucket = "gold" if gold_n < ceili(float(n_peasants) * 0.5) else "wood"
			_buckets[u.get_instance_id()] = bucket
			_send(u, bucket == "gold")
		if bool(u.call("is_idle_like")):
			if bucket == "gold":
				_gold_idle += step
			elif bucket == "wood":
				_wood_idle += step
			elif bucket == "build":
				_builder_idle += step
		# 采集方向跑偏的纠正（离桶判据：gather 的资源种类与桶不符 → 重派）
		if int(u.order) == RtsConst.Order.GATHER:
			var cur_kind: int = int(u.call("gather_kind"))
			var want_kind: int = RtsConst.Harvest.GOLD if bucket == "gold" else RtsConst.Harvest.WOOD
			if cur_kind != want_kind:
				_send(u, bucket == "gold")


func _finish() -> void:
	if _done:
		return
	_done = true
	var wall: float = float(Time.get_ticks_usec() / 1000 - _t0_msec) / 1000.0
	var report := {
		"peasants": n_peasants, "gw": gw, "builders": n_builders,
		"minutes": minutes, "seed": seed_val,
		"最终农民数": _workers().size(),
		"prod_idle_gold": snappedf(_gold_idle, 0.1),
		"prod_idle_wood": snappedf(_wood_idle, 0.1),
		"prod_idle_builder": snappedf(_builder_idle, 0.1),
		"每农民金空转": snappedf(_gold_idle / maxf(_workers().size(), 1), 0.1),
		"金收入": int(_income_curve[-1]["gold"]) if not _income_curve.is_empty() else 0,
		"金收入曲线_30s": _income_curve,
		"wall_s": snappedf(wall, 1.0),
	}
	var path := ProjectSettings.globalize_path(
		"res://_qa/peasant_test_%d_%s_%d.json" % [n_peasants, gw.replace(":", "-"), seed_val])
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(report, "  "))
		fa.close()
	print("PEASANT-TEST %s" % JSON.stringify({
		"N": n_peasants, "gw": gw, "K": n_builders,
		"金空转": report["prod_idle_gold"], "木空转": report["prod_idle_wood"],
		"建造空转": report["prod_idle_builder"],
		"每农民金空转": report["每农民金空转"], "金收入": report["金收入"],
	}))
	get_tree().quit(0)
