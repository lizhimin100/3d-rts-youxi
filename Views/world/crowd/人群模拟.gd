extends RefCounted
## **人群模拟核心** —— 一万个单位，零个 Node3D。
##
## 执行模型（四件事，顺序不能换）：
##   1. **20Hz 固定步长**：逻辑每 0.05s 跑一次，渲染按 60fps 插值。逻辑与画面彻底分离，
##      CPU 不再跟着帧率跑（这是"3000 兵 2.5fps"最直接的解药）。
##   2. **SoA 连续数组**：位置/速度/半径/血量各一条 `Packed*Array`，
##      没有 Variant、没有对象头、没有 `get_node()`。
##   3. **平坦网格 + 位运算**：`(z >> 2) << 6 | (x >> 2)`，热循环里**没有一个 `int /` 或 `%`**
##      （实测线程里整数除余是 0.5× 负加速，见 Documents/万单位与SC2管线_可行性评估.md §2）。
##   4. **WorkerThreadPool 分块**：每块 ≥512 单位；块内只写自己那段 `des_*` / `push_*`，
##      不跨块写，不吃锁。
##
## 单位只记两个拐点（`n1/n2`），走完就推进，偏离超过 `PATH_DEVIATE` 就丢窗口重算。
## 空中单位（`ST_AIR`）不参与推挤、不吃流场，但按 `slot` 保持阵型。

const C := preload("res://Views/world/crowd/人群常量.gd")
const Space := preload("res://Views/world/crowd/人群空间.gd")
const Flow := preload("res://Views/world/crowd/人群流场.gd")
const Nav := preload("res://Views/world/crowd/人群导航.gd")

# ---------------------------------------------------------------------------
# SoA：位置 / 运动
# ---------------------------------------------------------------------------
var count: int = 0
var pos_x: PackedFloat32Array = PackedFloat32Array()
var pos_z: PackedFloat32Array = PackedFloat32Array()
var pos_y: PackedFloat32Array = PackedFloat32Array()
## 上一 tick 的位置（渲染插值用）
var prev_x: PackedFloat32Array = PackedFloat32Array()
var prev_z: PackedFloat32Array = PackedFloat32Array()
var vel_x: PackedFloat32Array = PackedFloat32Array()
var vel_z: PackedFloat32Array = PackedFloat32Array()
## 期望方向缓存（每 DIR_EVERY 个 tick 重算一次，steer 只读）
var dir_x: PackedFloat32Array = PackedFloat32Array()
var dir_z: PackedFloat32Array = PackedFloat32Array()
## steer 输出（每 tick 覆写）
var des_x: PackedFloat32Array = PackedFloat32Array()
var des_z: PackedFloat32Array = PackedFloat32Array()
var push_x: PackedFloat32Array = PackedFloat32Array()
var push_z: PackedFloat32Array = PackedFloat32Array()

# ---------------------------------------------------------------------------
# SoA：属性 / 状态
# ---------------------------------------------------------------------------
var radius: PackedFloat32Array = PackedFloat32Array()
var speed: PackedFloat32Array = PackedFloat32Array()
var hp: PackedFloat32Array = PackedFloat32Array()
var max_hp: PackedFloat32Array = PackedFloat32Array()
var yaw: PackedFloat32Array = PackedFloat32Array()
var anim_phase: PackedFloat32Array = PackedFloat32Array()
var state: PackedInt32Array = PackedInt32Array()
var team: PackedInt32Array = PackedInt32Array()
var group: PackedInt32Array = PackedInt32Array()

