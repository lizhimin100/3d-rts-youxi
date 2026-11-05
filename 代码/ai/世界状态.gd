extends RefCounted
## **世界状态层**（2C-13 §2）：每 tick 覆盖写一份结构化快照。
##
## 定位：**只读适配器**，不重构现有 `Game` / `RtsUnit` / `RtsBuilding` 查询。
## 谁要读世界，就读这一份，不要各自扫场景（口径不一致的根源）。
##
## 为什么是 Dictionary 而不是 Node/Resource：
##   ① 配置回归（`--script`）能直接 `load()` 调用，不需要场景；
##   ② 快照是"一次性的值"，不是"活的引用" —— 每 tick 用 `build()` 造新的，
##      旧的自然被丢弃，**结构上不可能累积**（这正是 §2 的回归断言）。
##
## 区域 id 规范（用户拍板，§3）：
##   区域 = 8×8 地块；地块 8 m（`地形.TILE_M`）→ 区域 64 m × 64 m。
##   前缀：Zj（自己的区域，**无序号**，唯一）/ Dr###（发现敌人的区域）/
##         Zy###（资源区域：金矿、树、四季树……）/ My###（盟友区域）。
##   三位序号按**发现顺序**自增，同一区域永不重编号（key = 前缀+格坐标）。
##   区域中心 = 8×8 地块中心（格坐标 × 64 + 32）。

# ---------------------------------------------------------------------------
# 区域
# ---------------------------------------------------------------------------

## 地块边长（米）—— 与 `代码/核心/地形.gd` 的 `TILE_M` 同值；这里**不能**去读
## 那个常量：世界状态要让配置回归在无场景条件下也能跑，只能自带一份并断言之。
const TILE_M: float = 8.0
## 一个区域的边长（地块数）= 8 → 64 m
const REGION_TILES: int = 8
const REGION_M: float = TILE_M * float(REGION_TILES)

const RK_SELF: String = "Zj"
const RK_ENEMY: String = "Dr"
const RK_RESOURCE: String = "Zy"
const RK_ALLY: String = "My"
const RK_NUMBERED: Array[String] = [RK_ENEMY, RK_RESOURCE, RK_ALLY]

## 快照的 18 个字段（任务书 §2 的字段表逐项展开；回归按这个列表检查完整性）。
const SNAPSHOT_FIELDS: Array[String] = [
	"金币", "木材", "人口上限", "人口占用", "在训人口",
	"现役兵力", "防守锁定", "已锁定兵力",
	"时间阶段", "昼夜", "威胁等级",
	"建筑", "敌方建筑", "区域",
	"最近30s受伤", "最近60s金收支", "最近60s木收支", "最近3波判定",
]


## 世界坐标 → 区域格坐标（floor 除法；负坐标也向下取整，与地形格一致）。
static func region_cell(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / REGION_M)), int(floor(pos.z / REGION_M)))


## 区域格坐标 → 区域中心（8×8 地块中心，y 恒 0：调用方要贴地自己取地形高度）。
static func region_center(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * REGION_M + REGION_M * 0.5, 0.0,
			float(cell.y) * REGION_M + REGION_M * 0.5)


## 区域 key（去重用）：前缀 + 格坐标。Zj 无序号，key 固定。
static func region_key(kind: String, cell: Vector2i) -> String:
	if kind == RK_SELF:
		return RK_SELF
	return "%s:%d:%d" % [kind, cell.x, cell.y]


## 编号 → id 字符串。Zj 无序号；其余三位补零。
static func region_id_of(kind: String, n: int) -> String:
	if kind == RK_SELF:
		return RK_SELF
	if n <= 0:
		return ""
	return "%s%03d" % [kind, n]


## 空注册表（三个前缀各自从 1 开始）。
static func region_registry() -> Dictionary:
	return {"ids": {}, "next": {RK_ENEMY: 1, RK_RESOURCE: 1, RK_ALLY: 1}}


## 给一个区域分配 id。**入参注册表不被修改**（返回新表），返回值：
##   {"reg": 新注册表, "id": "Dr001", "created": bool}
## 同一 (前缀,格坐标) 永远返回同一个 id —— 这是"同一区域不重复编号"的实现。
static func region_assign(reg: Dictionary, kind: String, cell: Vector2i) -> Dictionary:
	var ids: Dictionary = (reg.get("ids", {}) as Dictionary).duplicate()
	var nxt: Dictionary = (reg.get("next", {}) as Dictionary).duplicate()
	var key: String = region_key(kind, cell)
	if kind == RK_SELF:
		ids[key] = RK_SELF
		return {"reg": {"ids": ids, "next": nxt}, "id": RK_SELF, "created": false}
	if ids.has(key):
		return {"reg": {"ids": ids, "next": nxt}, "id": String(ids[key]), "created": false}
	var n: int = int(nxt.get(kind, 1))
	nxt[kind] = n + 1
	var id: String = region_id_of(kind, n)
	ids[key] = id
	return {"reg": {"ids": ids, "next": nxt}, "id": id, "created": true}


