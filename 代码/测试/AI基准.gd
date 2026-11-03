extends Node
## **AI 基准（--ai-bench）**：固定条件跑一局**真实对局**，采集 P0 指标 + 情况文本 dump。
##
## 定位（本轮纪律）：
##   · 这是**量测工具**，不是 AI 的一部分 —— 只读状态、订全局信号，不改任何 AI 行为文件；
##   · 情况文本（--dump-situations）由引擎在对局中现场生成，**禁止**人工编写/润色；
##   · 复用 AUTOTEST 的输出口径：结尾打印一行 `AI-BENCH {json}`，方便脚本 grep。
##
## 用法（全部参数走 `--` 之后的 user args，与主场景 _parse_cmdline 同一口径）：
##   godot --headless --fixed-fps 60 --path . --quit-after 20000 -- \
##       --ai-bench --seed=1 --minutes=8 --speed=8 \
##       --map=res://地图/主场景地图.tres [--ratio-mode=A|B|C] \
##       [--dump-situations=res://_qa/situations_1.jsonl]
##
## `--ratio-mode` 只改"出击门槛跟谁比"（A 最强 / B 次强 / C 门槛衰减，默认 A）。
## 这是 2.2 的死锁试验开关：三组跑同一 seed，其它一切都必须相同。
##
## 输出：
##   _qa/bench_<seed>.json   完整指标（P0）+ 事件时间线 + 确定性签名
##   _qa/situations_<seed>.jsonl  情况文本（周期快照 + 关键决策前后各一条）
##   stdout: `AI-BENCH {json}`（人读摘要）+ `AI-BENCH-SIGNATURE <串>`（同 seed 复跑比对用）
##
## P1 指标（编队完整率/集结时间/占点/目标出视野行为…）依赖任务层/情报层，本轮**不可采**，
## 在 JSON 里固定写 `"P1": "不可采：无任务层与情报层（见 4.2 诊断）"`。

## 采样步长（游戏秒）：单位级状态轮询的粒度
const SAMPLE_STEP: float = 0.25
## 情况文本周期快照间隔（游戏秒）
const SITUATION_EVERY: float = 5.0
## 2C-5 军队规模 / 人口占用曲线采样间隔（游戏秒）
const CURVE_STEP: float = 60.0
## 战略权重开关（A/B/C）。默认 A，保证"不带参数 = 现状"。
const AIW := preload("res://代码/配置/AI战略权重.gd")
## 判定口径开关（old/new）+ 理论值参数（2C-3）。
const AIV := preload("res://代码/配置/AI判定模式.gd")
## 护栏公式复用战斗模型的纯函数（不抄阈值）
const _bench_model := preload("res://代码/ai/战斗模型.gd")

# --- 参数 ---
var seed_val: int = 1
var minutes: float = 8.0
var speed: float = 8.0
var map_path: String = ""
var dump_path: String = ""
var ratio_mode_arg: String = "A"
## 输出文件名后缀（`--tag=_4min` → bench_A_1_4min.json）。
## 用途：同一 seed 要跑多组时长/多组口径时，别让后一组把前一组的证据覆盖掉。
var tag: String = ""

# --- 状态 ---
var _acc: float = 0.0            # 采样累计
var _sit_acc: float = 0.0        # 情况文本累计
var _curve_acc: float = 0.0      # 军队规模/人口曲线累计（2C-5，每 60 游戏秒一行）
var _done: bool = false
var _t0_msec: int = 0

## 每个 AI 脑一份的观测（faction 名 → Dictionary）
var _brains: Array = []          # [{node, faction, prev_think, prev_wave, prev_plan, prev_defend_cd, prev_allow}]
## 全体阵营的累计指标（faction 名 → Dictionary）
var _stats: Dictionary = {}
## 2C-5：军队规模 / 人口占用曲线（faction 名 → [{t, army, pop_used, pop_cap}]，60 s 粒度）
var _curves: Dictionary = {}
## 事件时间线（关键决策逐条）
var _events: Array = []
## 每个阵营最近一次决策（写进情况文本 recent_decision）
var _recent: Dictionary = {}
## 撤退代理：unit 实例 id → 上次血量比例（识别"重伤事件"）
var _wounded_seen: Dictionary = {}
## 确定性签名采样（每 30 游戏秒压一行）
var _sig_lines: Array = []
var _file_bench: String = ""
var _file_sit: String = ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--seed="):
			seed_val = int(a.substr(7))
		elif a.begins_with("--minutes="):
			minutes = float(a.substr(10))
		elif a.begins_with("--speed="):
			speed = maxf(float(a.substr(8)), 0.1)
		elif a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--dump-situations="):
			dump_path = a.substr(18)
		elif a.begins_with("--ratio-mode="):
			ratio_mode_arg = a.substr(13)
		elif a.begins_with("--tag="):
			tag = a.substr(6)
	# ★ 判定口径必须在**任何 AI 思考之前**定下来（简单AI 每 tick 读它）
	AIV.setup_from_cmdline()
	for a in args:
		if a.begins_with("--verdict-mode="):
			AIV.set_mode(a.substr(String("--verdict-mode=").length()))
		elif a.begins_with("--verdict-base-sec="):
			AIV.set_base_sec(float(a.substr(String("--verdict-base-sec=").length())))
		elif a.begins_with("--verdict-coef="):
			AIV.set_output_coef(float(a.substr(String("--verdict-coef=").length())))
	# ★ 出击门槛口径必须在**任何 AI 思考之前**定下来（简单AI 每 tick 读它）
	AIW.set_mode(ratio_mode_arg)
	# ★ 确定性：对局开始前固定全局 RNG。地图是固定 .tres、帧率定死 60，
	#   AI 的随机（波次骰/巡逻/加权选兵）全部来自这里的种子。
	seed(seed_val)
	# ★ 时间缩放由 主场景._parse_cmdline 的 --speed= 在首帧前设好（别在这里设：
	#   在本节点 _ready 里设，首帧时序一差就会让 Game.elapsed 的起点差一帧）。
	_t0_msec = Time.get_ticks_usec() / 1000
	if not is_equal_approx(Engine.time_scale, speed):
		print("[AI基准] ⚠ time_scale=%.2f 与 --speed=%.2f 不一致（缺 --speed= 参数？）"
			% [Engine.time_scale, speed])

	Game.combat_hit.connect(_on_hit)
	Game.unit_died.connect(_on_death)
	_collect_brains()
	for f in Game.factions:
		if f == null:
			continue
		_stats[f.display_name] = _new_faction_stats(f)

	if not dump_path.is_empty():
		_file_sit = _abs(dump_path)
		DirAccess.make_dir_recursive_absolute(_file_sit.get_base_dir())
		var fa := FileAccess.open(_file_sit, FileAccess.WRITE)
		if fa != null:
			fa.close()
			print("[AI基准] 情况文本 → %s" % _file_sit)
		else:
			print("[AI基准] 打不开情况文本输出：%s" % _file_sit)
	print("[AI基准] 开始：seed=%d minutes=%.1f speed=%.1f 地图=%s 口径=%s 判定=%s 耗时上限(墙钟)=%.0fs"
		% [seed_val, minutes, speed, map_path if not map_path.is_empty() else "(默认)",
			AIW.describe(), AIV.describe(), minutes * 60.0 * 8.0])


