@tool
class_name 建筑网格
extends RefCounted
## **建筑建造网格**：建筑落点 / 朝向 / 占格 / 预览的**唯一入口**。
##
## 为什么要有这一层（老板原话："建筑的摆放没有一个统一的系统，方向杂乱"）：
##   · 以前玩家点哪、工地就落在哪，建筑和寻路格毫无关系 —— 同一排房子左一个
##     半格、右一个三分之一格，看着"乱"，寻路占格还会骑在格线上（`world_to_cell`
##     用 floori，格线左右的判定差一整格）；
##   · 现在**建筑占用的格必须和寻路格完全对齐**：2×2 正好盖满 4 格，3×3 正好
##     盖满 9 格。这样 `mark_footprint` / `is_buildable` / A* 看到的是同一批格子，
##     谁也不会再"骑格"。
##
## 和寻路共用同一套格：格子边长、格子原点全部读 `GridPathfinder`（不另设一套，
## 也不改它的 CELL）。所以地图尺寸 / 格子大小变了，这里自动跟着变。
##
## 静态类，不持有任何状态；没有关卡 / 寻路器时退化成"原地平面网格"，不会崩。

## 寻路格宽（唯一真相）：编辑器/游戏/地图生成都从这里取，别再写 1.0
const CELL: float = GridPathfinder.CELL

## 朝向吸附档位：90°。资产包（大本营 / 兵营 / 农场 / 铁匠铺 / 箭塔）全部是正交
## 设计的墙线，斜放会露出模型底面、墙面对不上，所以不做 45° / 任意角。
const YAW_STEP: float = PI * 0.5

## ★ **全项目唯一的建筑默认朝向**（模型正面朝镜头 / 世界 +Z，即 yaw = ±PI）。
##
## 用户原话："建筑朝向有问题：统一朝向，别管是地图生成还是农民建造，都默认一个角度"
## —— 所以地图生成、开局布阵、农民建造、AI 建造、编辑器放置**全部**读这一个常量，
## 不许再"按朝地图中心算"（那样 2 人图对角出生会得到 ±90°/±135°，四家各朝一边，
## 俯视看就是"随机朝向"）。
##
## 取 **-PI** 而不是 +PI：`snap_yaw()` 的结果落在 [-PI, PI)，两者视觉完全等价，
## 但写成 -PI 才能让"默认值 == 吸附后的值"，存档里也不会出现两种写法。
const DEFAULT_YAW: float = -PI


## 建筑默认朝向（唯一出口，调用方别再自己算）
static func default_yaw() -> float:
	return DEFAULT_YAW

## 偶数边长吸附到格线时**不加任何偏置**（这一点是踩过坑的）：
## 关卡 `_footprint_cell_rect` 用 `floori(min_x) / ceili(max_x)` 再各扩 1 格净空，
## 只有边界值恰好是整数时才左右对称；加 0.1mm 会让 4×4 的阻挡区变成 7×7 且
## 右/下多挡一格（实测）。CELL = 1.0、地图边长是整数时，格线坐标在 double 里是
## 精确值，floor 不会判错，所以宁可相信精确算术。

## 预览线离地高度（米）：贴地画会和地形 / 土路共面，闪成一片
const PREVIEW_LIFT: float = 0.05


# ===========================================================================
# 1. 落点吸附
# ===========================================================================

## 把任意世界坐标吸附到建筑网格。
##
## 规则（每轴独立）：
##   t = (w + half) / CELL                    ← 世界坐标换算成"连续的格坐标"
##   奇数边长：t' = floor(t) + 0.5            ← 中心落在**格中心**，3 格正好压 3 格
##   偶数边长：t' = round(t)                  ← 中心落在**格线**，2×2 正好盖满 4 格
##   x = t' * CELL - half                     ← 还原世界坐标
##   y = RtsWorld.ground(...)                 ← 仍然贴地
##
## 幂等：snap(snap(p)) == snap(p)。这是硬要求 —— 指令系统每帧都拿吸附结果再吸一次，
## 不幂等的话预览会左右抖。
static func snap_point(pos: Vector3, footprint: Vector2i) -> Vector3:
	var fp := Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	var cell: float = GridPathfinder.CELL
	var half: float = _grid_half(RtsWorld.pathfinder())
	var p := snap_point_in(pos, fp, half, cell)
	return RtsWorld.ground(p)