# ---------------------------------------------------------------------------
# SoA：目标 / 路径窗口
# ---------------------------------------------------------------------------
var goal_x: PackedFloat32Array = PackedFloat32Array()
var goal_z: PackedFloat32Array = PackedFloat32Array()
## 两个拐点（只有 has1/has2 为真时有效）
var n1_x: PackedFloat32Array = PackedFloat32Array()
var n1_z: PackedFloat32Array = PackedFloat32Array()
var n2_x: PackedFloat32Array = PackedFloat32Array()
var n2_z: PackedFloat32Array = PackedFloat32Array()
var has1: PackedByteArray = PackedByteArray()
var has2: PackedByteArray = PackedByteArray()
## 编队槽（相对军团目标点的偏移）
var slot_x: PackedFloat32Array = PackedFloat32Array()
var slot_z: PackedFloat32Array = PackedFloat32Array()
## 侧向意图（0=未定 / 1=左 / 2=右）与保持计时
var side: PackedByteArray = PackedByteArray()
var side_t: PackedFloat32Array = PackedFloat32Array()
## 卡住计时（连续多少秒位移 < 2cm）
var stuck_t: PackedFloat32Array = PackedFloat32Array()

# ---------------------------------------------------------------------------
# 地形与空间
# ---------------------------------------------------------------------------
## 1m 可走表（1=可走），65536
var walk: PackedByteArray = PackedByteArray()
## 1m 高度表（米），65536
var height: PackedFloat32Array = PackedFloat32Array()
var space: Space = null

## 流场池：最多 4 个军团同时行军
## 方向重算间隔（tick）。看路/流场采样不便宜，8 次/秒足够——
## 单位每 tick 都在动，但"往哪走"不该每 50ms 重算一次。
const DIR_EVERY: int = 4
const MAX_FLOWS: int = 4
var _flows: Array = []
var _flow_free: PackedInt32Array = PackedInt32Array()

## 军团表：group id -> {target_x, target_z, flow, built_at}
var _groups: Array = []

# ---------------------------------------------------------------------------
# 线程
# ---------------------------------------------------------------------------
var _chunk_from: PackedInt32Array = PackedInt32Array()
var _chunk_to: PackedInt32Array = PackedInt32Array()
var _chunk_n: int = 0
var _threads: int = 1

## 诊断
var tick_ms: float = 0.0
var steer_ms: float = 0.0
var spatial_ms: float = 0.0
var flow_ms: float = 0.0
var tick_count: int = 0
var thread_used: bool = false
var _dir_tick: int = 0


func _init() -> void:
	_alloc()
	space = Space.new()
	for i in range(MAX_FLOWS):
		_flows.append(Flow.new())


func _alloc() -> void:
	var n: int = C.MAX_UNITS
	pos_x.resize(n); pos_z.resize(n); pos_y.resize(n)
	prev_x.resize(n); prev_z.resize(n)
	vel_x.resize(n); vel_z.resize(n)
	des_x.resize(n); des_z.resize(n)
	dir_x.resize(n); dir_z.resize(n)
	push_x.resize(n); push_z.resize(n)
	radius.resize(n); speed.resize(n); hp.resize(n); max_hp.resize(n)
	yaw.resize(n); anim_phase.resize(n)
	state.resize(n); team.resize(n); group.resize(n)
	goal_x.resize(n); goal_z.resize(n)
	n1_x.resize(n); n1_z.resize(n); n2_x.resize(n); n2_z.resize(n)
	has1.resize(n); has2.resize(n)
	slot_x.resize(n); slot_z.resize(n)
	side.resize(n); side_t.resize(n); stuck_t.resize(n)
	walk.resize(C.GRID_TOTAL)
	walk.fill(0)
	height.resize(C.GRID_TOTAL)
	height.fill(0.0)


## 设置地形。walk1m / height1m 都是 256×256，索引 `(cz << 8) | cx`。
func set_terrain(walk1m: PackedByteArray, height1m: PackedFloat32Array) -> void:
	walk = walk1m
	height = height1m
	for f in _flows:
		(f as Flow).sync_from_walk1m(walk)


## 线程数：块数 = clamp(count / CHUNK_MIN, 1, CPU/2)
func configure_threads(cpu: int = 0) -> void:
	var c: int = cpu if cpu > 0 else OS.get_processor_count()
	_threads = maxi(1, mini(8, c / 2))


# ===========================================================================
# 生成 / 编队
# ===========================================================================