func _process(delta: float) -> void:
	if _done:
		return
	if Game.phase == RtsConst.Phase.VICTORY or Game.phase == RtsConst.Phase.DEFEAT:
		_finish("对局结束：phase=%d" % Game.phase)
		return
	if Game.elapsed >= minutes * 60.0:
		_finish("到达时限 %.0f 游戏秒" % (minutes * 60.0))
		return

	_watch_brains()          # 逐帧：思考边界 / 波次 / 拒绝 / 回防 / 计划切换
	_acc += delta
	while _acc >= SAMPLE_STEP:
		_acc -= SAMPLE_STEP
		_sample_units(SAMPLE_STEP)
	_sit_acc += delta
	while _sit_acc >= SITUATION_EVERY:
		_sit_acc -= SITUATION_EVERY
		_dump_situations(false)
	# 2C-5：军队规模 / 人口占用曲线（60 s 一行，看"是否顶死"）
	_curve_acc += delta
	if _curve_acc >= CURVE_STEP:
		_curve_acc -= CURVE_STEP
		_sample_curve()
	_sig_sample()




# ===========================================================================
# 脑观测
# ===========================================================================

func _collect_brains() -> void:
	var seen := {}
	var nodes: Array = get_tree().get_nodes_in_group("ai_brain")
	nodes.append_array(get_tree().get_nodes_in_group("adjutant"))
	for n in nodes:
		if n == null or not is_instance_valid(n) or seen.has(n.get_instance_id()):
			continue
		seen[n.get_instance_id()] = true
		var f = n.get("command_faction")
		if f == null:
			f = n.get("_faction")
		if f == null:
			continue
		_brains.append({
			"node": n, "faction": f,
			"prev_think": -1.0, "prev_wave": -1,
			"prev_plan": "", "prev_defend_cd": 0.0, "prev_allow": false,
			"prev_allow_think": false,
			"primed": false,
		})