## id 格式校验（回归用；也保护调用方不要把 "Dr1" 这种写进目标对象）。
static func region_id_valid(id: String) -> bool:
	if id == RK_SELF:
		return true
	if id.length() != 5:
		return false
	var pre: String = id.substr(0, 2)
	if not RK_NUMBERED.has(pre):
		return false
	var digits: String = id.substr(2, 3)
	for i in range(3):
		var c: String = digits.substr(i, 1)
		if c < "0" or c > "9":
			return false
	return int(digits) >= 1


# ---------------------------------------------------------------------------
# 快照
# ---------------------------------------------------------------------------

## 造一份快照。**每次调用都返回全新的 Dictionary** —— 不允许在旧快照上增量写。
##
## `inp` 由 `简单AI._world_tick()` 采集（只做取值，不做判断）：
##   gold, wood, pop_cap, pop_used, pop_reserved, army_n,
##   defense_locked, troop_locked, phase, night, threat,
##   buildings: {id: 座数}, enemy_buildings: [{id,type,pos,hp}],
##   allies: [Vector3], resources: [{kind,pos}],
##   dmg_30s, gold_60s, wood_60s, verdicts: [String]
## 区域分配要跨 tick 记住编号 → 注册表由调用方持有并回传（`reg`）。
static func build(inp: Dictionary, reg: Dictionary) -> Dictionary:
	var cur: Dictionary = reg if not reg.is_empty() else region_registry()
	var regions: Array = []
	var seen: Dictionary = {}
	var own_pos: Vector3 = inp.get("own_base", Vector3.ZERO)
	# ① 自己的区域（唯一，无序号）
	var own_cell: Vector2i = region_cell(own_pos)
	var own: Dictionary = region_assign(cur, RK_SELF, own_cell)
	cur = own["reg"]
	regions.append(String(own["id"]))
	seen[String(own["id"])] = true
	# ② 敌方建筑 → Dr###
	var eb: Array = []
	for e in (inp.get("enemy_buildings", []) as Array):
		if not (e is Dictionary):
			continue
		var d: Dictionary = e as Dictionary
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		var ra: Dictionary = region_assign(cur, RK_ENEMY, region_cell(pos))
		cur = ra["reg"]
		var rid: String = String(ra["id"])
		if not seen.has(rid):
			seen[rid] = true
			regions.append(rid)
		eb.append({
			"id": int(d.get("id", 0)),
			"type": String(d.get("type", "")),
			"pos": pos,
			"hp": float(d.get("hp", 0.0)),
			"区域": rid,
		})
	# ③ 资源点 → Zy###（金矿 / 树 / 四季树，全都算可采集）
	for r in (inp.get("resources", []) as Array):
		if not (r is Dictionary):
			continue
		var d2: Dictionary = r as Dictionary
		var ra2: Dictionary = region_assign(cur, RK_RESOURCE,
				region_cell(d2.get("pos", Vector3.ZERO)))
		cur = ra2["reg"]
		var rid2: String = String(ra2["id"])
		if not seen.has(rid2):
			seen[rid2] = true
			regions.append(rid2)
	# ④ 盟友基地 → My###
	for a in (inp.get("allies", []) as Array):
		var ra3: Dictionary = region_assign(cur, RK_ALLY, region_cell(a as Vector3))
		cur = ra3["reg"]
		var rid3: String = String(ra3["id"])
		if not seen.has(rid3):
			seen[rid3] = true
			regions.append(rid3)
	return {
		"金币": int(inp.get("gold", 0)),
		"木材": int(inp.get("wood", 0)),
		"人口上限": int(inp.get("pop_cap", 0)),
		"人口占用": int(inp.get("pop_used", 0)),
		"在训人口": int(inp.get("pop_reserved", 0)),
		"现役兵力": int(inp.get("army_n", 0)),
		"防守锁定": int(inp.get("defense_locked", 0)),
		"已锁定兵力": int(inp.get("troop_locked", 0)),
		"时间阶段": String(inp.get("phase", "")),
		"昼夜": "夜晚" if bool(inp.get("night", false)) else "白天",
		"威胁等级": int(inp.get("threat", 0)),
		"建筑": (inp.get("buildings", {}) as Dictionary).duplicate(),
		"敌方建筑": eb,
		"区域": regions,
		"最近30s受伤": float(inp.get("dmg_30s", 0.0)),
		"最近60s金收支": float(inp.get("gold_60s", 0.0)),
		"最近60s木收支": float(inp.get("wood_60s", 0.0)),
		"最近3波判定": (inp.get("verdicts", []) as Array).duplicate(),
		# 注册表跟快照一起回传：调用方下一 tick 用它继续编号（不进 JSON）
		"_reg": cur,
	}


## 快照字段完整性（缺字段 → 返回缺失列表；回归用它断言 18 项一个不缺）。
static func missing_fields(snap: Dictionary) -> Array:
	var miss: Array = []
	for f in SNAPSHOT_FIELDS:
		if not snap.has(f):
			miss.append(f)
	return miss


## 取注册表（快照里带出来的那份）。
static func registry_of(snap: Dictionary) -> Dictionary:
	var r = snap.get("_reg", null)
	return r if r is Dictionary else region_registry()