## 生成一个单位，返回索引；满了返回 -1。
func spawn(x: float, z: float, p_team: int = 1, p_radius: float = 0.35, p_speed: float = 3.2) -> int:
	if count >= C.MAX_UNITS:
		return -1
	var i: int = count
	pos_x[i] = x
	pos_z[i] = z
	pos_y[i] = _height_at(x, z)
	prev_x[i] = x
	prev_z[i] = z
	vel_x[i] = 0.0
	vel_z[i] = 0.0
	des_x[i] = 0.0
	des_z[i] = 0.0
	dir_x[i] = 0.0
	dir_z[i] = 0.0
	push_x[i] = 0.0
	push_z[i] = 0.0
	radius[i] = p_radius
	speed[i] = p_speed
	max_hp[i] = 100.0
	hp[i] = 100.0
	yaw[i] = 0.0
	# 动画节拍错开：黄金比散列，保证任意 N 个单位的相位分布均匀，
	# 不会出现"整队齐步走"（这是人群层最廉价的观感升级）。
	anim_phase[i] = fmod(float(i) * 0.61803398875, 1.0)
	state[i] = C.ST_IDLE
	team[i] = p_team
	group[i] = -1
	goal_x[i] = x
	goal_z[i] = z
	has1[i] = 0
	has2[i] = 0
	slot_x[i] = 0.0
	slot_z[i] = 0.0
	side[i] = 0
	side_t[i] = 0.0
	stuck_t[i] = 0.0
	count += 1
	return i

## 建一个军团（一个目标一个流场），返回 group id。
func make_group(tx: float, tz: float) -> int:
	var g: int = _groups.size()
	var fidx: int = _take_flow()
	_groups.append({
		"target_x": tx, "target_z": tz,
		"flow": fidx, "built_at": -999.0,
	})
	if fidx >= 0:
		(_flows[fidx] as Flow).build(tx, tz)
		(_groups[g] as Dictionary)["built_at"] = 0.0
	return g


## 把一批单位塞进军团，按**方阵**分配槽位。
##
## 为什么不是环形：环形在 200 人时会排到 20m 半径，单位各自奔向自己的槽，
## 视觉上散成一团"彗尾"，既看不出阵型也看不出推挤。方阵（cols × rows）紧凑，
## 前排后排走同一条流场，挤在一起才试得出"空闲可推 / 快者少被推"。
func assign_group(g: int, indices: PackedInt32Array, spacing: float = 1.05) -> void:
	if g < 0 or g >= _groups.size():
		return
	var n: int = indices.size()
	if n == 0:
		return
	var cols: int = maxi(1, int(ceil(sqrt(float(n)))))
	# ⚠ 必须把军团目标写进每个单位：只写 slot 不写 goal 的话，
	# 单位的目标点会留在 spawn 时的脚下，整队"原地列队"——2026-11-13 踩过。
	var gd: Dictionary = _groups[g]
	var tx: float = float(gd["target_x"])
	var tz: float = float(gd["target_z"])
	for k in range(n):
		var i: int = indices[k]
		var col: int = k % cols
		var row: int = k / cols
		slot_x[i] = (float(col) - float(cols - 1) * 0.5) * spacing
		slot_z[i] = (float(row) - float(cols - 1) * 0.5) * spacing
		goal_x[i] = tx
		goal_z[i] = tz
		group[i] = g
		state[i] = C.ST_MOVE


## 给单个单位下移动令（个体行走，不用流场，直接指向目标）
func order_move(i: int, tx: float, tz: float) -> void:
	goal_x[i] = tx
	goal_z[i] = tz
	slot_x[i] = 0.0
	slot_z[i] = 0.0
	group[i] = -1
	state[i] = C.ST_MOVE
	has1[i] = 0
	has2[i] = 0
	stuck_t[i] = 0.0


func order_hold(i: int) -> void:
	state[i] = C.ST_HOLD
	des_x[i] = 0.0
	des_z[i] = 0.0
	dir_x[i] = 0.0
	dir_z[i] = 0.0
	vel_x[i] = 0.0
	vel_z[i] = 0.0


# ===========================================================================
# 每 tick
# ===========================================================================

