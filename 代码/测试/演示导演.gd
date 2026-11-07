extends Node
## **开发日志 · 拍摄导演** —— 只服务"录演示片"，不参与玩法、不写存档。
##
## 为什么需要它：录一段像样的演示，需要三件玩法里本来不存在的事：
##   ① **拨太阳**：把时钟钉在某个时刻，或者让它在一条镜头里连续走完黄昏→入夜；
##   ② **走镜头**：RTS 镜头只跟鼠标，拍不出"推、摇、跟"；这里直接接管 Camera3D；
##   ③ **按剧本出兵**：现在野怪是营地定时刷、刷完待在原地，不会主动扑家。
##      拍"夜袭"这条镜头时由本脚本把野怪从营地请出来、下令攻打各个玩家基地。
##
## ★ 三条纪律（改这个文件前先看）：
##   1. 只在 `--demo-shot=<名字>` 时被主场景挂载；正常开局一行都不跑。
##   2. 不复用、不修改任何玩法脚本的私有状态：只调它们的公开方法
##      （`debug_set_hour` / `spawn_unit` / `order_attack_move` / `base_center`）。
##   3. 镜头一旦接管，就把「镜头」节点的 process 全关掉 —— 否则鼠标边缘滚动、
##      惯性收敛会在录制过程中偷偷把机位挪走（录出来是"慢慢漂"的废片）。
##
## 用法（录制一条镜头）：
##   godot --path . --resolution 1920x1080 --write-movie=<out.avi> --fixed-fps 60 \
##     -- --demo-shot=raid --all-hidden --qa-reveal
##
## 可用镜头：
##   list   —— 只打印场景情报（基地/营地坐标、单位数），然后退出，用来定机位
##   bench  —— 固定机位 5 秒，试分辨率/帧率与质感
##   day    —— 白天，基地环绕
##   dusk   —— 黄昏 → 入夜，基地环绕（含营火点亮）
##   night  —— 深夜低机位，月光与营火
##   raid   —— 入夜野怪出营、行军、扑家
##   after  —— 战后破晓

## 每拍最多推进多少秒：movie maker 掉帧时 delta 会很大，不夹一下镜头会"跳"
const MAX_STEP := 0.1
## 相机离地最低高度（防止低机位切进地形）
const MIN_CLEARANCE := 2.2

var _main: Node3D = null
var _rig: Node = null
var _cam: Camera3D = null
var _day: Node = null
var _level: Node3D = null

## `--demo-stop=<秒>`：跑到第 N 秒就收工（配合 --shot 只拍一张，试机位用）
var _stop_at: float = -1.0
var _t_total: float = 0.0
var _beats: Array = []
var _i: int = 0
var _bt: float = 0.0
var _done: bool = false

## 参与"夜袭"的野怪（跟拍用：中心点取它们的平均位置）
var _raid: Array = []
## 跟拍失效时的备用中心（野怪全死了镜头不至于飞到原点）
var _raid_last: Vector3 = Vector3.INF


func _ready() -> void:
	_main = get_parent() as Node3D
	# 等两帧：关卡的地形高度、阵营的基地中心都是 _ready 里才落位的
	await get_tree().process_frame
	await get_tree().process_frame
	_grab_refs()
	_stop_at = _argf("--demo-stop=", -1.0)
	match _shot_name():
		"list":
			_shot_list()
		"bench":
			_shot_bench()
		"still":
			_shot_still()
		"dawn", "day":
			_shot_day()
		"dusk":
			_shot_dusk()
		"night":
			_shot_night()
		"raid":
			_shot_raid()
		"after":
			_shot_after()
		_:
			push_warning("[导演] 不认识的镜头名，改跑 list")
			_shot_list()
	_run()


# ===========================================================================
# 基础设施
# ===========================================================================

func _shot_name() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--demo-shot="):
			return a.substr(12).strip_edges()
	return ""


