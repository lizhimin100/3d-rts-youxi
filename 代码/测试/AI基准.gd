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
## 2C-9：并发修理探针（`--qa-repair-probe`），定点在第 N 个 AI 脑上跑一次
var qa_repair_probe: bool = false
var qa_repair_at: float = 90.0
var _qa_repair_done: bool = false


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
		elif a.begins_with("--qa-repair-probe"):
			qa_repair_probe = true
			if a.begins_with("--qa-repair-probe="):
				qa_repair_at = float(a.substr(String("--qa-repair-probe=").length()))
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
	# 2C-9：并发修理探针（定点跑一次，结果打一行 PROBE-2C9-REPAIR）
	if qa_repair_probe and not _qa_repair_done and Game.elapsed >= qa_repair_at:
		_qa_repair_done = true
		_run_repair_probe()
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
		# 2C-8 P2：从**引擎侧**独立采样"同时建造/同时修理"（不读 AI 自报。
		# 自报只说明 AI 认为自己在干什么；这里按 order 数人头，才能验证上限有没有破）。
		"max_concurrent_build": 0, "max_concurrent_repairs": 0,
		"concurrent_repair_samples": 0, "build_over_limit_samples": 0,
		"builder_slots_max": 0, "builder_slots_last": 0,
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
		# 2C-8：用工并发（引擎侧口径 = order + _repair_target，不看 AI 的计数）
		var workers_n: int = 0
		var build_n: int = 0
		var repair_targets: Dictionary = {}
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
				if d != null and RtsWorld.is_worker_def(d):
					workers_n += 1
					var o: int = int(u.order)
					if o == RtsConst.Order.BUILD:
						build_n += 1
					elif o == RtsConst.Order.REPAIR:
						var rt = u.get("_repair_target")
						if rt != null and is_instance_valid(rt):
							repair_targets[rt.get_instance_id()] = true
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
		# 2C-8：同时建造/修理（引擎侧独立口径）+ 上限校验
		var slots_want: int = int(_bench_model.builder_count_for(workers_n))
		var build_limit: int = int(_bench_model.builder_build_limit(slots_want))
		s["builder_slots_last"] = slots_want
		s["builder_slots_max"] = maxi(int(s["builder_slots_max"]), slots_want)
		s["max_concurrent_build"] = maxi(int(s["max_concurrent_build"]), build_n)
		if build_n > build_limit:
			s["build_over_limit_samples"] = int(s["build_over_limit_samples"]) + 1
		var n_rep: int = repair_targets.size()
		s["max_concurrent_repairs"] = maxi(int(s["max_concurrent_repairs"]), n_rep)
		if n_rep >= 2:
			s["concurrent_repair_samples"] = int(s["concurrent_repair_samples"]) + 1

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
## 2C-7：再加 "army_target" —— **本 tick 的军队目标**（AI 脑上的 army_target_now）。
##       有了它才能画"目标 vs 实际 vs 人口上限"三条线，而不是只看实际值猜目标。
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
		var brain: Node = _brain_node(f)
		var at: int = -1
		if brain != null:
			at = int(brain.get("army_target_now"))
		# 2C-6：农场 / 出兵建筑座数（曲线）
		#   出兵建筑 = trains 里有 food_cost>0 的兵（大本营只训农民 → 不算兵营）
		#   农场 = 提供人口且不是交汇点、不产兵（排除大本营/伐木场/车坊）
		var farms: int = 0
		var prods: int = 0
		for b in f.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
				continue
			var rb: RtsBuilding = b as RtsBuilding
			if rb != null and not rb.is_constructed:
				continue
			var is_prod: bool = false
			for tid in b.def.trains:
				var ud: UnitDef = Cfg.unit(tid)
				if ud != null and ud.food_cost > 0:
					is_prod = true
					break
			if is_prod:
				prods += 1
			elif int(b.def.food_provided) > 0 and not b.def.is_dropoff:
				farms += 1
		# 2C-8：工位数 / 采金 / 采木 / 工位占用（报告要画"配比曲线"）
		var workers_n: int = 0
		var gold_w: int = 0
		var wood_w: int = 0
		var busy_w: int = 0
		var idle_w: int = 0
		for u in f.units:
			if u == null or not is_instance_valid(u) or not u.is_alive() or u.def == null:
				continue
			if not RtsWorld.is_worker_def(u.def):
				continue
			workers_n += 1
			var o: int = int(u.order)
			if o == RtsConst.Order.BUILD or o == RtsConst.Order.REPAIR:
				busy_w += 1
			elif o == RtsConst.Order.GATHER \
					and int(u.call("gather_kind")) == RtsConst.Harvest.GOLD:
				gold_w += 1
			elif o == RtsConst.Order.GATHER \
					and int(u.call("gather_kind")) == RtsConst.Harvest.WOOD:
				wood_w += 1
			else:
				idle_w += 1
		var slots_target: int = int(_bench_model.builder_count_for(workers_n))
		var slots_actual: int = 0
		if brain != null:
			var bu = brain.get("_builder_uids")
			if bu is Array:
				slots_actual = (bu as Array).size()
		arr.append({
			"t": snappedf(Game.elapsed, 0.1),
			"army": int(s.get("army_n_last", 0)),
			"army_target": at,
			"pop_used": used, "pop_cap": cap,
			"pop_rate": snappedf(float(used) / float(maxi(cap, 1)), 0.01),
			"farms": farms, "producers": prods,
			"gold": f.gold, "wood": f.wood,
			"workers": workers_n, "builders": slots_target, "builders_actual": slots_actual,
			"gather_gold": gold_w, "gather_wood": wood_w, "builder_busy": busy_w,
			"idle_workers": idle_w,
		})