## 推进一个逻辑 tick。dt 固定为 TICK_DT。
func tick() -> void:
	var t0: int = Time.get_ticks_usec()

	# --- 1) 流场（分摊重建，最多一个 tick 建一个）---
	var tf: int = Time.get_ticks_usec()
	_refresh_flow()
	flow_ms = float(Time.get_ticks_usec() - tf) / 1000.0

	# --- 1.5) 方向 pass（低频：每 DIR_EVERY tick 一次）---
	_dir_tick += 1
	if _dir_tick >= DIR_EVERY:
		_dir_tick = 0
		_update_dirs()

	# --- 2) 空间分区（计数排序，纯位运算）---
	var ts: int = Time.get_ticks_usec()
	space.build(pos_x, pos_z, count)
	spatial_ms = float(Time.get_ticks_usec() - ts) / 1000.0

	# --- 3) 转向 + 推挤（线程池分块）---
	var tt: int = Time.get_ticks_usec()
	_steer_all()
	steer_ms = float(Time.get_ticks_usec() - tt) / 1000.0

	# --- 4) 积分 + 贴地 + 滑动（主线程，写位置只在这里发生）---
	_integrate()

	tick_count += 1
	tick_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func _refresh_flow() -> void:
	var built_this_tick: bool = false
	for g in range(_groups.size()):
		if built_this_tick:
			break
		var gd: Dictionary = _groups[g]
		var fidx: int = int(gd["flow"])
		if fidx < 0:
			continue
		var f: Flow = _flows[fidx]
		var built: float = float(gd["built_at"])
		if built < 0.0 or (float(tick_count) * C.TICK_DT - built) < C.FLOW_TTL:
			continue
		f.build(float(gd["target_x"]), float(gd["target_z"]))
		gd["built_at"] = float(tick_count) * C.TICK_DT
		flow_ms = maxf(flow_ms, f.build_ms)
		built_this_tick = true


func _steer_all() -> void:
	var n: int = count
	if n <= 0:
		return
	# 块边界：每块至少 CHUNK_MIN，块数不超过线程数 × 2（再多就是调度开销）
	# 向上取整：1000 / 512 = 1（整数除）→ 永远只有 1 块，线程池白开。
	var want: int = (n + C.CHUNK_MIN - 1) / C.CHUNK_MIN
	var chunks: int = maxi(1, mini(_threads * 2, want))
	_chunk_n = chunks
	_chunk_from.resize(chunks)
	_chunk_to.resize(chunks)
	var base: int = n / chunks
	var rem: int = n - base * chunks
	var at: int = 0
	for c in range(chunks):
		var sz: int = base + (1 if c < rem else 0)
		_chunk_from[c] = at
		at += sz
		_chunk_to[c] = at

	if chunks <= 1 or _threads <= 1:
		thread_used = false
		for c in range(chunks):
			_steer_chunk(c)
		return
	thread_used = true
	var cb: Callable = Callable(self, "_steer_chunk")
	var gid: int = WorkerThreadPool.add_group_task(cb, chunks, -1, false, "crowd_steer")
	WorkerThreadPool.wait_for_group_task_completion(gid)