func _grab_refs() -> void:
	_rig = _main.get_node_or_null("镜头")
	if _rig != null:
		_cam = _rig.get_node_or_null("相机") as Camera3D
		# 整条输入/位姿链全部关掉：谁都别再动机位
		_rig.set_process(false)
		_rig.set_physics_process(false)
		_rig.set_process_input(false)
		_rig.set_process_unhandled_input(false)
		_rig.set("locked", true)
	_day = Game.day_night
	_level = Game.level
	print("[导演] 镜头=%s 日夜=%s 关卡=%s" % [
		"有" if _cam != null else "无", "有" if _day != null else "无",
		"有" if _level != null else "无"])


## 场景情报（定机位用，不做任何演出）
func _shot_list() -> void:
	print("[导演] 玩家基地=%s" % str(_base_of(Game.player_faction)))
	for f in Game.factions:
		if f != null:
			print("[导演]   槽%d %s 队%d 基地=%s 单位=%d 建筑=%d" % [
				f.slot, f.display_name, f.team, str(_base_of(f)),
				f.units.size(), f.buildings.size()])
	print("[导演] 中立野怪=%d 只" % (
		Game.neutral_faction.units.size() if Game.neutral_faction != null else -1))
	for c in _camps():
		print("[导演]   营地「%s」@%s 活 %d/%d" % [
			String(c.get("name", "")), str(c.get("pos", Vector3.ZERO)),
			int(c.get("alive", 0)), int(c.get("total", 0))])
	# 营火位置：夜景镜头要靠它当画面里唯一的暖色光源
	if _level != null:
		var bc: Vector3 = _base_of(Game.player_faction)
		for n in _main.find_children("*", "OmniLight3D", true, false):
			var p3: Vector3 = (n as Node3D).global_position
			if p3.distance_to(bc) < 60.0:
				var sc: Script = n.get_script() as Script
				print("[导演]   点光 %s @%s 脚本=%s" % [
					String(n.name), str(p3),
					String(sc.resource_path) if sc != null else "无"])
	_finish()


## 固定机位 5 秒（把 4K/1080p 的录制成本量出来再决定拍哪档）
func _shot_bench() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	_beats.append({
		"dur": 5.0,
		"pos_a": b + Vector3(26.0, 22.0, 30.0),
		"pos_b": b + Vector3(20.0, 18.0, 24.0),
		"look_a": b, "look_b": b,
		"hour_a": 10.0, "hour_b": 10.0,
	})


## 定机位（不录整段，只停住让 --shot 拍一张）：
##   --demo-shot=still --demo-ang=49 --demo-rad=40 --demo-h=22 --demo-hour=10 [--demo-fov=48]
## 参数就是上面 orbit 的四个量，改一个数跑一张，几秒钟一轮，比录整段再抽帧快得多。
func _shot_still() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	var ang: float = _argf("--demo-ang=", 49.0)
	var rad: float = _argf("--demo-rad=", 40.0)
	var h: float = _argf("--demo-h=", 22.0)
	var hour: float = _argf("--demo-hour=", 10.0)
	var fov: float = _argf("--demo-fov=", 48.0)
	var look_y: float = _argf("--demo-look=", 2.0)
	_beats.append({
		"dur": 1.5, "mode": "orbit",
		"center": b, "look_off": Vector3(0.0, look_y, 0.0),
		"ang_a": ang, "ang_b": ang, "rad_a": rad, "rad_b": rad,
		"h_a": h, "h_b": h, "hour_a": hour, "hour_b": hour,
		"fov_a": fov, "fov_b": fov,
	})


func _argf(prefix: String, fallback: float) -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return float(a.substr(prefix.length()))
	return fallback