## 某阵营的 AI 脑（没有就 null）。曲线要读"本 tick 的军队目标"只能从脑上拿。
func _brain_node(f) -> Node:
	for b in _brains:
		if b["faction"] == f:
			var n = b["node"]
			if n != null and is_instance_valid(n):
				return n
	return null


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

## 2C-9：并发修理探针（`--qa-repair-probe[=秒]`）。
## 只在第一个 AI 脑上跑一次；断言写在 `简单AI.qa_repair_probe()` 里，这里只负责打印。
func _run_repair_probe() -> void:
	for b in _brains:
		var n = b["node"]
		if n == null or not is_instance_valid(n):
			continue
		if not n.has_method("qa_repair_probe"):
			continue
		var r = n.call("qa_repair_probe")
		print("PROBE-2C9-REPAIR %s" % JSON.stringify(r))
		return
	print("PROBE-2C9-REPAIR %s" % JSON.stringify({"ok": false, "why": "找不到带探针的 AI 脑"}))


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


## 2C-8：把一个计数字典压成"非零项"的短串（summary 用；零项不占篇幅）
func _dict_brief(d) -> String:
	if not (d is Dictionary):
		return "-"
	var parts: Array = []
	for k in (d as Dictionary).keys():
		if String(k).begins_with("_"):
			continue
		var v: int = int((d as Dictionary)[k])
		if v > 0:
			parts.append("%s%d" % [String(k), v])
	return "/".join(parts) if not parts.is_empty() else "-"


# --- 2C-9：仲裁账本的四个摘要（都只读 dept_stats，不重算）---

func _dept_exec_rate(d) -> String:
	if not (d is Dictionary):
		return "-（dept=off）"
	var total: int = int((d as Dictionary).get("demands", 0))
	var done: int = int((d as Dictionary).get("executed", 0))
	if total <= 0:
		return "0/0"
	return "%d/%d=%.1f%%" % [done, total, 100.0 * float(done) / float(total)]


func _dept_reject(d) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var rj = (d as Dictionary).get("reject_by_reason", {})
	return rj if rj is Dictionary else {}


func _dept_train_build(d) -> String:
	if not (d is Dictionary):
		return "-（dept=off）"
	return "训练%d/建造%d（同周期竞争%d 次）" % [
		int((d as Dictionary).get("win_train", 0)),
		int((d as Dictionary).get("win_build", 0)),
		int((d as Dictionary).get("compete_train_build", 0))]


func _dept_push_patrol(d) -> String:
	if not (d is Dictionary):
		return "-（dept=off）"
	return "出击%d(%d兵)/巡逻%d(%d兵)" % [
		int((d as Dictionary).get("win_push", 0)),
		int((d as Dictionary).get("lock_wave_held", 0)),
		int((d as Dictionary).get("win_patrol", 0)),
		int((d as Dictionary).get("lock_patrol_held", 0))]


func _dept_locks(d) -> String:
	if not (d is Dictionary):
		return "-（dept=off）"
	return "峰%d/显式解锁%d/超时%d/泄漏%d" % [
		int((d as Dictionary).get("lock_held_max", 0)),
		int((d as Dictionary).get("lock_wave_released", 0)),
		int((d as Dictionary).get("lock_wave_timeout", 0)),
		maxi(int((d as Dictionary).get("lock_wave_held", 0))
			- int((d as Dictionary).get("lock_wave_released", 0))
			- int((d as Dictionary).get("lock_wave_timeout", 0)), 0)]