## 逐帧盯每个脑的公开字段：只在**状态跳变**处立案，不额外扫场景。
func _watch_brains() -> void:
	for b in _brains:
		var n = b["node"]
		if n == null or not is_instance_valid(n):
			continue
		# 首次观察：只同步基线，不立案（否则开局状态会被误报成事件）
		if not bool(b["primed"]):
			b["primed"] = true
			b["prev_think"] = float(n.get("_think"))
			b["prev_wave"] = int(n.get("_wave_index"))
			b["prev_defend_cd"] = float(n.get("_defend_cd"))
			var p0: Dictionary = n.get("posture")
			b["prev_plan"] = String(p0.get("plan_id", ""))
			b["prev_allow"] = bool(p0.get("allow_attack", false))
			continue
		var fac: String = String(b["faction"].display_name)
		var think: float = float(n.get("_think"))
		var wave: int = int(n.get("_wave_index"))
		var defend_cd: float = float(n.get("_defend_cd"))
		var posture: Dictionary = n.get("posture")
		var plan: String = String(posture.get("plan_id", ""))
		var allow: bool = bool(posture.get("allow_attack", false))
		var st: Dictionary = {}
		var sched = n.get("_sched")
		if sched != null and is_instance_valid(sched):
			st = sched.call("stats")

		# ① 思考边界：_think 被重置（跳回正间隔）= 刚完成一次思考 → 结算调度统计
		if think > b["prev_think"] and b["prev_think"] >= 0.0:
			_on_think(b, fac, st, posture)
		b["prev_think"] = think

		# ② 波次真的打出去了（目标坐标现场问脑的只读函数 _push_target()）
		if wave > int(b["prev_wave"]):
			var tgt: String = ""
			if n.has_method("_push_target"):
				tgt = str(n.call("_push_target"))
			_event(fac, "wave_issued", {
				"wave_index": wave,
				"target": tgt,
			}, "波次推进")
			var st2: Dictionary = _stats.get(fac, {})
			if int(st2.get("first_wave_t", -1)) < 0:
				st2["first_wave_t"] = Game.elapsed
			st2["wave_count"] = int(st2.get("wave_count", 0)) + 1
			b["prev_wave"] = wave
		elif wave < int(b["prev_wave"]):
			b["prev_wave"] = wave    # 重开/阵营变更兜底

		# ③ 计划切换
		if plan != String(b["prev_plan"]) and not plan.is_empty():
			if not String(b["prev_plan"]).is_empty():
				_event(fac, "plan_switch", {
					"from": String(b["prev_plan"]), "to": plan,
					"army_ratio": float(posture.get("army_ratio", 0.0)),
					"base_threat": float(posture.get("base_threat", 0.0)),
				}, "计划切换 → %s" % plan)
			b["prev_plan"] = plan

		# ④ 回防触发：_defend_cd 从低位跳到 DEFEND_REISSUE
		var reissue: float = 4.0
		if n.get("DEFEND_REISSUE") != null:
			reissue = float(n.get("DEFEND_REISSUE"))
		if b["prev_defend_cd"] < 0.5 and defend_cd >= reissue * 0.9:
			var threat_n: int = 0
			var m: Dictionary = n.get("metrics")
			if m != null:
				threat_n = int(float(m.get("base_threat", 0.0)))
			_event(fac, "defense_triggered", {"threat_units": threat_n}, "回防触发")
			var st3: Dictionary = _stats.get(fac, {})
			st3["defense_count"] = int(st3.get("defense_count", 0)) + 1
			if int(st3.get("first_defense_t", -1)) < 0:
				st3["first_defense_t"] = Game.elapsed
			# 防守响应口径：只认"建筑真的开始掉血之后"的第一次回防。
			# 掉血前就回防 = 预判成功，另记 preemptive（见 _finish）。
			if float(st3.get("first_base_damage_t", -1)) >= 0.0 \
					and float(st3.get("first_defense_after_damage_t", -1)) < 0.0:
				st3["first_defense_after_damage_t"] = Game.elapsed
			_recent[fac] = {"name": "defense_triggered", "t": Game.elapsed,
				"detail": {"threat_units": threat_n}}
		b["prev_defend_cd"] = defend_cd
		b["prev_allow"] = allow


## 一次思考刚发生：结算调度统计 + 出击拒绝判定
func _on_think(b: Dictionary, fac: String, st: Dictionary, posture: Dictionary) -> void:
	var s: Dictionary = _stats.get(fac, {})
	s["think_count"] = int(s.get("think_count", 0)) + 1
	# 出击许可按**思考**统计（按帧统计会被"许可一直为真"吞掉上升沿）：
	#   allow_on_think  = 许可开着的思考次数；
	#   allow_attack_on = 其中 false→true 的上升沿次数（B/C 关心的"门槛真的松开了"）。
	var allow_now: bool = bool(posture.get("allow_attack", false))
	if allow_now:
		s["allow_on_think"] = int(s.get("allow_on_think", 0)) + 1
		if not bool(b.get("prev_allow_think", false)):
			s["allow_attack_on"] = int(s.get("allow_attack_on", 0)) + 1
	b["prev_allow_think"] = allow_now
	# 门槛区间（C 的衰减曲线要能在数据里看见）
	var need: float = float(posture.get("attack_ratio_needed", 0.0))
	if need > 0.0:
		s["need_min"] = minf(float(s.get("need_min", 99.0)), need)
		s["need_max"] = maxf(float(s.get("need_max", 0.0)), need)
	s["cmd_sent"] = int(s.get("cmd_sent", 0)) + int(st.get("sent", 0))
	s["cmd_skipped"] = int(s.get("cmd_skipped", 0)) + int(st.get("skipped", 0))
	s["cmd_throttled"] = int(s.get("cmd_throttled", 0)) + int(st.get("throttled", 0))
	s["cmd_filtered_player"] = int(s.get("cmd_filtered_player", 0)) + int(st.get("filtered_player", 0))
	s["cmd_stuck_locked"] = int(s.get("cmd_stuck_locked", 0)) + int(st.get("stuck_locked", 0))
	# 出击拒绝：波次到期却没拿到许可（每个思考至多记一次）
	var n = b["node"]
	var next_at: float = float(n.get("_next_wave_at"))
	if Game.elapsed >= next_at and not bool(posture.get("allow_attack", false)):
		s["attack_rejected"] = int(s.get("attack_rejected", 0)) + 1
		var reason: String = String(n.call("_block_reason"))
		var key: String = reason.substr(0, 24)
		var dist: Dictionary = s.get("reject_reasons", {})
		dist[key] = int(dist.get(key, 0)) + 1
		s["reject_reasons"] = dist
		if int(s.get("last_reject_log_t", -999)) < Game.elapsed - 20.0:
			_event(fac, "attack_rejected", {"reason": reason}, "暂不出击")
			s["last_reject_log_t"] = Game.elapsed


# ===========================================================================
# 单位级采样（每 SAMPLE_STEP 一次）
# ===========================================================================