# ===========================================================================
# 镜头一：白天 · 基地环绕
# ===========================================================================
## 机位角度说明：基地在 (44,44)，地图中心在 (0,0)。
## 相机站在 base 的**外侧**（角度 ~40°）+ 回看基地，背景才是地图内部；
## 站在内侧会把"地图边缘 + 天空"当前景拍进去，像半成品。
func _shot_day() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	_beats.append({
		"dur": 9.0, "mode": "orbit",
		"center": b, "look_off": Vector3(0.0, 2.0, 0.0),
		"ang_a": 42.0, "ang_b": 78.0,
		"rad_a": 34.0, "rad_b": 30.0,
		"h_a": 27.0, "h_b": 23.0,
		"hour_a": 8.8, "hour_b": 10.8,
		"fov_a": 46.0, "fov_b": 47.0,
	})


# ===========================================================================
# 镜头二：黄昏 → 入夜（营火点亮）—— 时间系统的主镜头
# ===========================================================================
func _shot_dusk() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	_beats.append({
		"dur": 14.0, "mode": "orbit",
		"center": b, "look_off": Vector3(0.0, 2.0, 0.0),
		"ang_a": 25.0, "ang_b": 100.0,
		"rad_a": 33.0, "rad_b": 27.0,
		"h_a": 26.0, "h_b": 18.0,
		"hour_a": 17.0, "hour_b": 20.6,
		"fov_a": 44.0, "fov_b": 48.0,
	})


# ===========================================================================
# 镜头三：深夜 · 月光与营火
# ===========================================================================
func _shot_night() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	_beats.append({
		"dur": 8.0, "mode": "orbit",
		"center": b, "look_off": Vector3(-1.0, 1.5, 0.0),
		"ang_a": 55.0, "ang_b": 96.0,
		"rad_a": 26.0, "rad_b": 21.0,
		"h_a": 15.0, "h_b": 11.0,
		"hour_a": 21.2, "hour_b": 22.4,
		"fov_a": 45.0, "fov_b": 44.0,
	})


# ===========================================================================
# 镜头三：入夜 · 野怪出营 → 扑家
# ===========================================================================
func _shot_raid() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	var camp: Vector3 = _camp_near(b)
	var dir: Vector3 = (b - camp)
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.1 else Vector3.FORWARD
	# 队伍的行进侧向：跟拍机位放在"斜前方"，让野怪朝镜头压过来（纯侧跟像监控）
	var side: Vector3 = Vector3(-dir.z, 0.0, dir.x)
	var up: Vector3 = Vector3.UP

	# 先把戏搭好：每家的基地都放一队野怪（"攻打各位玩家"，不是只针对镜头里的那家）
	_stage_night_raid()

	# ① 出营：正对营地，野怪在门口越聚越多（这一段定"它们从哪来"）
	_beats.append({
		"dur": 3.5,
		"pos_a": camp + dir * 15.0 + Vector3(0.0, 11.0, 0.0),
		"pos_b": camp + dir * 12.0 + Vector3(0.0, 9.5, 0.0),
		"look_a": camp + Vector3(0.0, 0.8, 0.0),
		"look_b": camp + Vector3(0.0, 0.8, 0.0),
		"hour_a": 19.65, "hour_b": 19.95,
		"fov_a": 46.0, "fov_b": 44.0,
	})
	# ② 行军：高位跟拍。
	#   ★ 别把镜头放低：夜里树是黑的、草是黑的、豺狼人也是深灰的，
	#     低机位一进林子整帧就糊成一团。抬到 20m 俯看，"一条队伍在草地上推"才读得出来。
	_beats.append({
		"dur": 5.5, "mode": "follow",
		"off_a": side * 15.0 + dir * 8.0 + Vector3.UP * 21.0,
		"off_b": side * 12.0 + dir * 5.0 + Vector3.UP * 18.0,
		"look_off": Vector3(0.0, 0.5, 0.0),
		"hour_a": 19.95, "hour_b": 20.5,
		"fov_a": 50.0, "fov_b": 48.0,
	})
	# ③ 家里：镜头切回基地，守军正在集结（给观众一个"要挨打了"的视角）
	_beats.append({
		"dur": 3.5,
		"pos_a": b + side * 20.0 + up * 14.0,
		"pos_b": b + side * 16.0 + up * 12.0,
		"look_a": b + Vector3(0.0, 1.5, 0.0),
		"look_b": b + Vector3(0.0, 1.5, 0.0),
		"hour_a": 20.5, "hour_b": 20.7,
		"fov_a": 48.0, "fov_b": 46.0,
	})
	# ④ 接战：**固定机位**横在扑家路线上，等它们自己走进画面。
	#   跟拍在这里一定会被树/工地挡死（实测两次），固定机位 + 让动作入画最稳。
	_beats.append({
		"dur": 11.0,
		"pos_a": b - dir * 2.0 + side * 19.0 + up * 12.0,
		"pos_b": b + dir * 1.0 + side * 15.0 + up * 10.5,
		"look_a": b - dir * 12.0 + Vector3(0.0, 1.0, 0.0),
		"look_b": b - dir * 8.0 + Vector3(0.0, 1.0, 0.0),
		"hour_a": 20.7, "hour_b": 21.5,
		"fov_a": 48.0, "fov_b": 46.0,
	})