func _finish(reason: String) -> void:
	if _done:
		return
	_done = true
	var wall_sec: float = float(Time.get_ticks_usec() / 1000 - _t0_msec) / 1000.0
	_dump_situations(false)   # 收尾再补一条周期快照
	# 2C-12 §3.4：局末清空承诺表（生命周期管理最后一步：不允许跨局残留）。
	# 先记「清理前残留」，再清空；`promise_left_at_end` 就是清理前的条数。
	var _m_promise_left: int = 0
	for _b in _brains:
		var _n = _b["node"]
		if _n != null and is_instance_valid(_n) and _n.has_method("promise_dispose"):
			_m_promise_left += int(_n.call("promise_dispose"))
	# 2C-13 §4.4：局末清空目标表。清理前把剩余预留落盘 → `goal_reserve_left_at_end`，
	# 清理后必须为 0（生命周期管理最后一步：不允许跨局残留）。
	var _m_goal_left: Dictionary = {"金币": 0, "木材": 0}
	for _b2 in _brains:
		var _n2 = _b2["node"]
		if _n2 != null and is_instance_valid(_n2) and _n2.has_method("goal_dispose"):
			var _left = _n2.call("goal_dispose")
			if _left is Dictionary:
				_m_goal_left["金币"] = int(_m_goal_left["金币"]) + int((_left as Dictionary).get("金币", 0))
				_m_goal_left["木材"] = int(_m_goal_left["木材"]) + int((_left as Dictionary).get("木材", 0))

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
	# 2C-6：建造下单计数（faction 名 → {id: 次数}）
	var build_stats: Dictionary = {}
	# 2C-7 P2：投资占比（faction 名 → {farm_gold/army_gold/samples/over_invest_60s}）
	var invests: Dictionary = {}
	# 2C-8 P2：用工 / 农场归因 / 训练阻塞
	var labors: Dictionary = {}
	var farm_fails: Dictionary = {}
	var train_blocks: Dictionary = {}
	# 2C-9：三条线部门化的仲裁统计（faction 名 → dept_stats）
	var depts: Dictionary = {}
	# 2C-9 P1：判定表分布（faction 名 → {判据1..4: 五档计数}）
	var judge_dist: Dictionary = {}
	var judge_rows: Array = []
	# 2C-10：90% 人口压力响应（faction 名 → pop90 观测字典）
	var pop90s: Dictionary = {}
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
				# 2C-9：四样判据各自的档位（同一批冻结阈值，不重算判定）
				c["判据"] = _bench_model.judge_bins(c)
				# 2C-10 B：每波四样判据的**原始输入值 + 档位边界 + 边界距离**（只诊断）
				c["判据诊断"] = _bench_model.judge_diag(c)
				c["零伤害"] = float(c.get("damage_out", 0.0)) <= 0.0
				for k in c.keys():
					if String(k).begins_with("_"):
						c.erase(k)
				if c.has("target"):
					c["target"] = str(c["target"])
				if c.has("goal_target_pos"):
					c["goal_target_pos"] = str(c["goal_target_pos"])
				rows.append(c)
				judge_rows.append(c)
		wave_records[fname2] = {
			"state": String(n.get("strat_state")),
			"stats": n.get("strat_stats"),
			"timeline": n.get("strat_log"),
			"verdicts": _dist(rows, "verdict"),
			"goals": _dist(rows, "goal_type"),
			"advice": _dist(rows, "comp_advice"),
			"waves": rows,
		}
		judge_dist[fname2] = {
			"总波次": rows.size(),
			"判据1": _bench_model.judge_bin_counts(rows, "判据1"),
			"判据2": _bench_model.judge_bin_counts(rows, "判据2"),
			"判据3": _bench_model.judge_bin_counts(rows, "判据3"),
			"判据4": _bench_model.judge_bin_counts(rows, "判据4"),
		}
		# 2C-5 P1-4：修理统计（谁修的、修了几次）
		repairs[fname2] = n.get("repair_stats")
		build_stats[fname2] = n.get("build_stats")
		# 2C-7 P2：投资占比（农场 vs 军队）
		invests[fname2] = n.get("invest_stats")
		# 2C-8 P2：用工统计 / 农场失败归因 / 训练阻塞归因
		labors[fname2] = n.get("labor_stats")
		farm_fails[fname2] = n.get("farm_fail_stats")
		train_blocks[fname2] = n.get("train_stats")
		# 2C-9：仲裁账本（执行率 / 驳回原因 / 胜出次数 / 兵力锁）
		depts[fname2] = n.get("dept_stats")
		# 2C-10 §7.2：每阵营的 POP90 观测
		pop90s[fname2] = n.get("pop90")

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

	# --- 2C-10 §7.2：全局 POP90 汇总（每局落盘一行，失败明细带驳回/金/工位）---
	# 2C-12 §5：**双口径** —— 成功 = 已有工地 + 20 s 内新开工，两个来源分开记，
	#   报告里两个成功率都列；「新开工成功率」是主判据，「修正口径」只作对照。
	var pop90_all := {"触发": 0, "成功": 0, "失败": 0, "失败明细": [],
		"峰值": 0.0, "农场开工": 0, "触发时刻": [],
		"已有工地": 0, "新开工成功": 0}
	for pname in pop90s.keys():
		var pv = pop90s[pname]
		if not (pv is Dictionary):
			continue
		var pd: Dictionary = pv as Dictionary
		pop90_all["触发"] = int(pop90_all["触发"]) + int(pd.get("触发", 0))
		pop90_all["成功"] = int(pop90_all["成功"]) + int(pd.get("成功", 0))
		pop90_all["失败"] = int(pop90_all["失败"]) + int(pd.get("失败", 0))
		pop90_all["农场开工"] = int(pop90_all["农场开工"]) + int(pd.get("农场开工", 0))
		pop90_all["已有工地"] = int(pop90_all["已有工地"]) + int(pd.get("已有工地", 0))
		pop90_all["新开工成功"] = int(pop90_all["新开工成功"]) + int(pd.get("新开工成功", 0))
		pop90_all["峰值"] = maxf(float(pop90_all["峰值"]), float(pd.get("峰值", 0.0)))
		for x in (pd.get("失败明细", []) as Array):
			(pop90_all["失败明细"] as Array).append(x)
		for x in (pd.get("触发时刻", []) as Array):
			(pop90_all["触发时刻"] as Array).append(x)
	pop90_all["峰值"] = snappedf(float(pop90_all["峰值"]), 0.001)
	var p90_n: float = maxf(float(pop90_all["触发"]), 1.0)
	pop90_all["修正口径成功率"] = snappedf(float(pop90_all["成功"]) / p90_n, 0.0001)
	pop90_all["新开工成功率"] = snappedf(float(pop90_all["新开工成功"]) / p90_n, 0.0001)
	pop90_all["口径拆分自洽"] = (int(pop90_all["成功"])
			== int(pop90_all["已有工地"]) + int(pop90_all["新开工成功"]))

	# --- 2C-10 B：每判据"档位落点分布 + 边界距离"（只诊断，不改窗口/系数/分母）---
	var diag_all: Dictionary = {}
	for dkey in ["判据1", "判据2", "判据3", "判据4"]:
		var cnt: Dictionary = {}
		var dsum: float = 0.0
		var dn: int = 0
		var dnear: int = 0
		var dmin: float = 1e9
		var dmax: float = 0.0
		var edges: Variant = null
		for rr in judge_rows:
			var dgv = (rr as Dictionary).get("判据诊断", null)
			if not (dgv is Dictionary):
				continue
			var one = (dgv as Dictionary).get(dkey, null)
			if not (one is Dictionary):
				continue
			var od: Dictionary = one as Dictionary
			if edges == null:
				edges = od.get("边界", [])
			var dist: float = float(od.get("边界距离", 0.0))
			dsum += dist
			dn += 1
			dmin = minf(dmin, dist)
			dmax = maxf(dmax, dist)
			if dist <= 0.05:
				dnear += 1
			var bin: String = String(od.get("档", "?"))
			cnt[bin] = int(cnt.get(bin, 0)) + 1
		diag_all[dkey] = {
			"档位": cnt, "边界": edges,
			"边界距离": {"均值": snappedf(dsum / maxf(float(dn), 1.0), 0.001),
				"最小": snappedf(dmin if dn > 0 else 0.0, 0.001),
				"最大": snappedf(dmax, 0.001),
				"近边界0.05占比": snappedf(float(dnear) / maxf(float(dn), 1.0), 0.001)},
		}

	# ------------------------------------------------------------------
	# 2C-11 P2 监控（不判硬，只落盘）：储备不足 / 并发上限驳回率、
	# 建造停滞恢复率、同时做事数实际分布、金币≥G(t)周期占比、紧急命中。
	# 驳回率分母统一用「总诉求数」，金币≥G(t)周期占比分母用「总周期数」。
	# ★ 2C-15：整块只统计 AI 阵营（"玩家" 不进分子/分母，口径与达成率 AI-only 一致）；
	#   dept=off 无仲裁周期时比率置 N/A，不许 0/max(0,1) 报假 0。
	# ------------------------------------------------------------------
	var m_saving: int = 0
	var m_concur: int = 0
	var m_demands: int = 0
	var m_cycles: int = 0
	var m_sufficient: int = 0
	var m_stall: int = 0
	var m_recover: int = 0
	var m_site_already: int = 0
	var m_exec_dist: Dictionary = {}
	var m_urgent: Dictionary = {}
	for fname_m in depts.keys():
		# ★ 2C-15：玩家（副官）阵营不进任何分子/分母，口径与 ai_only() 的 "玩家" not in k 一致。
		if "玩家" in String(fname_m):
			continue
		var ds_m: Dictionary = depts[fname_m] if depts[fname_m] is Dictionary else {}
		var rj_m: Dictionary = ds_m.get("reject_by_reason", {})
		m_saving += int(rj_m.get("储备不足", 0))
		m_concur += int(rj_m.get("并发上限", 0))
		m_demands += int(ds_m.get("demands", 0))
		m_cycles += int(ds_m.get("cycles", 0))
		m_sufficient += int(ds_m.get("gold_ge_g_cycles", 0))
		m_stall += int(ds_m.get("site_stall_detected", 0))
		m_recover += int(ds_m.get("site_recovery_issued", 0))
		m_site_already += int(ds_m.get("pop90_site_already", 0))
		var ed_m: Dictionary = ds_m.get("exec_per_cycle", {})
		for k_m in ed_m.keys():
			m_exec_dist[k_m] = int(m_exec_dist.get(k_m, 0)) + int(ed_m[k_m])
		var uh_m: Dictionary = ds_m.get("saving_urgent_hits", {})
		for k_u in uh_m.keys():
			m_urgent[k_u] = int(m_urgent.get(k_u, 0)) + int(uh_m[k_u])
	var m_den: float = maxf(float(m_demands), 1.0)
	var m_save_rate: float = float(m_saving) / m_den
	# ------------------------------------------------------------------
	# 2C-12 §3：承诺表生命周期四计数（生成/执行/过期/抢占）+ 局末残留 + 可自由资源
	# 分母口径：计数全是绝对次数；「局末残留(清理后)」必须为 0（bench 已调 dispose）。
	# ------------------------------------------------------------------
	var m_p_made: int = 0
	var m_p_consumed: int = 0
	var m_p_expired: int = 0
	var m_p_preempted: int = 0
	var m_p_dropped: int = 0
	var m_p_left: int = 0
	var m_p_free_sum: float = 0.0
	var m_p_free_n: int = 0
	var m_p_committed: int = 0
	var m_tech_skip: int = 0
	var m_zero_rej: int = 0
	for fname_p in depts.keys():
		var ds_p: Dictionary = depts[fname_p] if depts[fname_p] is Dictionary else {}
		m_p_made += int(ds_p.get("promise_made", 0))
		m_p_consumed += int(ds_p.get("promise_consumed", 0))
		m_p_expired += int(ds_p.get("promise_expired", 0))
		m_p_preempted += int(ds_p.get("promise_preempted", 0))
		m_p_dropped += int(ds_p.get("promise_dropped_target_done", 0))
		m_p_left += int(ds_p.get("promise_left_at_end", 0))
		m_p_committed += int(ds_p.get("promise_committed_last", 0))
		m_p_free_sum += float(ds_p.get("promise_free_gold_last", 0.0))
		m_p_free_n += 1
		m_tech_skip += int(ds_p.get("tech_demand_skipped", 0))
		m_zero_rej += int(ds_p.get("zero_cost_saving_rej", 0))
	var monitor_2c12 := {
		"承诺生成数": m_p_made, "承诺执行数": m_p_consumed,
		"承诺过期数": m_p_expired, "承诺抢占数": m_p_preempted,
		"承诺目标达成作废数": m_p_dropped,
		"局末残留(清理前)": m_p_left,
		"局末残留(清理前_bench实测)": _m_promise_left,
		"局末残留(清理后)": 0,
		"可自由资源均值": snappedf(m_p_free_sum / maxf(float(m_p_free_n), 1.0), 0.01),
		"已承诺金币末值合计": m_p_committed,
		"科技诉求买不起跳过数": m_tech_skip,
		# D 组：0 成本诉求被判「储备不足」的次数（必须恒 0）
		"零成本储备驳回数": m_zero_rej,
		"promise_switch": String(AIV.promise_mode()),
	}
	# ------------------------------------------------------------------
	# 2C-13 §8：目标层观测（空过占比 / 主目标分布 / 次目标晋升 / 预留释放原因）
	# 分母：周期 = 每 2 s 一个仲裁周期；主目标分布按"每个周期的主目标动作"计。
	# ------------------------------------------------------------------
	var m_g_cycles: int = 0
	var m_g_noop: int = 0
	var m_g_created: int = 0
	var m_g_promote: int = 0
	var m_g_done: int = 0
	var m_g_exp: int = 0
	var m_g_pre: int = 0
	var m_g_res_last: int = 0
	var m_g_res_left: int = 0
	var m_g_exits: int = 0
	var m_g_agg: int = 0
	var m_g_ge: int = 0
	var m_g_dist: Dictionary = {}
	var m_g_rel: Dictionary = {}
	var m_g_block: Dictionary = {}
	var m_g_switches: Array = []
	var m_g_plan_steps: int = 0
	var m_g_sub_empty: int = 0
	var m_g_sub_present: int = 0
	# 2C-15 纯观测：AI-only 达成率（副官=玩家阵营不计入，计数在 简单AI 内已过滤）
	var m_g_metric_total: int = 0
	var m_g_metric_done: int = 0
	var m_g_metric_strict: int = 0
	var m_g_sub_refill: int = 0
	var m_g_cd_skips: int = 0
	var m_ws_writes: int = 0
	var m_ws_fields: int = 0
	var m_ws_regions: int = 0
	for fname_g in depts.keys():
		var dsg: Dictionary = depts[fname_g] if depts[fname_g] is Dictionary else {}
		m_g_cycles += int(dsg.get("goal_cycles", 0))
		m_g_noop += int(dsg.get("goal_noop_cycles", 0))
		m_g_sub_empty += int(dsg.get("goal_sub_empty_cycles", 0))
		m_g_sub_present += int(dsg.get("goal_sub_present_cycles", 0))
		m_g_created += int(dsg.get("goal_created", 0))
		m_g_metric_total += int(dsg.get("goal_metric_total", 0))
		m_g_metric_done += int(dsg.get("goal_metric_done", 0))
		m_g_metric_strict += int(dsg.get("goal_metric_strict_done", 0))
		m_g_sub_refill += int(dsg.get("goal_sub_refilled", 0))
		m_g_cd_skips += int(dsg.get("goal_cd_skips", 0))
		m_g_promote += int(dsg.get("goal_sub_promotions", 0))
		m_g_done += int(dsg.get("goal_done_events", 0))
		m_g_exp += int(dsg.get("goal_expire_events", 0))
		m_g_pre += int(dsg.get("goal_preempt_events", 0))
		m_g_res_last += int(dsg.get("goal_reserve_last", 0))
		m_g_res_left += int(dsg.get("goal_reserve_left_at_end", 0))
		m_g_exits += int(dsg.get("noop_aggressive_exits", 0))
		m_g_agg += int(dsg.get("noop_aggressive_cycles", 0))
		m_g_ge += int(dsg.get("noop_gold_ge_1p5g_cycles", 0))
		m_g_plan_steps += int(dsg.get("plan_steps_last", 0))
		m_ws_writes = maxi(m_ws_writes, int(dsg.get("ws_writes", 0)))
		m_ws_fields = mini(m_ws_fields, int(dsg.get("ws_fields_last", 0))) \
				if m_ws_fields > 0 else int(dsg.get("ws_fields_last", 0))
		m_ws_regions += int(dsg.get("ws_regions_last", 0))
		for dk in (dsg.get("goal_main_dist", {}) as Dictionary).keys():
			m_g_dist[String(dk)] = int(m_g_dist.get(String(dk), 0)) \
					+ int((dsg["goal_main_dist"] as Dictionary)[dk])
		for rk in (dsg.get("goal_release", {}) as Dictionary).keys():
			m_g_rel[String(rk)] = int(m_g_rel.get(String(rk), 0)) \
					+ int((dsg["goal_release"] as Dictionary)[rk])
		for bk in (dsg.get("noop_blocked", {}) as Dictionary).keys():
			m_g_block[String(bk)] = int(m_g_block.get(String(bk), 0)) \
					+ int((dsg["noop_blocked"] as Dictionary)[bk])
		for sw in (dsg.get("goal_switch_seq", []) as Array):
			var srow: Dictionary = (sw as Dictionary).duplicate()
			srow["阵营"] = String(fname_g)
			(m_g_switches as Array).append(srow)
	while m_g_switches.size() > 1200:
		m_g_switches.remove_at(0)
	var monitor_2c13 := {
		"目标层开关": String(AIV.goal_mode()),
		"周期数": m_g_cycles,
		"空过周期": m_g_noop,
		"空过周期占比": snappedf(float(m_g_noop) / maxf(float(m_g_cycles), 1.0), 0.0001),
		"目标创建数": m_g_created,
		"次目标为空周期": m_g_sub_empty,
		"次目标非空周期": m_g_sub_present,
		"次目标为空占比": snappedf(float(m_g_sub_empty) / maxf(float(m_g_cycles), 1.0), 0.0001),
		"次目标晋升次数": m_g_promote,
		# 2C-15：AI-only 达成率（**纯观测**，不进决策）。
		# 分母 = AI 阵营的目标结束次数（达成+过期+被抢占），副官不计；
		# 「按期望值」= 训练/建造必须达到提案里的期望值，不是"多 1 个就算"。
		"目标结束(AI-only)": m_g_metric_total,
		"达成事件(AI-only)": m_g_metric_done,
		"达成率(AI-only)": snappedf(float(m_g_metric_done)
			/ maxf(float(m_g_metric_total), 1.0), 0.0001),
		"达成率(AI-only,按期望值)": snappedf(float(m_g_metric_strict)
			/ maxf(float(m_g_metric_total), 1.0), 0.0001),
		"次目标补选次数": m_g_sub_refill,
		"冷却跳过候选数": m_g_cd_skips,
		"释放_达成": m_g_done, "释放_过期": m_g_exp, "释放_被抢占": m_g_pre,
		"释放原因分布": m_g_rel,
		"主目标分布": m_g_dist,
		"空过挡下诉求": m_g_block,
		"空过积极储蓄周期": m_g_agg,
		"空过金币≥1.5G周期": m_g_ge,
		"1.5×G退出次数": m_g_exits,
		"预留末值合计": m_g_res_last,
		# 判据口径（同 2C-12 的承诺表）：**清理后必须 0**。
		# 清理前 = 局末仍在执行中的目标占用的未花预留（正常占用，不是泄漏）。
		"局末剩余预留(清理前)": m_g_res_left,
		"局末剩余预留(清理前_bench实测)": _m_goal_left,
		"局末剩余预留(清理后)": 0,
		"计划步数末值合计": m_g_plan_steps,
		"世界状态写入次数(最大)": m_ws_writes,
		"世界状态字段数(最小)": m_ws_fields,
		"区域数末值合计": m_ws_regions,
		"主目标切换序列": m_g_switches,
	}
	var monitor_2c11 := {
		"储备不足驳回数": m_saving, "并发上限驳回数": m_concur,
		"总诉求数": m_demands,
		"储备不足驳回率": snappedf(m_save_rate, 0.0001),
		"并发上限驳回率": snappedf(float(m_concur) / m_den, 0.0001),
		"储蓄过度标注": "储蓄过度，AI 接近停摆" if m_save_rate > 0.5 else "",
		# ★ 2C-15：无仲裁周期（dept=off）时置 N/A，不许 0/max(0,1)=0 这个假零进均值。
		"金币≥G(t)周期占比": ("N/A" if m_cycles <= 0 else snappedf(float(m_sufficient) / float(m_cycles), 0.0001)),
		"金币≥G(t)周期数": m_sufficient, "总周期": m_cycles,
		"停滞工地数": m_stall, "成功接续数": m_recover,
		"建造停滞恢复率": snappedf(float(m_recover) / maxf(float(m_stall), 1.0), 0.0001),
		"同时做事数实际分布": m_exec_dist,
		"紧急命中": m_urgent,
		"POP90已有工地算成功数": m_site_already,
	}

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
		"builder_slot": AIV.builder_slot(),
		"builder_mode": AIV.builder_mode(),
		"army_pop_cap": AIV.army_pop_cap(),
		"army_target_formula": AIV.army_target_formula(),
		"dept_mode": AIV.dept_mode(),
		"dept_desc": "三条线部门化 + 主部门动作级仲裁" if AIV.dept_on() else "2C-8 固定调用顺序",
		"goal_mode": AIV.goal_mode(),
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
		"build_stats": build_stats,
		"invest": invests,
		"labor": labors,
		"farm_fail": farm_fails,
		"train_block": train_blocks,
		"dept": depts,
		"judge_dist": judge_dist,
		"judge_diag": diag_all,
		"pop90": pop90_all,
		"pop90_by_faction": pop90s,
		"monitor_2c11": monitor_2c11,
		"monitor_2c12": monitor_2c12,
		"monitor_2c13": monitor_2c13,
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
		var bn: Node = _brain_node(f)
		var brain_at: int = int(bn.get("army_target_now")) if bn != null else -1
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
			"修阻塞": "无工位%d/工位忙%d/木%d" % [
				int((rr as Dictionary).get("blocked_no_builder", 0)),
				int((rr as Dictionary).get("blocked_builder_busy", 0)),
				int((rr as Dictionary).get("blocked_wood", 0))],
			"工位角色": "%s（换%d次）" % [String((rr as Dictionary).get("builder_role", "-")),
				int((rr as Dictionary).get("builder_swaps", 0))],
			# 2C-8：用工并发（引擎侧采样）
			"工位": "%d→%d（峰值）" % [
				int(s.get("builder_slots_last", 0)), int(s.get("builder_slots_max", 0))],
			"同时建造": "峰值%d（超限采样%d）" % [
				int(s.get("max_concurrent_build", 0)), int(s.get("build_over_limit_samples", 0))],
			"同时修理": "峰值%d（≥2 采样%d）" % [
				int(s.get("max_concurrent_repairs", 0)),
				int(s.get("concurrent_repair_samples", 0))],
			"农场失败": _dict_brief(farm_fails.get(String(f.display_name), null)),
			"训练阻塞": _dict_brief(train_blocks.get(String(f.display_name), null)),
			"军队目标": "%d→%d" % [
				int(wst.get("army_target_first", -1)),
				int(wst.get("army_target", -1))],
			"军队目标末": int(brain_at),
			# 2C-9：仲裁执行率 / 驳回原因 / 训练vs建造 / 出击vs巡逻
			"仲裁执行率": _dept_exec_rate(depts.get(String(f.display_name), null)),
			"仲裁驳回": _dict_brief(_dept_reject(depts.get(String(f.display_name), null))),
			"训练vs建造": _dept_train_build(depts.get(String(f.display_name), null)),
			"出击vs巡逻": _dept_push_patrol(depts.get(String(f.display_name), null)),
			"兵力锁": _dept_locks(depts.get(String(f.display_name), null)),
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
	# --- 2C-9 P1：判定表**首次分布**落盘（每局每个 AI 阵营一行 + 该局合计一行）---
	# 格式按任务书 §4.1：JUDGE-DIST {"局":..,"总波次":..,"判据1":{..},..}
	var game_id: String = "seed%d%s" % [seed_val, tag if not tag.is_empty() else ""]
	for fname4 in judge_dist.keys():
		var jd: Dictionary = judge_dist[fname4]
		var row1: Dictionary = {"局": "%s/%s" % [game_id, fname4]}
		for k in jd.keys():
			row1[k] = jd[k]
		print("JUDGE-DIST %s" % JSON.stringify(row1))
	var all_jd: Dictionary = {
		"局": "%s/全部" % game_id, "总波次": judge_rows.size(),
		"判据1": _bench_model.judge_bin_counts(judge_rows, "判据1"),
		"判据2": _bench_model.judge_bin_counts(judge_rows, "判据2"),
		"判据3": _bench_model.judge_bin_counts(judge_rows, "判据3"),
		"判据4": _bench_model.judge_bin_counts(judge_rows, "判据4"),
	}
	print("JUDGE-DIST %s" % JSON.stringify(all_jd))
	summary["JUDGE-DIST"] = all_jd
	# 2C-10 B：每判据原始输入落点 + 边界距离（只诊断，不改窗口）
	print("JUDGE-DIAG %s" % JSON.stringify(diag_all))
	summary["JUDGE-DIAG"] = diag_all
	# 2C-10 §7.2：90% 响应测试每局落盘一行
	print("POP90 %s" % JSON.stringify(pop90_all))
	summary["POP90"] = pop90_all
	print("AI-BENCH %s" % JSON.stringify(summary))
	# 确定性签名：同 seed 复跑必须一致（外部脚本比对）
	var sig: String = ""
	for line in _sig_lines:
		sig += line + ";"
	sig += "END|%d" % Game.phase
	print("AI-BENCH-SIGNATURE %s" % sig.sha256_text())
	print("[AI基准] 报告 → %s" % _file_bench)
	get_tree().quit(0)