## 分块转向。**只写本块的 des_/push_**，只读 pos/vel/radius/state/space。
## 参数 idx 由线程池传入；块边界从 _chunk_from/_chunk_to 读。
func _steer_chunk(idx: int) -> void:
	var from: int = _chunk_from[idx]
	var to: int = _chunk_to[idx]
	var dt: float = C.TICK_DT
	var push_gain: float = C.PUSH_GAIN
	var sep_lim: float = C.SEP_MAX * dt
	# 只读数组取别名：Packed 数组是写时复制，**只读不写**就不会复制，省掉每格的成员查找。
	# 写数组（des_/push_）必须走成员访问，否则会 CoW 出一份 64KB 副本。
	var s_start: PackedInt32Array = space.cell_start
	var s_items: PackedInt32Array = space.cell_items
	var s_px: PackedFloat32Array = pos_x
	var s_pz: PackedFloat32Array = pos_z
	var s_r: PackedFloat32Array = radius
	var s_sp: PackedFloat32Array = speed
	var s_st: PackedInt32Array = state
	var s_team: PackedInt32Array = team
	var s_vx: PackedFloat32Array = vel_x
	var s_vz: PackedFloat32Array = vel_z
	var s_side: PackedByteArray = side

	for i in range(from, to):
		var px: float = s_px[i]
		var pz: float = s_pz[i]
		var ri: float = s_r[i]
		var st: int = s_st[i]
		var sp: float = s_sp[i]

		# --- 空中层：不吃流场、不吃推挤，直线去 slot ---
		if st == C.ST_AIR:
			var atx: float = goal_x[i] + slot_x[i]
			var atz: float = goal_z[i] + slot_z[i]
			var adx: float = atx - px
			var adz: float = atz - pz
			var ad: float = sqrt(adx * adx + adz * adz)
			if ad > 0.35:
				var ak: float = sp / maxf(ad, 0.001)
				des_x[i] = adx * ak
				des_z[i] = adz * ak
			else:
				des_x[i] = 0.0
				des_z[i] = 0.0
			push_x[i] = 0.0
			push_z[i] = 0.0
			continue

		# --- 静止 / 驻守 ---
		if st == C.ST_IDLE or st == C.ST_HOLD:
			des_x[i] = 0.0
			des_z[i] = 0.0
		else:
			# 方向已由 _update_dirs() 低频算好，这里只做乘法
			des_x[i] = dir_x[i] * sp
			des_z[i] = dir_z[i] * sp

		# --- 推挤（空闲/同向可推、快者少被推、Hold 抗推）---
		var ax: float = 0.0
		var az: float = 0.0
		var my_speed: float = sp
		var my_team: int = s_team[i]
		var wi: float = _push_weight(st)
		# 3×3 桶：位运算，无除法
		var cx: int = ((floori(px) + 128) >> 2) & 63
		var cz: int = ((floori(pz) + 128) >> 2) & 63
		# 邻居预算：最挤的桶会出现 30+ 人，全查一遍是浪费。
		# RTS 的手感只需要"最近十几个"，超出的一点推力看不出来。
		var budget: int = 16
		var dz_i: int = -1
		while dz_i <= 1 and budget > 0:
			var row: int = ((cz + dz_i) & 63) << 6
			var dx_i: int = -1
			while dx_i <= 1 and budget > 0:
				var b: int = row | ((cx + dx_i) & 63)
				var k: int = s_start[b]
				var k1: int = s_start[b + 1]
				while k < k1 and budget > 0:
					var j: int = s_items[k]
					k += 1
					budget -= 1
					if j == i:
						continue
					var jst: int = s_st[j]
					# 空中单位不参与地面碰撞
					if jst == C.ST_AIR:
						continue
					var ddx: float = px - s_px[j]
					var ddz: float = pz - s_pz[j]
					var d2: float = ddx * ddx + ddz * ddz
					var rr: float = ri + s_r[j]
					if d2 >= rr * rr:
						continue
					if d2 < 1e-8:
						# 完全重合：用相位散开，别让两个单位粘成一个
						var ang: float = anim_phase[i] * TAU
						ddx = cos(ang) * 0.01
						ddz = sin(ang) * 0.01
						d2 = 1e-4
					var dd: float = sqrt(d2)
					var overlap: float = rr - dd
					var inv: float = 1.0 / dd
					# 我承担的份额 = 我的可推程度 / 双方之和（空闲者多动、Hold 少动）
					var share: float = 0.5
					if s_team[j] == my_team:
						var wj: float = _push_weight(jst)
						share = wi / (wi + wj + 0.001)
						# 快者少被推：5m/s 对 2m/s → 快的只承担 46%
						var sj: float = s_sp[j]
						var ratio: float = 1.0 - my_speed / (my_speed + sj + 0.001)
						share *= clampf(ratio * 1.6, 0.25, 0.85)
					# 敌军：双方对推，各承担一半
					var disp: float = overlap * share * push_gain
					ax += ddx * inv * disp
					az += ddz * inv * disp

					# --- 互让（先读对方意图）---
					# 迎面接近时，两人往同侧躲会"跳探戈"（你左我也左），
					# 所以看 side 字节：已定的一侧说了算，都没定就按索引奇偶定死。
					# 这一步只加横向分量，不改前后 —— 让开但不减速。
					var rvx: float = s_vx[i] - s_vx[j]
					var rvz: float = s_vz[i] - s_vz[j]
					var closing: float = -(ddx * rvx + ddz * rvz) * inv
					if closing > 0.6 and dd < 1.6:
						var sd: int = s_side[i]
						var sd_j: int = s_side[j]
						if sd == 0:
							# 读对方：对方已经决定往哪边，我就往反方向
							if sd_j != 0:
								sd = 3 - sd_j
							else:
								sd = 1 if ((i ^ j) & 1) == 0 else 2
							side[i] = sd
						var sgn: float = 1.0 if sd == 1 else -1.0
						var lat: float = closing * 0.12 * sgn
						ax += (-ddz * inv) * lat
						az += (ddx * inv) * lat
				dx_i += 1
			dz_i += 1
		# 推力限幅（每 tick 位移上限 = SEP_MAX * dt）
		var pl2: float = ax * ax + az * az
		if pl2 > sep_lim * sep_lim:
			var pl: float = sqrt(pl2)
			ax = ax / pl * sep_lim
			az = az / pl * sep_lim
		push_x[i] = ax
		push_z[i] = az