func _new_faction_stats(f: RtsFaction) -> Dictionary:
	return {
		"faction": f.display_name, "is_player": f.is_player, "team": f.team,
		"gold_income": 0, "wood_income": 0,
		"idle_unit_seconds": 0.0, "stuck_unit_seconds": 0.0, "stuck_max_units": 0,
		# prod_idle_seconds = **新口径**（2026-11-03 2C-2：加了 army < max_army，
		#   只统计"该造却没造"，不再把"已满编"算成空转）；
		# prod_idle_seconds_legacy = 旧口径（不判满编），保留只为同一跑里做新旧对比。
		"prod_idle_seconds": 0.0, "prod_idle_seconds_legacy": 0.0,
		# 该阵营的军队规模上限（一切口径都来自难度档，不写死）
		"max_army": int(Cfg.difficulty(Game.difficulty_index).max_army),
		"broke_seconds": 0.0, "broke_episodes": 0, "_was_broke": false,
		"damage_dealt": 0.0, "damage_taken": 0.0,
		"units_lost": 0, "buildings_lost": 0,
		"wounded_episodes": 0, "_wounded_alive_units": 0,
		"first_wave_t": -1, "wave_count": 0,
		"attack_rejected": 0, "reject_reasons": {}, "last_reject_log_t": -999.0,
		"allow_attack_on": 0, "allow_on_think": 0, "need_min": 99.0, "need_max": 0.0,
		"defense_count": 0, "first_defense_t": -1,
		"first_base_damage_t": -1, "base_damage_taken": 0.0,
		# 防守响应专用：建筑掉血**之后**的第一次回防 + "打之前就已经在回防"的标记
		"first_defense_after_damage_t": -1.0, "defense_preemptive": false,
		# 交叉校验：按"建筑总血量差值"采到的伤害（会漏掉 unregister 那一瞬的终末伤害，
		# 所以只做对照，不进 base_damage_taken）
		"base_damage_hp_sample": 0.0, "base_damage_by_death": 0,
		"think_count": 0,
		"cmd_sent": 0, "cmd_skipped": 0, "cmd_throttled": 0,
		"cmd_filtered_player": 0, "cmd_stuck_locked": 0,
		"prev_gold": f.gold, "prev_wood": f.wood, "prev_bldg_hp": 0.0,
	}


func _sample_units(step: float) -> void:
	for f in Game.factions:
		if f == null or not _stats.has(f.display_name):
			continue
		var s: Dictionary = _stats[f.display_name]
		# 资源收入（只累计正向跳变 = 采集交付 / 研究返还不存在）
		var dg: int = f.gold - int(s["prev_gold"])
		var dw: int = f.wood - int(s["prev_wood"])
		if dg > 0:
			s["gold_income"] = int(s["gold_income"]) + dg
		if dw > 0:
			s["wood_income"] = int(s["wood_income"]) + dw
		s["prev_gold"] = f.gold
		s["prev_wood"] = f.wood

		var idle_n: int = 0
		var stuck_n: int = 0
		var wounded_n: int = 0
		var army_n: int = 0
		var home: Vector3 = RtsWorld.base_center(f)
		for u in f.units:
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			if bool(u.call("is_idle_like")):
				idle_n += 1
			if int(u.get("_stuck_count")) >= 2:
				stuck_n += 1
			var d: UnitDef = u.def
			if d == null or RtsWorld.is_worker_def(d):
				continue
			if d.kind != RtsConst.Kind.UNIT:
				continue
			army_n += 1
			# 撤退代理：重伤事件（血量比例 <32%，与 SimpleAI.RETRAIN_HP 口径一致的重伤线）
			if d.max_hp > 0.0:
				var frac: float = u.hp / d.max_hp
				var uid: int = u.get_instance_id()
				var seen_frac: float = float(_wounded_seen.get(uid, 1.0))
				if frac <= 0.32 and seen_frac > 0.32:
					wounded_n += 1
				_wounded_seen[uid] = frac
		s["idle_unit_seconds"] = float(s["idle_unit_seconds"]) + step * float(idle_n)
		s["stuck_unit_seconds"] = float(s["stuck_unit_seconds"]) + step * float(stuck_n)
		s["stuck_max_units"] = maxi(int(s["stuck_max_units"]), stuck_n)
		s["_wounded_alive_units"] = wounded_n
		if wounded_n > 0:
			s["wounded_episodes"] = int(s["wounded_episodes"]) + wounded_n
		s["army_n_last"] = army_n
		s["idle_n_last"] = idle_n

		# 生产队列空档：有已完工产能建筑但队列全空，且钱够最便宜的兵。
		# ★ 2026-11-03 2C-2 口径修正：还要 **army < max_army**。
		#   旧口径把"已经满编所以不造"也算成空转（2C-1 复盘：改后 65% 采样点处于满编，
		#   89.2 s 里约 58 s 是"该停"的），修好之后余量会被误读成"还没修好"。
		#   旧口径数字保留在 prod_idle_seconds_legacy 里，同一跑里可做新旧对比。
		var prod_empty: bool = true
		var prod_any: bool = false
		for b in f.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive():
				continue
			if not b.has_method("queue_train"):
				continue
			if not bool(b.get("is_constructed")):
				continue
			prod_any = true
			if int(b.call("train_count")) > 0:
				prod_empty = false
				break
		var max_army_i: int = int(s.get("max_army", 0))
		var under_cap: bool = max_army_i <= 0 or army_n < max_army_i
		if prod_any and prod_empty and f.gold >= 130:
			s["prod_idle_seconds_legacy"] = float(s["prod_idle_seconds_legacy"]) + step
			if under_cap:
				s["prod_idle_seconds"] = float(s["prod_idle_seconds"]) + step
		# 资源断档：钱袋见底且队列空（episode 计数）
		var broke: bool = f.gold < 75 and f.wood < 20 and prod_empty
		if broke and not bool(s["_was_broke"]):
			s["broke_episodes"] = int(s["broke_episodes"]) + 1
		if broke:
			s["broke_seconds"] = float(s["broke_seconds"]) + step
		s["_was_broke"] = broke

		# 基地受损：**主口径**是 combat_hit 里"目标是建筑"的那一刀（见 _on_hit）——
		# 它发生在 unregister 之前，不会漏掉"最后一击"。这里的血量差值只做交叉校验，
		# 并留作兜底立案（脚本直接扣血这类不走 combat_hit 的路径）。
		var hp_sum: float = 0.0
		for b in f.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
				continue
			hp_sum += b.hp
		var prev_hp: float = float(s["prev_bldg_hp"])
		if prev_hp > 0.0 and hp_sum < prev_hp:
			s["base_damage_hp_sample"] = float(s["base_damage_hp_sample"]) + (prev_hp - hp_sum)
			if float(s["first_base_damage_t"]) < 0.0:
				s["first_base_damage_t"] = Game.elapsed
		s["prev_bldg_hp"] = hp_sum