## **纯函数版**：不读 Game/RtsWorld，编辑器（@tool）与地图生成器都能直接用。
## half = 地图边长的一半，cell = 寻路格宽（当前恒为 1m）。
## 保留传入的 y；调用方自己按地形高度落 y。
static func snap_point_in(pos: Vector3, footprint: Vector2i, half: float, cell: float) -> Vector3:
	var fp := Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	var x: float = _snap_axis(pos.x, fp.x, half, maxf(cell, 0.01))
	var z: float = _snap_axis(pos.z, fp.y, half, maxf(cell, 0.01))
	return Vector3(x, pos.y, z)


## 判断一个落点是否已经压在网格锚点上（编辑器校验/自检用）
static func is_snapped(pos: Vector3, footprint: Vector2i, half: float, cell: float) -> bool:
	var p := snap_point_in(pos, footprint, half, cell)
	return absf(p.x - pos.x) < 0.001 and absf(p.z - pos.z) < 0.001


## 单轴吸附（x / z 共用；n = 该轴的格数）
static func _snap_axis(w: float, n: int, half: float, cell: float) -> float:
	var t: float = (w + half) / cell
	if n % 2 == 0:
		# 偶数：最近的一条格线（round 比 floor 更跟手：点在格线右边就落右边，不整格跳）
		var k: float = roundf(t)
		return k * cell - half
	# 奇数 / 1×1：最近格子的中心。格心在 k+0.5，floor + 0.5 就是最近的那个中心。
	var kc: float = floorf(t)
	return (kc + 0.5) * cell - half


## 建筑网格的"半边长"（= 关卡 world_size / 2）。
## 由寻路器反算而不是直接读关卡字段：格子原点只认寻路器，避免两份真相。
static func _grid_half(pf: GridPathfinder) -> float:
	if pf == null:
		return 0.0
	return GridPathfinder.CELL * 0.5 - pf.cell_to_world(Vector2i.ZERO).x


# ===========================================================================
# 2. 朝向吸附
# ===========================================================================

## 把朝向吸到 90° 的整数倍（返回 [-PI, PI)）。
##
## 为什么是 90°：资产是正交设计的（墙线 / 屋檐 / 底面都按 0° 建的），
## 斜放会破面、露底、门洞对不上；而且 90° 的整数倍下占格和朝向完全无关，
## 不需要额外的旋转占格计算。
static func snap_yaw(yaw: float) -> float:
	return wrapf(roundf(yaw / YAW_STEP) * YAW_STEP, -PI, PI)


# ===========================================================================
# 3. 占格查询
# ===========================================================================

## 建筑落点占用的格子（顺序 z 优先，与寻路器 mark_blocked_rect 完全一致）。
## 没有寻路器时返回空数组（调用方按"无边可判"处理）。
static func cells_of(center: Vector3, footprint: Vector2i) -> Array[Vector2i]:
	var pf: GridPathfinder = RtsWorld.pathfinder()
	if pf == null:
		return []
	return cells_of_in(center, footprint, _grid_half(pf), GridPathfinder.CELL)


