extends RefCounted
## **驻守调度** —— 决定"哪些点值得留人站岗"，以及每个点留几个。
##
## 玩家口径：「AI 系统学会运用驻守，占据据点获取资源、扩展占据资源点获取更多资源
## 和势力范围」。
##
## 为什么需要单独一层：原来的 AI 只有"出击"和"回防"两种状态，
## 兵要么全在基地、要么全在推进路上。真实 RTS 的势力范围是**靠驻守点撑起来的**：
##   · 据点（地图中心）：占 15 秒 → 200 金 + 80 木，是全图收益最高的单点；
##   · 外围来路（基地朝敌方 26–34m）：挡住第一波，给主力争取集结时间；
##   · 前线箭塔：塔自己会打，但需要 1 个人"看着"，否则被拆了没人报；
##   · 外围资源簇：农民去采的时候需要人护，否则野怪一刷就白给。
##
## 每个点给一个 `need`（需要几个人）和 `value`（值不值得为它分兵）。
## **只挑点，不下令** —— 下令由 `简单AI._manage_garrison()` 统一做，
## 这样兵力上限、空闲兵过滤、调度器节流全部只有一个出口。

## 据点距离上限（超过这个距离，派过去的人走回来要半分钟，不值）
const STRONGPOINT_MAX_DIST: float = 140.0
## 外围来路的距离（基地朝敌方方向）
const OUTPOST_DIST: float = 30.0
## 防御建筑算"前线"的最小离基地距离
const FRONT_LINE_MIN: float = 24.0


## 返回 [{pos: Vector3, kind: String, need: int, value: float}]，按 value 降序。
static func pick_points(faction, want: int = 2) -> Array:
	var out: Array = []
	if faction == null:
		return out
	var base: Vector3 = RtsWorld.base_center(faction)

	# ① 据点：收益最高，永远排第一
	var sp: Node = Game.strongpoint
	if sp != null and is_instance_valid(sp) and bool(sp.get("crate_active")):
		var spos: Vector3 = sp.call("crate_pos")
		if base.distance_to(spos) <= STRONGPOINT_MAX_DIST:
			out.append({
				"pos": spos, "kind": "strongpoint",
				"need": 3, "value": 100.0,
			})

	# ② 外围来路：基地朝敌方 30m，挡第一波
	var foe: Vector3 = _foe_dir_point(faction, base)
	if foe != Vector3.INF:
		var d: Vector3 = foe - base
		d.y = 0.0
		if d.length() > 1.0:
			var p: Vector3 = RtsWorld.walkable_pos(base + d.normalized() * OUTPOST_DIST)
			out.append({
				"pos": p, "kind": "approach",
				"need": 2, "value": 60.0,
			})

	# ③ 前线防御建筑：塔/前哨，各留 1 个人看着
	for b in faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		var bp: Vector3 = b.global_position
		if bp.distance_to(base) < FRONT_LINE_MIN:
			continue
		# 只挑防御类（有攻击力的建筑）：口径走 def 字段，不在这里硬编码 id
		if float(b.def.attack_damage) <= 0.0:
			continue
		out.append({
			"pos": bp, "kind": "tower",
			"need": 1, "value": 40.0,
		})

	out.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))
	if out.size() > want:
		out.resize(want)
	return out


## 敌方方向参考点：优先敌方基地，其次敌方最近建筑，最后用"基地背面的反方向"。
static func _foe_dir_point(faction, base: Vector3) -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_d: float = 1e20
	for f in Game.factions:
		if f == null or f == faction:
			continue
		if int(f.team) == 0:
			continue
		var c: Vector3 = RtsWorld.base_center(f)
		if c == Vector3.INF:
			continue
		var d: float = base.distance_to(c)
		if d < best_d and d > 1.0:
			best_d = d
			best = c
	return best