## 2C-5：军队规模曲线 + 人口占用率（60 s 一行）。
## 口径：army = 存活战斗单位（不含农民，与 _sample_units 同一把尺）；
##       pop_used/pop_cap 直接读阵营，用来判断"军队是不是被人口顶死"。
func _sample_curve() -> void:
	for f in Game.factions:
		if f == null or not _stats.has(f.display_name):
			continue
		var s: Dictionary = _stats[f.display_name]
		var name: String = String(f.display_name)
		if not _curves.has(name):
			_curves[name] = []
		var arr: Array = _curves[name]
		var used: int = f.food_used()
		var cap: int = f.food_cap()
		arr.append({
			"t": snappedf(Game.elapsed, 0.1),
			"army": int(s.get("army_n_last", 0)),
			"pop_used": used, "pop_cap": cap,
			"pop_rate": snappedf(float(used) / float(maxi(cap, 1)), 0.01),
			"gold": f.gold, "wood": f.wood,
		})


func _on_hit(attacker: Node3D, target: Node3D, damage: float, _crit: bool) -> void:
	if attacker == null or target == null or not is_instance_valid(attacker) or not is_instance_valid(target):
		return
	var af = attacker.get("faction")
	var tf = target.get("faction")
	if af != null and _stats.has(String(af.display_name)):
		_stats[String(af.display_name)]["damage_dealt"] = float(_stats[String(af.display_name)]["damage_dealt"]) + damage
	if tf != null and _stats.has(String(tf.display_name)):
		_stats[String(tf.display_name)]["damage_taken"] = float(_stats[String(tf.display_name)]["damage_taken"]) + damage
	# 建筑挨打 = 基地受损。这里立案最准：伤害结算时建筑还活着（还没 unregister），
	# 而 0.25s 一次的血量采样会漏掉"这一刀把人打死"的终末伤害。
	if target is RtsBuilding and tf != null and _stats.has(String(tf.display_name)):
		var bs: Dictionary = _stats[String(tf.display_name)]
		bs["base_damage_taken"] = float(bs["base_damage_taken"]) + damage
		if float(bs["first_base_damage_t"]) < 0.0:
			bs["first_base_damage_t"] = Game.elapsed


func _on_death(u: Node3D) -> void:
	if u == null or not is_instance_valid(u):
		return
	var f = u.get("faction")
	if f == null or not _stats.has(String(f.display_name)):
		return
	var s: Dictionary = _stats[String(f.display_name)]
	if u is RtsBuilding:
		s["buildings_lost"] = int(s["buildings_lost"]) + 1
		# 兜底：建筑被打死却没在 combat_hit 里立案（理论上不该发生）→ 用死亡时刻补一条，
		# 并在报告里单独计数，免得"没立案"被误读成"没挨打"。
		if float(s["first_base_damage_t"]) < 0.0:
			s["first_base_damage_t"] = Game.elapsed
			s["base_damage_by_death"] = int(s.get("base_damage_by_death", 0)) + 1
	else:
		s["units_lost"] = int(s["units_lost"]) + 1


# ===========================================================================
# 情况文本（引擎现场生成，禁止人工润色）
# ===========================================================================