# ===========================================================================
# 镜头四：战后破晓
# ===========================================================================
func _shot_after() -> void:
	var b: Vector3 = _base_of(Game.player_faction)
	_beats.append({
		"dur": 7.0,
		"pos_a": b + Vector3(-18.0, 12.0, 22.0),
		"pos_b": b + Vector3(-34.0, 26.0, 40.0),
		"look_a": b + Vector3(0.0, 1.0, 0.0),
		"look_b": b + Vector3(0.0, 2.0, 0.0),
		"hour_a": 5.6, "hour_b": 6.9,
		"fov_a": 46.0, "fov_b": 48.0,
	})


# ===========================================================================
# 演出：夜袭
# ===========================================================================

## 从每家的营地各请出一队野怪，下令攻打对应玩家的基地。
## 镜头跟的是"离玩家基地最近那座营地"的那一队（见 _raid）。
func _stage_night_raid() -> void:
	if Game.neutral_faction == null:
		push_warning("[导演] 没有中立阵营，夜袭拍不了")
		return
	var b: Vector3 = _base_of(Game.player_faction)
	var home_camp: Vector3 = _camp_near(b)
	var n_total: int = 0
	var targets: Array = []
	for f in Game.factions:
		if f != null:
			targets.append(f)
	for f in targets:
		var c: Vector3 = _camp_near(_base_of(f))
		if c == Vector3.INF:
			c = home_camp
		var pack: Array = _spawn_pack(c, 6, 3)
		n_total += pack.size()
		# 只跟"打玩家"的那一队：不同阵营的营地可能撞在同一座（地图上只有 4 座），
		# 把两队都塞进 _raid 会让跟拍中心落在两拨人中间 —— 画面里谁都不在中心。
		if f == Game.player_faction:
			_raid.append_array(pack)
		var goal: Vector3 = _base_of(f)
		var i: int = 0
		for u in pack:
			if u != null and is_instance_valid(u):
				# 每家摊开一点落点：全点同一个坐标会挤成一坨
				var ang: float = TAU * float(i) / float(maxi(pack.size(), 1))
				var p: Vector3 = goal + Vector3(cos(ang), 0.0, sin(ang)) * 7.0
				u.call("order_attack_move", RtsWorld.walkable_pos(p))
				i += 1
		print("[导演] 夜袭 → %s：%d 只（营地 %s）" % [f.display_name, pack.size(), str(c)])
	print("[导演] 夜袭总兵力 %d 只；跟拍队 %d 只" % [n_total, _raid.size()])