## 可推程度：空闲 1.0、行军 0.8、驻守 0.15、其他 0.5。
func _push_weight(st: int) -> float:
	if st == C.ST_HOLD:
		return 0.15
	if st == C.ST_IDLE:
		return 1.0
	if st == C.ST_MOVE:
		return 0.8
	return 0.5


## 方向 pass：把"往哪走"从每 tick 的热循环里挪出来。
## 10000 单位 × 每 4 tick 一次 ≈ 2500 次/帧的采样，比每 tick 10000 次便宜 4 倍。
func _update_dirs() -> void:
	var n: int = count
	for i in range(n):
		var st: int = state[i]
		if st == C.ST_IDLE or st == C.ST_HOLD or st == C.ST_AIR:
			dir_x[i] = 0.0
			dir_z[i] = 0.0
			continue
		var d: Vector2 = _desired_dir(i, pos_x[i], pos_z[i], radius[i])
		dir_x[i] = d.x
		dir_z[i] = d.y


## 期望方向：流场 → 路径窗口 → 看路 → 避让。
func _desired_dir(i: int, px: float, pz: float, ri: float) -> Vector2:
	var g: int = group[i]
	var dir: Vector2 = Vector2.ZERO

	# --- 1) 路径窗口优先（只记两个拐点）---
	if has1[i] != 0:
		var tx: float = n1_x[i]
		var tz: float = n1_z[i]
		var dx: float = tx - px
		var dz: float = tz - pz
		if dx * dx + dz * dz < 0.36:
			# 到点了：推进窗口
			if has2[i] != 0:
				n1_x[i] = n2_x[i]
				n1_z[i] = n2_z[i]
				has2[i] = 0
			else:
				has1[i] = 0
				tx = goal_x[i] + slot_x[i]
				tz = goal_z[i] + slot_z[i]
				dx = tx - px
				dz = tz - pz
		var l: float = sqrt(dx * dx + dz * dz)
		if l > 0.01:
			dir = Vector2(dx / l, dz / l)

	# --- 2) 流场（军团行军）+ 阵型槽混合 ---
	if dir == Vector2.ZERO and g >= 0 and g < _groups.size():
		var fidx: int = int((_groups[g] as Dictionary)["flow"])
		if fidx >= 0:
			var f: Flow = _flows[fidx]
			dir = f.sample(px, pz)
			# 纯流场会把整队压成一条纵队（所有人都沿同一个方向）。
			# 越接近目标，"回自己的槽"的权重越大：远处 90% 跟流场，近处 85% 回槽，
			# 队伍就会从纵队自然展开成方阵。20m 是展开距离（≈ 一个方阵的宽度）。
			var gx: float = goal_x[i] + slot_x[i]
			var gz: float = goal_z[i] + slot_z[i]
			var ddx: float = gx - px
			var ddz: float = gz - pz
			var gd: float = sqrt(ddx * ddx + ddz * ddz)
			if gd > 0.01:
				var to_slot := Vector2(ddx / gd, ddz / gd)
				# **远处也要回槽**：只靠"接近才展开"不行——队伍早在 100m 外就被
				# 流场压成一条纵队了，到 50m 内已经没有宽度可以展开。
				# 这里给一个不随距离归零的底：45% 回槽（保宽度）+ 55% 流场（绕障碍），
				# 近处升到 95% 回槽（精确落位）。
				var k: float = 0.45 + 0.5 * clampf(1.0 - gd / 50.0, 0.0, 1.0)
				if k > 0.0:
					var mixed: Vector2 = dir * (1.0 - k * 0.95) + to_slot * (k * 0.95)
					var ml: float = mixed.length()
					if ml > 1e-4:
						dir = mixed / ml

	# --- 3) 无军团：直奔目标 ---
	if dir == Vector2.ZERO:
		var tx2: float = goal_x[i] + slot_x[i]
		var tz2: float = goal_z[i] + slot_z[i]
		var dx2: float = tx2 - px
		var dz2: float = tz2 - pz
		var l2: float = sqrt(dx2 * dx2 + dz2 * dz2)
		if l2 > 0.05:
			dir = Vector2(dx2 / l2, dz2 / l2)

	# --- 4) 看路：正前方不可走就扫空隙（不是试固定角度）---
	if dir != Vector2.ZERO:
		dir = _look_ahead(dir, px, pz, ri)

	# --- 5) 侧向意图：迎面时双方错开 ---
	return dir