func _situation(f_or_null, tag: String, extra: Dictionary) -> Dictionary:
	var f: RtsFaction = f_or_null
	var out := {
		"t": snappedf(Game.elapsed, 0.01),
		"phase": Game.phase,
		"tag": tag,
	}
	if f == null:
		return out
	var s: Dictionary = _stats.get(f.display_name, {})
	var army: int = int(s.get("army_n_last", 0))
	var workers := 0
	for u in f.units:
		if u != null and is_instance_valid(u) and u.is_alive() and RtsWorld.is_worker_def(u.def):
			workers += 1
	out["faction"] = f.display_name
	out["team"] = f.team
	out["own_summary"] = {
		"units": f.count_units(), "army": army, "workers": workers,
		"buildings": f.count_buildings(),
		"gold": f.gold, "wood": f.wood,
		"food_used": f.food_used(), "food_cap": f.food_cap(),
	}
	# 指标与姿态：直接读 AI 脑的公开字段（本阵营的脑）
	for b in _brains:
		if b["faction"] == f:
			var n = b["node"]
			if n != null and is_instance_valid(n):
				var m: Dictionary = n.get("metrics")
				out["metrics"] = {
					"army_count": m.get("army_count", -1),
					"army_ratio": m.get("army_ratio", -1),
					"army_food": m.get("army_food", -1),
					"my_army_value": m.get("my_army_value", -1),
					"workers": m.get("workers", -1),
					"idle_workers": m.get("idle_workers", -1),
					"base_threat": m.get("base_threat", -1),
					"gold_float": m.get("gold_float", -1),
					"enemy_static_defense": m.get("enemy_static_defense", -1),
				}
				var p: Dictionary = n.get("posture")
				out["posture"] = {
					"plan_id": p.get("plan_id", ""), "stance": p.get("stance", ""),
					"aggression": p.get("aggression", -1),
					"allow_attack": p.get("allow_attack", false),
					"attack_ratio_needed": p.get("attack_ratio_needed", -1),
				}
			break
	# 情报口径：AI 直接读 Game.factions 全量 —— 这里如实标注 omniscient
	var known: Array = []
	for foe in Game.enemies_of(f):
		if foe == null:
			continue
		known.append({
			"name": foe.display_name, "team": foe.team,
			"units": foe.count_units(), "buildings": foe.count_buildings(),
			"gold": foe.gold, "wood": foe.wood,
		})
	out["known_enemies"] = {"omniscient": true, "factions": known}
	out["recent_decision"] = _recent.get(f.display_name, {"name": "无"})
	out["task_state"] = "无任务层（定时器+许可，见诊断 4.2）"
	if not extra.is_empty():
		for k in extra.keys():
			out[k] = extra[k]
	return out