## 在营地外圈刷一队野怪（黄金角铺开，避免叠在一起）
func _spawn_pack(at: Vector3, warriors: int, scouts: int) -> Array:
	var out: Array = []
	var seq: int = 0
	for i in warriors:
		var u: Node3D = _spawn_creep(&"gnoll_warrior", at, seq)
		seq += 1
		if u != null:
			out.append(u)
	for i in scouts:
		var u2: Node3D = _spawn_creep(&"gnoll_scout", at, seq)
		seq += 1
		if u2 != null:
			out.append(u2)
	return out


func _spawn_creep(id: StringName, at: Vector3, seq: int) -> Node3D:
	var ang: float = 2.39996323 * float(seq)
	var rad: float = 4.2 + 0.55 * float(seq)
	var p: Vector3 = at + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	p = RtsWorld.walkable_pos(RtsWorld.snap_y(p))
	var u: Node3D = Game.spawn_unit(Game.neutral_faction, id, p, _level)
	if u != null:
		u.call("order_stop")
	return u


# ===========================================================================
# 时间线
# ===========================================================================

func _run() -> void:
	if _beats.is_empty():
		_finish()
		return
	_enter(0)


func _process(delta: float) -> void:
	if _done or _beats.is_empty():
		return
	var dt: float = minf(delta, MAX_STEP)
	_bt += dt
	_t_total += dt
	if _stop_at > 0.0 and _t_total >= _stop_at:
		_finish()
		return
	var b: Dictionary = _beats[_i]
	var dur: float = maxf(float(b.get("dur", 1.0)), 0.001)
	var k: float = clampf(_bt / dur, 0.0, 1.0)
	var e: float = _ease(k, String(b.get("ease", "smooth")))

	if b.has("hour_a"):
		var ha: float = float(b["hour_a"])
		var hb: float = float(b.get("hour_b", ha))
		_set_hour(lerpf(ha, hb, e))

	if String(b.get("mode", "static")) == "follow":
		_apply_follow(b, e)
	elif String(b.get("mode", "static")) == "orbit":
		_apply_orbit(b, e)
	else:
		_apply_static(b, e)

	if _bt >= dur:
		_bt = 0.0
		_i += 1
		if _i >= _beats.size():
			_finish()
		else:
			_enter(_i)


## 进入某一拍：先跑 on_enter 回调，再按"硬切"把机位落到起点
func _enter(i: int) -> void:
	var b: Dictionary = _beats[i]
	var cb: Variant = b.get("on_enter", null)
	if cb is Callable and (cb as Callable).is_valid():
		(cb as Callable).call()
	if i > 0 and bool(b.get("cut", true)):
		# 硬切：立刻用这一拍的起点摆位，避免上一拍的末位姿漏进新镜头
		var e0: float = 0.0
		var m: String = String(b.get("mode", "static"))
		if m == "follow":
			_apply_follow(b, e0)
		elif m == "orbit":
			_apply_orbit(b, e0)
		else:
			_apply_static(b, e0)


func _apply_static(b: Dictionary, e: float) -> void:
	var pa: Vector3 = b.get("pos_a", Vector3.ZERO)
	var pb: Vector3 = b.get("pos_b", pa)
	var la: Vector3 = b.get("look_a", pa)
	var lb: Vector3 = b.get("look_b", la)
	var fa: float = float(b.get("fov_a", 50.0))
	var fb: float = float(b.get("fov_b", fa))
	_place(pa.lerp(pb, e), la.lerp(lb, e), lerpf(fa, fb, e))


func _apply_follow(b: Dictionary, e: float) -> void:
	var c: Vector3 = _group_center()
	if c == Vector3.INF:
		return
	var oa: Vector3 = b.get("off_a", Vector3(10.0, 8.0, 12.0))
	var ob: Vector3 = b.get("off_b", oa)
	var lo: Vector3 = b.get("look_off", Vector3(0.0, 1.0, 0.0))
	var fa: float = float(b.get("fov_a", 46.0))
	var fb: float = float(b.get("fov_b", fa))
	_place(c + oa.lerp(ob, e), c + lo, lerpf(fa, fb, e))