## 看路：正前方通畅就直接走；否则在 ±80° 内按 7 档扫，找**连续可走段**取中点。
func _look_ahead(dir: Vector2, px: float, pz: float, ri: float) -> Vector2:
	var probe: float = C.LOOK_AHEAD + ri * 2.0
	if _walk_point(px + dir.x * probe, pz + dir.y * probe):
		return dir
	var base: float = atan2(dir.y, dir.x)
	var best: float = 0.0
	var best_score: float = -1e9
	var angles: Array = C.LOOK_ANGLES
	for k in range(angles.size()):
		var a: float = base + deg_to_rad(angles[k])
		var ca: float = cos(a)
		var sa: float = sin(a)
		if not _walk_point(px + ca * probe, pz + sa * probe):
			continue
		# 越接近原方向越好；夹角超过 80° 的候选直接降权
		var score: float = cos(deg_to_rad(angles[k]))
		if score > best_score:
			best_score = score
			best = a
	if best_score < -1e8:
		return dir
	return Vector2(cos(best), sin(best))


func _walk_point(x: float, z: float) -> bool:
	if x < -128.0 or x >= 128.0 or z < -128.0 or z >= 128.0:
		return false
	var cx: int = (floori(x) + 128) & 255
	var cz: int = (floori(z) + 128) & 255
	return walk[(cz << 8) | cx] != 0