func _dump_situations(is_event: bool, extra: Dictionary = {}, f_override = null) -> void:
	if _file_sit.is_empty():
		return
	var exists := FileAccess.file_exists(_file_sit)
	var fa := FileAccess.open(_file_sit, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if fa == null:
		return
	fa.seek_end()
	var targets: Array = []
	if f_override != null:
		targets.append(f_override)
	else:
		for f in Game.factions:
			if f != null:
				targets.append(f)
	for f in targets:
		var rec: Dictionary = _situation(f, "event" if is_event else "periodic", extra)
		fa.store_line(JSON.stringify(rec))
	fa.close()


# ===========================================================================
# 事件 / 签名 / 收尾
# ===========================================================================

func _event(fac: String, name: String, detail: Dictionary, decision: String) -> void:
	var e := {"t": snappedf(Game.elapsed, 0.01), "faction": fac, "event": name}
	for k in detail.keys():
		e[k] = detail[k]
	_events.append(e)
	_recent[fac] = {"name": name, "t": Game.elapsed, "detail": detail}
	# 关键决策前后各一条情况文本：决策本身这条就是"后"，把前一条靠周期快照覆盖
	if name == "wave_issued" or name == "defense_triggered" or name == "plan_switch":
		var f = null
		for ff in Game.factions:
			if ff != null and String(ff.display_name) == fac:
				f = ff
				break
		_dump_situations(true, {"decision": decision}, f)


func _sig_sample() -> void:
	var idx: int = int(Game.elapsed / 30.0)
	if _sig_lines.size() == idx:
		var row := "%d" % idx
		for f in Game.factions:
			if f == null or not _stats.has(f.display_name):
				continue
			var s: Dictionary = _stats[f.display_name]
			row += "|%d,%d,%d,%d" % [f.gold, f.wood, int(s.get("army_n_last", 0)), int(s.get("wave_count", 0))]
		_sig_lines.append(row)


func _abs(p: String) -> String:
	if p.begins_with("res://"):
		return ProjectSettings.globalize_path(p)
	return p


## 一组波次记录按某个字段计数（判定/目标/建议分布）
func _dist(rows: Array, key: String) -> Dictionary:
	var out: Dictionary = {}
	for r in rows:
		if not (r is Dictionary):
			continue
		var k: String = String((r as Dictionary).get(key, ""))
		if k.is_empty():
			k = "(空)"
		out[k] = int(out.get(k, 0)) + 1
	return out


func _finish(reason: String) -> void:
	if _done:
		return
	_done = true
	var wall_sec: float = float(Time.get_ticks_usec() / 1000 - _t0_msec) / 1000.0
	_dump_situations(false)   # 收尾再补一条周期快照

	# --- 防守响应时间 ---
	# 语义（2026-11-02 修）：从**建筑第一次真的掉血**到**此后第一次回防命令**的间隔。
	#   · 掉血后确有回防        → ≥0 的秒数；
	#   · 打之前就已经在回防    → 0，并标 defense_preemptive（威胁圈先行，这是好行为）；
	#   · 全程没掉血 / 没回防   → -1（不可测，不是 0）。
	# 旧口径是 first_defense_t - first_base_damage_t：只要 AI 先回防就必出负数 → 永远 -1。
	for f in Game.factions:
		if f == null or not _stats.has(f.display_name):
			continue
		var s: Dictionary = _stats[f.display_name]
		var fbd: float = float(s.get("first_base_damage_t", -1))
		var fda: float = float(s.get("first_defense_after_damage_t", -1))
		var resp: float = -1.0
		if fbd >= 0.0:
			if fda >= 0.0:
				resp = maxf(fda - fbd, 0.0)
			elif int(s.get("defense_count", 0)) > 0:
				resp = 0.0
				s["defense_preemptive"] = true
		s["defense_response_t"] = resp

	# 内部记账键不进报告（_开头 / prev_ 开头）
	var clean: Dictionary = {}
	for fname in _stats.keys():
		var s: Dictionary = _stats[fname]
		var c: Dictionary = {}
		for k in s.keys():
			if String(k).begins_with("_") or String(k).begins_with("prev_"):
				continue
			c[k] = s[k]
		clean[fname] = c

	# --- 波次记录表 / 战略状态机（2C-2）---
	# 只读 AI 脑上的公开字段，原样落盘；不在这里重算判定（判定由 AI 自己算）。
	# members/hits 是运行期索引（实例 id），落盘前剔掉，免得报告里全是内存地址。
	var wave_records: Dictionary = {}
	# 2C-5 P1-4：修理统计（faction 名 → {issued, buildings}）
	var repairs: Dictionary = {}
	for b in _brains:
		var n = b["node"]
		if n == null or not is_instance_valid(n):
			continue
		var fname2: String = String(b["faction"].display_name)
		var rows: Array = []
		var raw = n.get("wave_log")
		if raw is Array:
			for r in raw:
				if not (r is Dictionary):
					continue
				var c: Dictionary = (r as Dictionary).duplicate(true)
				c.erase("members")
				c.erase("hits")
				for k in c.keys():
					if String(k).begins_with("_"):
						c.erase(k)
				if c.has("target"):
					c["target"] = str(c["target"])
				if c.has("goal_target_pos"):
					c["goal_target_pos"] = str(c["goal_target_pos"])
				rows.append(c)
		wave_records[fname2] = {
			"state": String(n.get("strat_state")),
			"stats": n.get("strat_stats"),
			"timeline": n.get("strat_log"),
			"verdicts": _dist(rows, "verdict"),
			"goals": _dist(rows, "goal_type"),
			"advice": _dist(rows, "comp_advice"),
			"waves": rows,
		}
		# 2C-5 P1-4：修理统计（谁修的、修了几次）
		repairs[fname2] = n.get("repair_stats")

	# --- 2C-5 P1-5 达成归属：达成条数里"本波参与"的比例 ---
	# 口径：goal_last_hit = 目标临死前最后一刀的攻击者属于本波；
	#       goal_damage_ratio = 本波对目标的累计伤害 ÷ 目标总生命（-1 = 无目标/未记录）。
	var attribution := {
		"achieved": 0, "last_hit": 0, "zero_damage": 0,
		"ratio_sum": 0.0, "ratio_n": 0, "ratio_mean": -1.0, "by_faction": {},
	}
	for fname3 in wave_records.keys():
		var rows3: Array = wave_records[fname3].get("waves", [])
		var fa := {"achieved": 0, "last_hit": 0, "zero_damage": 0,
			"ratio_sum": 0.0, "ratio_n": 0, "ratio_mean": -1.0}
		for r in rows3:
			if not bool((r as Dictionary).get("goal_achieved", false)):
				continue
			fa["achieved"] = int(fa["achieved"]) + 1
			attribution["achieved"] = int(attribution["achieved"]) + 1
			if bool((r as Dictionary).get("goal_last_hit", false)):
				fa["last_hit"] = int(fa["last_hit"]) + 1
				attribution["last_hit"] = int(attribution["last_hit"]) + 1
			if float((r as Dictionary).get("goal_damage", 0.0)) <= 0.0:
				fa["zero_damage"] = int(fa["zero_damage"]) + 1
				attribution["zero_damage"] = int(attribution["zero_damage"]) + 1
			var gr: float = float((r as Dictionary).get("goal_damage_ratio", -1.0))
			if gr >= 0.0:
				fa["ratio_sum"] = float(fa["ratio_sum"]) + gr
				fa["ratio_n"] = int(fa["ratio_n"]) + 1
				attribution["ratio_sum"] = float(attribution["ratio_sum"]) + gr
				attribution["ratio_n"] = int(attribution["ratio_n"]) + 1
		if int(fa["ratio_n"]) > 0:
			fa["ratio_mean"] = snappedf(float(fa["ratio_sum"]) / float(fa["ratio_n"]), 0.01)
		attribution["by_faction"][fname3] = fa
	if int(attribution["ratio_n"]) > 0:
		attribution["ratio_mean"] = snappedf(
			float(attribution["ratio_sum"]) / float(attribution["ratio_n"]), 0.01)

	var report := {
		"seed": seed_val, "minutes": minutes, "speed": speed, "map": map_path,
		"difficulty": Cfg.game.default_difficulty,
		"ratio_mode": AIW.mode(), "ratio_mode_desc": AIW.describe(),
		"verdict_mode": AIV.mode(), "verdict_desc": AIV.describe(),
		"verdict_base_sec": AIV.base_sec(), "verdict_coef": AIV.output_coef(),
		"verdict_time_limit": AIV.time_limit(),
		"damage_theory_mode": AIV.damage_theory_mode(),
		"output_theory_mode": AIV.output_theory_mode(),
		"recent_attack_window": AIV.recent_attack_window(),
		"repair_hp_threshold": AIV.repair_hp_threshold(),
		"repair_hp_deficit": AIV.repair_hp_deficit(),
		"elapsed_game_s": snappedf(Game.elapsed, 0.01),
		"wall_clock_s": snappedf(wall_sec, 0.1),
		"end_reason": reason,
		"phase": Game.phase,
		"fog": "玩家侧启用（AI 不受迷雾限制，全图读取）",
		"P1": "不可采：无任务层与情报层（见诊断 4.2）",
		"factions": clean,
		"wave_records": wave_records,
		"army_curve": _curves,
		"repairs": repairs,
		"goal_attribution": attribution,
		"events": _events,
		"situations_file": _file_sit if not _file_sit.is_empty() else "未启用",
	}
	DirAccess.make_dir_recursive_absolute(_abs("res://_qa"))
	_file_bench = _abs("res://_qa/bench_%s_%s_%d%s.json"
		% [AIW.mode(), AIV.mode(), seed_val, tag])
	var fa := FileAccess.open(_file_bench, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(report, "  "))
		fa.close()
	var summary := {
		"seed": seed_val, "mode": AIW.mode(), "verdict_mode": AIV.mode(),
		"base_sec": AIV.base_sec(), "end": reason, "elapsed": snappedf(Game.elapsed, 0.1),
		"wall_s": snappedf(wall_sec, 0.1),
	}
	for f in Game.factions:
		if f == null or not _stats.has(f.display_name):
			continue
		var s: Dictionary = _stats[f.display_name]
		var wr: Dictionary = wave_records.get(f.display_name, {})
		# ★ 别写 `(x or {}).get(...)` —— GDScript 的 `or` 返回 **bool**，
		#   不是"短路取操作数"。2C-5 C5 就是栽在这上面：`repairs.get(...) or {}` 得到 false，
		#   再 `as Dictionary` / `.get()` 当场报错，_finish 中断 → 进程不退出（实测挂满墙钟）。
		#   正确写法是显式 `is Dictionary` 判一次。
		var rraw = repairs.get(String(f.display_name), null)
		var rr: Dictionary = rraw if rraw is Dictionary else {}
		var wstats = wr.get("stats", null)
		var wst: Dictionary = wstats if wstats is Dictionary else {}
		summary[f.display_name] = {
			"金收入": int(s["gold_income"]), "木收入": int(s["wood_income"]),
			"波次": int(s["wave_count"]), "首波": float(s["first_wave_t"]),
			"拒击": int(s["attack_rejected"]), "出击许可": int(s.get("allow_attack_on", 0)),
			"许可开着": int(s.get("allow_on_think", 0)),
			"门槛": "%.2f~%.2f" % [float(s.get("need_min", 0.0)), float(s.get("need_max", 0.0))],
			"空转新": snappedf(float(s["prod_idle_seconds"]), 0.1),
			"空转旧": snappedf(float(s["prod_idle_seconds_legacy"]), 0.1),
			"兵力": int(s.get("army_n_last", 0)),
			"回防": int(s["defense_count"]),
			"损失": "%d兵/%d建" % [int(s["units_lost"]), int(s["buildings_lost"])],
			"闲时": snappedf(float(s["idle_unit_seconds"]), 1.0),
			"卡死峰值": int(s["stuck_max_units"]),
			"断档": int(s["broke_episodes"]),
			"重伤": int(s["wounded_episodes"]),
			"基地掉血": snappedf(float(s["base_damage_taken"]), 0.1),
			"首次受击": snappedf(float(s["first_base_damage_t"]), 0.1),
			"防守响应": float(s.get("defense_response_t", -1)),
			"预判回防": bool(s.get("defense_preemptive", false)),
			"判定": wr.get("verdicts", {}),
			"目标": wr.get("goals", {}),
			"建议": wr.get("advice", {}),
			"修理": int((rr as Dictionary).get("issued", 0)),
			"军队目标": "%d→%d" % [
				int(wst.get("army_target_first", -1)),
				int(wst.get("army_target", -1))],
		}
	# 2C-5：达成归属摘要（达成条数里"本波参与"的比例）+ 曲线峰值
	summary["达成归属"] = "%d/%d 条达成是本波最后一击（伤害占比均值 %.2f，0 伤害 %d 条）" % [
		int(attribution["last_hit"]), int(attribution["achieved"]),
		float(attribution["ratio_mean"]), int(attribution["zero_damage"])]
	var peaks := {}
	for fname in _curves.keys():
		var arr2: Array = _curves[fname]
		var max_army: int = 0
		var max_rate: float = 0.0
		var last_army: int = 0
		for row in arr2:
			max_army = maxi(max_army, int(row.get("army", 0)))
			max_rate = maxf(max_rate, float(row.get("pop_rate", 0.0)))
			last_army = int(row.get("army", 0))
		peaks[fname] = {"峰值兵力": max_army, "末兵力": last_army,
			"峰值人口率": snappedf(max_rate, 0.01)}
	summary["曲线"] = peaks
	# 2C-4 §3.3 "好"比例护栏（只告警，不判失败、不阻断）
	var good_n: int = 0
	var total_n: int = 0
	for fname in wave_records.keys():
		var rows: Array = wave_records[fname].get("waves", [])
		for r in rows:
			total_n += 1
			if String(r.get("verdict", "")) == "好":
				good_n += 1
	if _bench_model.good_ratio_warning(good_n, total_n):
		print("[护栏 ⚠] 判定=好 的比例 %d/%d 超过 50%% —— 只告警，不判失败（任务书 §3.3）"
			% [good_n, total_n])
		summary["好比例告警"] = "%d/%d > 50%%" % [good_n, total_n]
	print("AI-BENCH %s" % JSON.stringify(summary))
	# 确定性签名：同 seed 复跑必须一致（外部脚本比对）
	var sig: String = ""
	for line in _sig_lines:
		sig += line + ";"
	sig += "END|%d" % Game.phase
	print("AI-BENCH-SIGNATURE %s" % sig.sha256_text())
	print("[AI基准] 报告 → %s" % _file_bench)
	get_tree().quit(0)