func _apply_orbit(b: Dictionary, e: float) -> void:
	var c: Vector3 = b.get("center", Vector3.ZERO)
	var a0: float = deg_to_rad(float(b.get("ang_a", 0.0)))
	var a1: float = deg_to_rad(float(b.get("ang_b", 0.0)))
	var r0: float = float(b.get("rad_a", 30.0))
	var r1: float = float(b.get("rad_b", r0))
	var h0: float = float(b.get("h_a", 18.0))
	var h1: float = float(b.get("h_b", h0))
	var ang: float = lerpf(a0, a1, e)
	var rad: float = lerpf(r0, r1, e)
	var h: float = lerpf(h0, h1, e)
	var look: Vector3 = c + (b.get("look_off", Vector3(0.0, 2.0, 0.0)) as Vector3)
	var fa: float = float(b.get("fov_a", 48.0))
	var fb: float = float(b.get("fov_b", fa))
	_place(c + Vector3(cos(ang) * rad, h, sin(ang) * rad), look, lerpf(fa, fb, e))


func _place(pos: Vector3, look: Vector3, fov: float) -> void:
	if _cam == null:
		return
	var gy: float = _ground(pos.x, pos.z) + MIN_CLEARANCE
	var p := Vector3(pos.x, maxf(pos.y, gy), pos.z)
	_cam.fov = fov
	_cam.global_position = p
	if p.distance_squared_to(look) > 0.04:
		_cam.look_at(look, Vector3.UP)


func _set_hour(h: float) -> void:
	if _day != null:
		_day.call("debug_set_hour", fposmod(h, 24.0))


func _ease(k: float, kind: String) -> float:
	match kind:
		"linear":
			return k
		"out":
			return 1.0 - pow(1.0 - k, 2.0)
		_:
			return k * k * (3.0 - 2.0 * k)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[导演] 镜头结束（%d 拍）" % _beats.size())
	await get_tree().create_timer(0.2).timeout
	get_tree().quit()


# ===========================================================================
# 查询
# ===========================================================================

func _base_of(f: RtsFaction) -> Vector3:
	if f == null or _level == null:
		return Vector3.ZERO
	var c: Vector3 = _level.base_center(f)
	return Vector3(c.x, _ground(c.x, c.z), c.z)


func _ground(x: float, z: float) -> float:
	if _level == null or not _level.has_method("height_at"):
		return 0.0
	return float(_level.call("height_at", x, z))


func _camps() -> Array:
	var creeps: Node = _main.get("creeps")
	if creeps == null:
		return []
	var cs: Node = creeps.get("camp_system")
	if cs == null or not is_instance_valid(cs):
		return []
	return cs.call("camps") as Array


## 离某个点最近的营地；没有营地就退回到"该点向地图中心 30m"的临时点
func _camp_near(p: Vector3) -> Vector3:
	var best: Vector3 = Vector3.INF
	var bd: float = 1e20
	for c in _camps():
		var cp: Vector3 = c.get("pos", Vector3.ZERO)
		var d: float = cp.distance_to(p)
		if d < bd:
			bd = d
			best = Vector3(cp.x, _ground(cp.x, cp.z), cp.z)
	if best == Vector3.INF:
		var fallback: Vector3 = p.lerp(Vector3.ZERO, 0.5)
		best = Vector3(fallback.x, _ground(fallback.x, fallback.z), fallback.z)
	return best


func _group_center() -> Vector3:
	var sum := Vector3.ZERO
	var n: int = 0
	for u in _raid:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		sum += (u as Node3D).global_position
		n += 1
	if n == 0:
		return _raid_last if _raid_last != Vector3.INF else Vector3.INF
	var c: Vector3 = sum / float(n)
	_raid_last = c
	return c