## 积分：**全工程唯一写位置的地方**（人群层）。
## 顺序：期望速度 → 加速度 → 限速 → 推挤位移 → 墙推回 → 贴地。
func _integrate() -> void:
	var dt: float = C.TICK_DT
	var accel: float = 12.0
	for i in range(count):
		prev_x[i] = pos_x[i]
		prev_z[i] = pos_z[i]
		var st: int = state[i]
		if st == C.ST_HOLD:
			vel_x[i] = 0.0
			vel_z[i] = 0.0
			continue
		var ax: float = (des_x[i] - vel_x[i]) * accel
		var az: float = (des_z[i] - vel_z[i]) * accel
		var nvx: float = vel_x[i] + ax * dt
		var nvz: float = vel_z[i] + az * dt
		var l: float = sqrt(nvx * nvx + nvz * nvz)
		var cap: float = speed[i] * 1.35
		if l > cap:
			nvx = nvx / l * cap
			nvz = nvz / l * cap
		vel_x[i] = nvx
		vel_z[i] = nvz

		var nx: float = pos_x[i] + nvx * dt + push_x[i]
		var nz: float = pos_z[i] + nvz * dt + push_z[i]

		# 墙：不可走就分轴滑动（比"整体退回"自然得多）
		if not _walk_point(nx, nz):
			if _walk_point(nx, pos_z[i]):
				nz = pos_z[i]
				vel_z[i] *= 0.2
			elif _walk_point(pos_x[i], nz):
				nx = pos_x[i]
				vel_x[i] *= 0.2
			else:
				nx = pos_x[i]
				nz = pos_z[i]
				vel_x[i] *= 0.1
				vel_z[i] *= 0.1
				stuck_t[i] += dt
			# 卡住超过 1.2s：横向抖一下，别死顶墙
			if stuck_t[i] > 1.2:
				vel_x[i] += cos(anim_phase[i] * 6.283 + float(tick_count)) * 1.5
				vel_z[i] += sin(anim_phase[i] * 6.283 + float(tick_count)) * 1.5
				stuck_t[i] = 0.0
		else:
			stuck_t[i] = maxf(0.0, stuck_t[i] - dt)

		pos_x[i] = nx
		pos_z[i] = nz
		pos_y[i] = _height_at(nx, nz)

		# 侧向意图只保持 SIDE_HOLD 秒：过期清 0，下次再按当下局面决定
		if side[i] != 0:
			side_t[i] += dt
			if side_t[i] > C.SIDE_HOLD:
				side[i] = 0
				side_t[i] = 0.0

		# 朝向：位移方向；速度太小就保持
		var sl: float = nvx * nvx + nvz * nvz
		if sl > 0.04:
			var ty: float = atan2(nvx, nvz)
			var dy: float = ty - yaw[i]
			while dy > PI:
				dy -= TAU
			while dy < -PI:
				dy += TAU
			yaw[i] = yaw[i] + dy * 0.35

		# 到点：转入 IDLE（个体），军团单位保持 MOVE 但速度归零
		if st == C.ST_MOVE and group[i] < 0:
			var gx: float = goal_x[i] + slot_x[i]
			var gz: float = goal_z[i] + slot_z[i]
			if (gx - nx) * (gx - nx) + (gz - nz) * (gz - nz) < 0.16:
				state[i] = C.ST_IDLE


## 双线性采样高度（1m 表）
func _height_at(x: float, z: float) -> float:
	var fx: float = clampf(x + 128.0, 0.0, 254.999)
	var fz: float = clampf(z + 128.0, 0.0, 254.999)
	var x0: int = int(fx)
	var z0: int = int(fz)
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)
	var i00: int = (z0 << 8) | x0
	var i10: int = i00 + 1
	var i01: int = i00 + 256
	var i11: int = i01 + 1
	var a: float = height[i00] * (1.0 - tx) + height[i10] * tx
	var b: float = height[i01] * (1.0 - tx) + height[i11] * tx
	return a * (1.0 - tz) + b * tz


# ===========================================================================
# 查询 / 诊断
# ===========================================================================

## 渲染用：取插值后的位置（alpha 0..1）
func render_x(i: int, alpha: float) -> float:
	return prev_x[i] + (pos_x[i] - prev_x[i]) * alpha


func render_z(i: int, alpha: float) -> float:
	return prev_z[i] + (pos_z[i] - prev_z[i]) * alpha


func alive_count() -> int:
	return count


func stats() -> Dictionary:
	return {
		"count": count,
		"tick_ms": "%.2f" % tick_ms,
		"steer_ms": "%.2f" % steer_ms,
		"spatial_ms": "%.2f" % spatial_ms,
		"flow_ms": "%.2f" % flow_ms,
		"threads": _threads,
		"chunks": _chunk_n,
		"max_bucket": space.max_bucket_load,
	}


func _take_flow() -> int:
	for i in range(_flows.size()):
		var used: bool = false
		for gd in _groups:
			if int((gd as Dictionary)["flow"]) == i:
				used = true
				break
		if not used:
			return i
	return -1