## **纯函数版占格查询**：格子坐标与寻路器完全同一套（z*格数+x）。
static func cells_of_in(center: Vector3, footprint: Vector2i, half: float, cell: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var fp := Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	var c := cell_of_point(center, half, cell)
	var hx: int = fp.x / 2
	var hz: int = fp.y / 2
	for dz in range(-hz, hz + fp.y % 2):
		for dx in range(-hx, hx + fp.x % 2):
			out.append(Vector2i(c.x + dx, c.y + dz))
	return out


## 世界点 → 1m 寻路格（和 GridPathfinder.world_to_cell 同一公式）
static func cell_of_point(pos: Vector3, half: float, cell: float) -> Vector2i:
	var c: float = maxf(cell, 0.01)
	return Vector2i(floori((pos.x + half) / c), floori((pos.z + half) / c))


## 格子中心的世界坐标（y 保留 0，由调用方贴地）
static func cell_center_in(c: Vector2i, half: float, cell: float) -> Vector3:
	var s: float = maxf(cell, 0.01)
	return Vector3((float(c.x) + 0.5) * s - half, 0.0, (float(c.y) + 0.5) * s - half)


## 朝向是否已经吸到 90° 档（校验/自检用）
static func yaw_is_snapped(yaw: float) -> bool:
	return absf(angle_difference(yaw, snap_yaw(yaw))) < 0.001


## 这个落点能不能建（**只读查询**，不扣钱、不落工地）。
## 通行判定完全走寻路器的 `is_cell_walkable`，不在这里另立一套；
## 关卡在的话再顺带问一次 `is_buildable`（它还管地形高度极差）。
static func can_place(center: Vector3, footprint: Vector2i) -> bool:
	var pf: GridPathfinder = RtsWorld.pathfinder()
	if pf == null:
		# 与 RtsWorld.is_buildable 的降级口径一致：无关卡 = 平地，处处可建
		return true
	var cells: Array[Vector2i] = cells_of(center, footprint)
	if cells.is_empty():
		return false
	for c in cells:
		if not pf.is_cell_walkable(c):
			return false
	var lv: Node3D = RtsWorld.level()
	if lv != null and lv.has_method("is_buildable"):
		return bool(lv.call("is_buildable", center, footprint))
	return true


# ===========================================================================
# 4. 建造预览网格
# ===========================================================================

## 画出建筑占用的那几格（绿色 = 可建 / 红色 = 不可建）。
##
## 形态：每格一圈地面线框（逐角贴地抬 0.05m，防 z-fighting）+ 占地四角四根
## 0.5m 高的立柱，远看也能看出"这块地是几乘几"。
## 返回的节点直接用**世界坐标**建面（`top_level = true`），调用方 add_child 即可，
## 不用关心父节点有没有位移；要跟着鼠标走就整体 `queue_free()` 后重建。
static func make_grid_preview(center: Vector3, footprint: Vector2i, ok: bool) -> MeshInstance3D:
	var pf: GridPathfinder = RtsWorld.pathfinder()
	var half: float = _grid_half(pf)
	return make_grid_preview_custom(center, footprint, ok, half, GridPathfinder.CELL,
		func(p: Vector3) -> Vector3: return RtsWorld.ground(p))


## **纯函数版预览**：ground 是 Callable(Vector3)->Vector3，用来把线贴到地面。
## 编辑器传 MapDef.height_at 的包装，游戏传 RtsWorld.ground —— 同一份绘制逻辑。
static func make_grid_preview_custom(center: Vector3, footprint: Vector2i, ok: bool,
		half: float, cell: float, ground: Callable) -> MeshInstance3D:
	var fp := Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	var cells: Array[Vector2i] = cells_of_in(center, fp, half, cell)
	var base: Vector3 = ground.call(center) if ground.is_valid() else center

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var has_mesh: bool = not cells.is_empty()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in cells:
		var cc: Vector3 = cell_center_in(c, half, cell)
		var half_cell: float = maxf(cell, 0.01) * 0.5
		lo.x = minf(lo.x, cc.x - half_cell)
		lo.y = minf(lo.y, cc.z - half_cell)
		hi.x = maxf(hi.x, cc.x + half_cell)
		hi.y = maxf(hi.y, cc.z + half_cell)
		var corners: Array[Vector3] = [
			Vector3(cc.x - half_cell, 0.0, cc.z - half_cell),
			Vector3(cc.x + half_cell, 0.0, cc.z - half_cell),
			Vector3(cc.x + half_cell, 0.0, cc.z + half_cell),
			Vector3(cc.x - half_cell, 0.0, cc.z + half_cell),
		]
		for i in 4:
			_line_ground(st, corners[i], corners[(i + 1) % 4], base, ground)
	# 占地四角的短立柱（0.5m）：线框贴地时容易和地形花纹糊在一起，立起来更好认
	if has_mesh:
		for sx in [lo.x, hi.x]:
			for sz in [lo.y, hi.y]:
				_post(st, Vector3(sx, 0.0, sz), 0.5, base, ground)

	var mi := MeshInstance3D.new()
	mi.name = "建筑网格预览"
	if has_mesh:
		mi.mesh = st.commit()
	mi.material_override = _preview_material(ok)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	mi.position = base
	return mi


## 预览材质：unshaded 线框，绿 = 可建 / 红 = 不可建
static func _preview_material(ok: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.42, 1.0, 0.55, 0.92) if ok else Color(1.0, 0.36, 0.30, 0.92)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	return m


## 一条贴地线（两端各自取地形高度 + PREVIEW_LIFT）。顶点相对 base，便于整体搬运。
static func _line_ground(st: SurfaceTool, a: Vector3, b: Vector3, base: Vector3,
		ground: Callable) -> void:
	var pa: Vector3 = ground.call(a) + Vector3.UP * PREVIEW_LIFT
	var pb: Vector3 = ground.call(b) + Vector3.UP * PREVIEW_LIFT
	st.add_vertex(pa - base)
	st.add_vertex(pb - base)


## 一根竖直立柱（贴地起步，高 height）。不能走 _line_ground：
## 贴地函数只保留 xz、y 直接取地形高度，加 UP 偏移会被抹掉。
static func _post(st: SurfaceTool, at: Vector3, height: float, base: Vector3,
		ground: Callable) -> void:
	var foot: Vector3 = ground.call(at) + Vector3.UP * PREVIEW_LIFT
	st.add_vertex(foot - base)
	st.add_vertex(foot + Vector3.UP * height - base)