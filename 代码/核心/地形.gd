@tool
class_name RtsTerrain
extends Node3D
## **地形**：程序化地面，**参数化 C¹ 双三次 Hermite 曲面** + 顶点色。
##
## 设计要点：
##   - 每格是一张**解析曲面片** S(u,v)（详见"曲面"一节公式），格与格共享边曲线与
##     切向量 → 格间 C¹ 连续，坡面是曲面而不是折线；
##   - 法线由 S 的偏导解析求出（不是 generate_normals、也不是逐面几何法线），
##     与渲染网格共用同一组参数点，逐顶点平滑；
##   - **曲率驱动自适应细分**：按二阶导估出的弦高误差选每格 (nu,nv)，
##     平坦区 1×1（2 面），崖壁沿陡的方向各向异性加密到 4~6 段；
##   - **height_at 与渲染网格同源**：两者都调 `_patch()`，网格顶点就是曲面采样点，
##     单位贴地/镜头贴地/拾取/放置吸附不会浮空或陷地；
##   - 顶点色按"高度分层 + 坡度"给草/土/岩；可走性不在这里决定。
##
## 坐标约定：地图以原点为中心，边长 size，格子 cell = size / resolution。
## 每个格子 (x,z) 覆盖 [x*cell-half, (x+1)*cell-half) × [z*cell-half, (z+1)*cell-half)，
## 参数 (u,v) 与世界的映射：x = -half + (x+u)*cell，z = -half + (z+v)*cell。

## 地形细分（每边格子数）
var resolution: int = 58
## 地图边长（米）
var size: float = 116.0
## 高度场，(resolution+1)^2
var heights: PackedFloat32Array = PackedFloat32Array()
## 水面节点（没有水潭时为 null）
var water: MeshInstance3D = null

## 台地地标（由 RtsLevel 在 build 前写入；着色与崖壁雕刻用）。
## 不能让 地形.gd 去读 MapGenerator：这一层只拿高度场，地标是"语义补充"。
var plateau_center: Vector2 = Vector2.ZERO
var plateau_radius: float = 0.0
var plateau_top: float = 0.0
## 坡道方位角（弧度）。雕刻崖壁时避开这些角度，保证坡道仍是 30° 的顺坡。
var ramp_angles: PackedFloat32Array = PackedFloat32Array()
## 营地中心点（每一个出生点）。营地半径内压暗一点、干裂纹少一点，
## 读起来是"被踩实的营地地面"，而不是"贴了一张土斑"。
var base_points: PackedVector2Array = PackedVector2Array()

## ── 地块材质（魔兽争霸 3 口径）──────────────────────────────────────────
## 材质存在**共享格点**上：1 texel = 1 个格点 = 8m，值 0=草 255=泥。
## 边长 mat_cells+1 个格点；mat_cells = 0 表示没数据（整图当草地）。
## 由关卡在 build() 之前写入（见 地图生成._paint_tiles）。
var mat_nodes: PackedByteArray = PackedByteArray()
var mat_cells: int = 0
## 生态 id（temperate/arid/snow/volcanic/swamp）：决定地形材质的 biome 换色参数。
## 和地块材质走同一条主线 —— 编辑器与游戏都从这里取色，不再各自画一套。
var biome: String = "temperate"
## 运行时生成的 R8 贴图（shader 里 texelFetch 逐格点取值）
var mat_map: ImageTexture = null

## 判定"陡面"的角度（度）——统计与着色用
const STEEP_FACE_DEG: float = 45.0

## 曲面弦高容许误差（米）：网格三角面相对解析曲面的最大垂向偏差预算。
## 细分级别的选择就是为了把这个误差压到它以下。
## 0.05 会顶到 13 万面 —— 手游相机最远约 34m，1 米在屏上才 ~20px，
## 5cm 的弦高连一个像素都占不到。0.10 是"看不出来 + 面数能扛"的平衡点。
## 编辑器笔刷拖动中会临时传更粗的值（见 视口.gd 的 rebuild_terrain），松手再补精。
const SURFACE_TOL: float = 0.10
## 单轴最大分段数（6×6 = 72 面/格，只在真正陡的崖面出现）
const SUBDIV_MAX_SEG: int = 6
## 细分候选 (nu,nv)，按面数从少到多排列。
## 各向异性项是关键：直纹崖壁只沿"陡"的那个方向加密，比 4×4 省 4 倍面。
const SUBDIV_CANDIDATES := [
	Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1), Vector2i(1, 3), Vector2i(3, 1),
	Vector2i(2, 2), Vector2i(1, 4), Vector2i(4, 1), Vector2i(2, 3), Vector2i(3, 2),
	Vector2i(1, 6), Vector2i(6, 1), Vector2i(2, 4), Vector2i(4, 2), Vector2i(3, 3),
	Vector2i(2, 6), Vector2i(6, 2), Vector2i(3, 4), Vector2i(4, 3), Vector2i(4, 4),
	Vector2i(3, 6), Vector2i(6, 3), Vector2i(4, 6), Vector2i(6, 4), Vector2i(6, 6),
]

var _cell: float = 2.0
var _half: float = 58.0
var _mesh_instance: MeshInstance3D = null
## 远景山脊（纯视觉，不参与 height_at / 可走性 / 镜头保护）
var _far_ridges: MeshInstance3D = null
## 边界裙边（四周向下的断崖墙）
var _skirt: MeshInstance3D = null

## 每格中心顶点高度（米）。仅细分格有效；-1e20 = 未细分。
var _cell_center_h: PackedFloat32Array = PackedFloat32Array()
## 每格是否细分（1=是）
var _cell_subdiv: PackedByteArray = PackedByteArray()
## 每格的参数分段数 (nu 沿 x / u，nv 沿 z / v)
var _cell_nu: PackedByteArray = PackedByteArray()
var _cell_nv: PackedByteArray = PackedByteArray()

## 节点切向量场（按节点定义 → 相邻格共享，保证 C¹）
var _tan_u: PackedFloat32Array = PackedFloat32Array()
var _tan_v: PackedFloat32Array = PackedFloat32Array()
var _tan_uv: PackedFloat32Array = PackedFloat32Array()
## 弦高估计的复用缓冲（避免每格每候选都 new 一个数组）
var _sag_buf: PackedFloat32Array = PackedFloat32Array()
## 每个节点 |4h - 四邻|（离散拉普拉斯，曲率指标）
var _lap: PackedFloat32Array = PackedFloat32Array()

## 当前生效的弦高误差预算（米）。build() 的 p_tol 参数落到这里。
var _tol: float = SURFACE_TOL

var _height_min: float = 0.0
var _height_max: float = 0.0
var _tri_count: int = 0
var _steep_tri_count: int = 0
var _max_slope_deg: float = 0.0
var _subdiv_count: int = 0


## 用高度场建地形网格（签名保持不变；p_tol 是可选加参，旧调用一行不用改）
## p_tol = 解析曲面被三角网格逼近时允许的**最大弦高误差（米）**。
##   · 游戏内稳态：SURFACE_TOL（精细）
##   · 编辑器笔刷拖动中：传一个粗值（如 0.35）—— 笔刷要跟手，精度等松手再补
## 关键：height_at() 走解析求值，**不依赖网格精度**，
##       所以粗网格期间放置/拾取依然准，不会因为降精度而漂。
func build(p_size: float, p_resolution: int, p_heights: PackedFloat32Array,
		p_far_ridges: bool = true, p_tol: float = SURFACE_TOL) -> void:
	size = p_size
	resolution = maxi(4, p_resolution)
	_tol = clampf(p_tol, 0.02, 2.0)
	# 复制一份再雕刻：MapData.heights 还要给地图生成自检/统计用，
	# 不能因为地形层加了岩架/山脊就把生成侧的数据改脏。
	heights = p_heights.duplicate()
	var need: int = (resolution + 1) * (resolution + 1)
	if heights.size() != need:
		# 尺寸不匹配就补零/截断，宁可有块平地也不要越界崩（调用方本应保证匹配）
		heights.resize(need)
	_cell = size / float(resolution)
	_half = size * 0.5

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "地形网格"
		add_child(_mesh_instance)

	# ★ 真实大图才做"手工地貌"：合成夹具（128m）的高度必须保持原样，
	#   否则 30° 坡道/60° 崖壁的断言会被这些装饰性起伏干扰。
	if size >= 150.0 and plateau_radius > 0.0:
		_sculpt_mesa_rim()
		_sculpt_outer_rim()

	# 边缘压平：让"边界断崖"的顶边是直线，而不是跟着地形起伏长出一圈狗牙
	_flatten_border(3)
	_compute_height_bounds()
	_prepare_tangents()
	_prepare_cells()
	_build_mesh()
	_build_skirt()
	_build_mat_map()
	# 材质：优先用美术侧的地形着色器，没有就退化成顶点色标准材质
	_mesh_instance.material_override = _make_material()
	# 边界裙边和地形共用同一份材质：裙边是竖直面，走着色器的"崖壁"分支，
	# 岩色/两阶光/雾都和地形一致 —— 以前它是另一套 StandardMaterial3D，
	# 边界那圈看起来像"另一块世界"。
	if _skirt != null and is_instance_valid(_skirt):
		_skirt.material_override = _mesh_instance.material_override

	# 远景山脊默认开（游戏里需要它堵住"地图外看见天空"）；地图编辑器里关掉，
	# 免得一圈几十米高的山挡在编辑区旁边。
	if size >= 150.0 and p_far_ridges:
		_build_far_ridges()


# ===========================================================================
# 建网格
# ===========================================================================

## 台地崖壁雕刻：只动崖壁本体，顶面（可建区）保持平整。
##
## 为什么需要：地图生成器给的台地是一个解析圆环，112 分辨率下崖壁只有 3~4 列格子，
## 平面着色后就是一圈"竖条纹"。这里沿崖壁叠一层**角向 + 径向**的低频噪声，
## 让崖面出现凸台/凹槽/碎裂的岩架；顶面边缘再做 0.4m 级的啃边，
## 从俯视角看就不会是"盖了个蛋糕"。
##
## 不碰坡道：坡道方位 ±0.34rad 内的顶点一律跳过，30° 顺坡原样保留。
func _sculpt_mesa_rim() -> void:
	var row: int = resolution + 1
	var half: float = size * 0.5
	var top_edge: float = maxf(4.0, plateau_radius - 4.5)
	var outer_r: float = plateau_radius + 2.8
	for gz in range(row):
		for gx in range(row):
			var wx: float = -half + float(gx) * _cell
			var wz: float = -half + float(gz) * _cell
			var r: float = Vector2(wx, wz).length()
			if r < top_edge - 1.4 or r > outer_r:
				continue
			var ang: float = atan2(wz, wx)
			if _near_ramp_angle(ang, 0.34):
				continue
			var i: int = gz * row + gx
			var h: float = heights[i]
			# 陡崖本体：从坡脚上方 0.6m 到顶面下方 0.25m
			if h > plateau_top - 0.25:
				# 顶面"啃边"：只在最外 1.4m 的一圈，幅度 0.75m，
				# 不会影响台地内部的 4×4 建造（那圈半径 19.5，建造点通常在 8~14m）
				if r > top_edge - 1.2 and r < top_edge + 1.2:
					# ★ 必须是**带限解析函数**（波长 ~9~10m，跨 5 格）：
					#   旧版用逐顶点哈希 → 格级白噪声，C¹ 曲面会被逼出格内振铃，
					#   细分面数和法线噪声都会炸掉。啃边只要"沿边长短不一"，不需要白噪声。
					var bite: float = (sin(ang * 13.0 + r * 1.1) * 0.60 \
						+ sin(ang * 7.0 - r * 0.70) * 0.40) * 0.75
					heights[i] = clampf(h + bite, plateau_top - 1.0, plateau_top + 0.30)
				continue
			if h < -1.2:
				continue
			var body: float = smoothstep(-0.4, 0.9, h)
			var w: float = smoothstep(top_edge - 1.0, top_edge + 1.2, r) \
				* (1.0 - smoothstep(plateau_radius + 0.6, outer_r, r))
			if w <= 0.001 or body <= 0.001:
				continue
			# 三层噪声叠加：大台阶 + 岩架 + 碎石
			var n: float = sin(ang * 9.0 + r * 0.55) * 0.55 \
				+ sin(ang * 17.0 - r * 1.15) * 0.28 \
				+ sin(ang * 5.0 + r * 0.9) * 0.37
			heights[i] = h + n * 0.95 * w * body


## 外圈山脊雕刻：打破"等高灰色浴缸壁"。
##
## 只改切比雪夫距离 82m 以外的山脊（可行走区最外只到 95m，且被 EDGE_MARGIN 封死），
## 做法是「脊线起伏 + 3 个断口 + 高频锯齿」。断口最低压到原高度的 ~40%，
## 但外圈边界依旧不可走，单位不可能借断口走出世界。
func _sculpt_outer_rim() -> void:
	var row: int = resolution + 1
	var half: float = size * 0.5
	for gz in range(row):
		for gx in range(row):
			var wx: float = -half + float(gx) * _cell
			var wz: float = -half + float(gz) * _cell
			var e: float = maxf(absf(wx), absf(wz))
			if e < 82.0:
				continue
			var i: int = gz * row + gx
			var base: float = heights[i]
			if base < 1.2:
				continue
			var ang: float = atan2(wz, wx)
			var fade: float = smoothstep(82.0, 89.0, e)
			# 脊线起伏：3/7/13 次谐波，肉眼看是连绵山脊而不是一圈等高墙
			var ridge: float = 0.80 + 0.24 * sin(ang * 3.0 + 0.8) \
				+ 0.12 * sin(ang * 7.0 + 2.3) + 0.06 * sin(ang * 13.0 + 4.1)
			var notch: float = 1.0
			notch -= 0.56 * (1.0 - smoothstep(0.0, 0.090, absf(_angle_delta(ang, -1.95))))
			notch -= 0.46 * (1.0 - smoothstep(0.0, 0.078, absf(_angle_delta(ang, -0.72))))
			notch -= 0.30 * (1.0 - smoothstep(0.0, 0.130, absf(_angle_delta(ang, 2.45))))
			notch = clampf(notch, 0.34, 1.0)
			var jag: float = sin(ang * 23.0 + e * 0.35) * 1.15 \
				+ sin(ang * 41.0 - e * 0.62) * 0.65
			var h: float = base * lerpf(1.0, ridge * notch, fade)
			h += jag * fade * smoothstep(6.0, 14.0, base)
			heights[i] = maxf(h, -2.0)


## 角度是否落在坡道保护扇区内
func _near_ramp_angle(ang: float, half_width: float) -> bool:
	for ra in ramp_angles:
		if absf(_angle_delta(ang, float(ra))) <= half_width:
			return true
	return false


func _angle_delta(a: float, b: float) -> float:
	return fposmod(a - b + PI, TAU) - PI


## 扫描高度场极值（给配色与统计用）
func _compute_height_bounds() -> void:
	_height_min = 0.0
	_height_max = 0.0
	var any: bool = false
	for i in range(heights.size()):
		var h: float = heights[i]
		if not any:
			_height_min = h
			_height_max = h
			any = true
		else:
			_height_min = minf(_height_min, h)
			_height_max = maxf(_height_max, h)
	if not any:
		_height_min = 0.0
		_height_max = 0.0


# ===========================================================================
# 曲面：参数化双三次 Hermite 曲面片（Catmull-Rom 切向）
# ===========================================================================
##
## 每格一张 S(u,v)，(u,v) ∈ [0,1]²，映射 x = -half+(x+u)·cell，z = -half+(z+v)·cell：
##
##     S(u,v) = Bu(u) · A · Bv(v)ᵀ
##     Bu(t)  = ( H00(t), H10(t), H01(t), H11(t) )
##     H00 = 2t³-3t²+1   H10 = t³-2t²+t   H01 = -2t³+3t²   H11 = t³-t²
##
##     A = ⎡ h00   m_v00  h01   m_v01 ⎤      h_ij = 四角格点高度
##         ⎢ m_u00 m_uv00 m_u01 m_uv01⎥      m_u, m_v = 一阶切向
##         ⎢ h10   m_v10  h11   m_v11 ⎥      m_uv    = 混合偏导
##         ⎣ m_u10 m_uv10 m_u11 m_uv11⎦
##
## 切向**按节点**定义（与哪一格来求值无关），所以相邻格在公共边上不仅高度相同，
## 一阶偏导也相同 → 格间 C¹：
##
##     m_u  = ( h(gx+1,gz)   - h(gx-1,gz)   ) / 2
##     m_v  = ( h(gx,gz+1)   - h(gx,gz-1)   ) / 2
##     m_uv = ( h(+1,+1) - h(+1,-1) - h(-1,+1) + h(-1,-1) ) / 4
##
## 选 Catmull-Rom 而不是普通双三次 Bezier 的理由：它**插值**格点（网格顶点必须
## 等于高度场取样值，编辑器笔刷所见即所得），且对一次/三次函数精确复现——
## 平地与等坡坡面误差为 0，不会在缓坡上凭空鼓包。它是 C¹ 张量积 Hermite 里
## 唯一"既插值又只依赖 4×4 邻域"的取法。
##
## 边界 ghost point 用**线性外推** h(-1) = 2h(0) - h(1)：
##   夹紧（h(-1)=h(0)）会把边界坡度砍半、镜像（h(-1)=h(1)）会让边界切线直接为 0，
##   两种都会让地图边缘"塌成平唇"；外推保持单侧坡度不变，边缘既不翘也不塌。

## 预计算节点切向量场（必须在 heights 最终确定之后调用）
func _prepare_tangents() -> void:
	var row: int = resolution + 1
	var n: int = row * row
	_tan_u.resize(n)
	_tan_v.resize(n)
	_tan_uv.resize(n)
	_lap.resize(n)
	for gz in range(row):
		for gx in range(row):
			var i: int = gz * row + gx
			_lap[i] = absf(4.0 * _h_ext(gx, gz) - _h_ext(gx - 1, gz) - _h_ext(gx + 1, gz)
				- _h_ext(gx, gz - 1) - _h_ext(gx, gz + 1))
			_tan_u[i] = (_h_ext(gx + 1, gz) - _h_ext(gx - 1, gz)) * 0.5
			_tan_v[i] = (_h_ext(gx, gz + 1) - _h_ext(gx, gz - 1)) * 0.5
			_tan_uv[i] = (_h_ext(gx + 1, gz + 1) - _h_ext(gx + 1, gz - 1)
				- _h_ext(gx - 1, gz + 1) + _h_ext(gx - 1, gz - 1)) * 0.25



## 取格点高度；越界用线性外推（ghost point）
func _h_ext(gx: int, gz: int) -> float:
	var row: int = resolution + 1
	var ax: int = clampi(gx, 0, resolution)
	var az: int = clampi(gz, 0, resolution)
	var h: float = heights[az * row + ax]
	if gx != ax:
		h += (h - heights[az * row + ax + (1 if gx < 0 else -1)]) * float(absi(gx - ax))
	if gz != az:
		h += (h - heights[(az + (1 if gz < 0 else -1)) * row + ax]) * float(absi(gz - az))
	return h


## Hermite 基与其导数
func _hermite(t: float) -> Vector4:
	var t2: float = t * t
	var t3: float = t2 * t
	return Vector4(2.0 * t3 - 3.0 * t2 + 1.0, t3 - 2.0 * t2 + t,
		-2.0 * t3 + 3.0 * t2, t3 - t2)


func _hermite_d(t: float) -> Vector4:
	var t2: float = t * t
	return Vector4(6.0 * t2 - 6.0 * t, 3.0 * t2 - 4.0 * t + 1.0,
		-6.0 * t2 + 6.0 * t, 3.0 * t2 - 2.0 * t)


## 曲面片求值：返回 (高度, ∂h/∂u, ∂h/∂v)
func _patch(cx: int, cz: int, u: float, v: float) -> Vector3:
	var row: int = resolution + 1
	var i00: int = cz * row + cx
	var i10: int = i00 + 1
	var i01: int = i00 + row
	var i11: int = i01 + 1
	# A 的 16 个控制量（行 = u 的 值0/切0/值1/切1，列 = v 同理）
	var a00: float = heights[i00]
	var a01: float = _tan_v[i00]
	var a02: float = heights[i01]
	var a03: float = _tan_v[i01]
	var a10: float = _tan_u[i00]
	var a11: float = _tan_uv[i00]
	var a12: float = _tan_u[i01]
	var a13: float = _tan_uv[i01]
	var a20: float = heights[i10]
	var a21: float = _tan_v[i10]
	var a22: float = heights[i11]
	var a23: float = _tan_v[i11]
	var a30: float = _tan_u[i10]
	var a31: float = _tan_uv[i10]
	var a32: float = _tan_u[i11]
	var a33: float = _tan_uv[i11]

	var bu := _hermite(u)
	var bv := _hermite(v)
	# row_val[r] = Σ_j A[r][j]·Bv[j] → 高度的 u 控制值
	var r0: float = a00 * bv.x + a01 * bv.y + a02 * bv.z + a03 * bv.w
	var r1: float = a10 * bv.x + a11 * bv.y + a12 * bv.z + a13 * bv.w
	var r2: float = a20 * bv.x + a21 * bv.y + a22 * bv.z + a23 * bv.w
	var r3: float = a30 * bv.x + a31 * bv.y + a32 * bv.z + a33 * bv.w
	var h: float = bu.x * r0 + bu.y * r1 + bu.z * r2 + bu.w * r3

	# ∂/∂u：对 u 基求导
	var du := _hermite_d(u)
	var su: float = du.x * r0 + du.y * r1 + du.z * r2 + du.w * r3

	# ∂/∂v：先按 u 组合每一列，再对 v 基求导
	var c0: float = a00 * bu.x + a10 * bu.y + a20 * bu.z + a30 * bu.w
	var c1: float = a01 * bu.x + a11 * bu.y + a21 * bu.z + a31 * bu.w
	var c2: float = a02 * bu.x + a12 * bu.y + a22 * bu.z + a32 * bu.w
	var c3: float = a03 * bu.x + a13 * bu.y + a23 * bu.z + a33 * bu.w
	var dv := _hermite_d(v)
	var sv: float = c0 * dv.x + c1 * dv.y + c2 * dv.z + c3 * dv.w
	return Vector3(h, su, sv)


## 世界坐标下的曲面法线（解析求：N ∝ (-∂S/∂x, 1, -∂S/∂z)，恒朝 +Y）
func _normal_from(p: Vector3) -> Vector3:
	return Vector3(-p.y / _cell, 1.0, -p.z / _cell).normalized()


## 参数坐标 → 世界坐标
func _world_point(cx: int, cz: int, u: float, v: float, h: float) -> Vector3:
	return Vector3(-_half + (float(cx) + u) * _cell, h, -_half + (float(cz) + v) * _cell)


# ===========================================================================
# 曲率驱动的自适应细分
# ===========================================================================

## 预计算每格的参数分段数 (nu,nv)、是否细分、中心高度
func _prepare_cells() -> void:
	var n: int = resolution * resolution
	_cell_center_h.resize(n)
	_cell_subdiv.resize(n)
	_cell_nu.resize(n)
	_cell_nv.resize(n)
	for z in range(resolution):
		for x in range(resolution):
			var i: int = z * resolution + x
			var seg: Vector2i = _choose_segments(x, z)
			_cell_nu[i] = seg.x
			_cell_nv[i] = seg.y
	_balance_levels()
	_subdiv_count = 0
	for z in range(resolution):
		for x in range(resolution):
			var i: int = z * resolution + x
			if _cell_nu[i] > 1 or _cell_nv[i] > 1:
				_cell_subdiv[i] = 1
				_subdiv_count += 1
				_cell_center_h[i] = _patch(x, z, 0.5, 0.5).x
			else:
				_cell_subdiv[i] = 0
				_cell_center_h[i] = -1e20


## 邻格分级平衡：任何一轴的分段数不低于邻格的一半（向上取候选档）。
## 不做这一步会出现"1×1 紧挨 6×6"：粗格内部只有 2 个三角，却要跟住一条
## 折弯很快的边界曲线，实测偏差 7cm。平衡后过渡只差一档，缝合扇形的三角形也规整。
func _balance_levels() -> void:
	for _r in range(2):
		for z in range(resolution):
			for x in range(resolution):
				var i: int = z * resolution + x
				var nu: int = int(_cell_nu[i])
				var nv: int = int(_cell_nv[i])
				var bn_u: int = maxi(_nu_at(x - 1, z), _nu_at(x + 1, z)) / 2
				var bn_v: int = maxi(_nv_at(x, z - 1), _nv_at(x, z + 1)) / 2
				_cell_nu[i] = maxi(nu, _snap_seg(bn_u))
				_cell_nv[i] = maxi(nv, _snap_seg(bn_v))


## 向上取到候选分段档 {1,2,3,4,6}
func _snap_seg(n: int) -> int:
	for v in [1, 2, 3, 4, 6]:
		if v >= n:
			return v
	return SUBDIV_MAX_SEG


## 按"弦高误差 ≤ _tol"挑最少面数的 (nu,nv)。
## 走的是最低成本优先：先试 1×1，不行再按面数递增试各向异性候选，
## 第一个满足预算的就是它——所以平坦区永远是 1×1（2 面）。
func _choose_segments(cx: int, cz: int) -> Vector2i:
	# 离散拉普拉斯（预计算）给出"最少要几段"的下界。
	# 弦高 ≈ M·(L/n)²/8，而 M ≈ lap/L² → n ≈ √(lap/(8·tol))；
	# 它只用于①平坦快路 ②跳过明显不够的候选，真正的判定仍由 _cell_sag 实测弦高。
	var row: int = resolution + 1
	var lap: float = 0.0
	for c in [0, 1, row, row + 1]:
		lap = maxf(lap, _lap[cz * row + cx + c])
	if lap < 0.02:
		return Vector2i(1, 1)
	var n_min: int = 1
	if lap > 0.0001:
		n_min = int(ceil(sqrt(lap / (8.0 * _tol)) * 0.55))
	var cost_min: int = 2 * n_min * n_min
	for cand in SUBDIV_CANDIDATES:
		if 2 * cand.x * cand.y < cost_min:
			continue
		if _cell_sag(cx, cz, cand.x, cand.y) <= _tol:
			return cand
	return Vector2i(SUBDIV_MAX_SEG, SUBDIV_MAX_SEG)


## 该格用 nu×nv 网格（每小格沿 00-11 对角线拆两三角）逼近解析面时的最大偏差。
## 采样点放在小格中心与两个对角采样点——三次曲面的弦高极值就在这附近。
func _cell_sag(cx: int, cz: int, nu: int, nv: int) -> float:
	var worst: float = 0.0
	var gw: int = nu + 1
	var grid: PackedFloat32Array = _sag_buf
	grid.resize(gw * (nv + 1))
	for j in range(nv + 1):
		for i in range(nu + 1):
			grid[j * gw + i] = _patch(cx, cz, float(i) / float(nu), float(j) / float(nv)).x
	_sag_buf = grid
	for j in range(nv):
		for i in range(nu):
			var h00: float = grid[j * gw + i]
			var h10: float = grid[j * gw + i + 1]
			var h01: float = grid[(j + 1) * gw + i]
			var h11: float = grid[(j + 1) * gw + i + 1]
			for k in range(5):
				var lu: float
				var lv: float
				if k == 0:
					lu = 0.5
					lv = 0.5
				elif k == 1:
					lu = 0.3
					lv = 0.7
				elif k == 2:
					lu = 0.7
					lv = 0.3
				elif k == 3:
					lu = 0.2
					lv = 0.2
				else:
					lu = 0.8
					lv = 0.8
				var lin: float
				if lu >= lv:
					lin = h00 * (1.0 - lu) + h10 * (lu - lv) + h11 * lv
				else:
					lin = h00 * (1.0 - lv) + h11 * lu + h01 * (lv - lu)
				var u: float = (float(i) + lu) / float(nu)
				var v: float = (float(j) + lv) / float(nv)
				worst = maxf(worst, absf(_patch(cx, cz, u, v).x - lin))
				if worst > SURFACE_TOL:
					return worst  # 已经超标，不必再算
	return worst


func _nv_at(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= resolution or z >= resolution:
		return 1
	return int(_cell_nv[z * resolution + x])


func _nu_at(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= resolution or z >= resolution:
		return 1
	return int(_cell_nu[z * resolution + x])


# ===========================================================================
# 建网格
# ===========================================================================

func _build_mesh() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	_tri_count = 0
	_steep_tri_count = 0
	_max_slope_deg = 0.0

	for z in range(resolution):
		for x in range(resolution):
			_add_cell(verts, normals, uvs, colors, x, z)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh


## 建一格。
##
## 拓扑：**格内保持 (nu,nv) 的规则参数网格**，只在"邻居在公共边上要更多段"的
## 边界四边形上，把邻居的那些参数点插进该四边形的外边界，然后以该四边形的一个角
## 为扇心三角化（红绿过渡的标准做法）。
##
## 为什么不用"整格中心扇形"（试过，是错的）：中心扇形只有一个内部采样点，
## 会把格内细分整个丢掉——4×6 的崖格被压成 22 个锥面三角，实测偏差 0.4m。
## 边界缝合只在四边形级别多插几个点、多 1~2 个三角，格内精度完全保留。
##
## 公共边上的参数点由两格各自用同一个 `_patch` 求值 → 逐点重合，因此**没有裂缝**。
func _add_cell(v: PackedVector3Array, n: PackedVector3Array,
		uv: PackedVector2Array, c: PackedColorArray, x: int, z: int) -> void:
	var i: int = z * resolution + x
	var nu: int = int(_cell_nu[i])
	var nv: int = int(_cell_nv[i])
	# 每条边要画几段 = 两格中更细的那个（保证公共边逐点重合）
	var e_w: int = maxi(nv, _nv_at(x - 1, z))
	var e_e: int = maxi(nv, _nv_at(x + 1, z))
	var e_s: int = maxi(nu, _nu_at(x, z - 1))
	var e_n: int = maxi(nu, _nu_at(x, z + 1))

	for j in range(nv):
		for ii in range(nu):
			var u0: float = float(ii) / float(nu)
			var u1: float = float(ii + 1) / float(nu)
			var v0: float = float(j) / float(nv)
			var v1: float = float(j + 1) / float(nv)
			# 四边形边界多边形（参数空间逆时针）
			var poly: Array[Vector2] = [Vector2(u0, v0)]
			if j == 0 and e_s > nu:
				for k in range(1, e_s):
					var uu: float = float(k) / float(e_s)
					if uu > u0 + 1e-6 and uu < u1 - 1e-6:
						poly.append(Vector2(uu, v0))
			poly.append(Vector2(u1, v0))
			if ii == nu - 1 and e_e > nv:
				for k in range(1, e_e):
					var vv: float = float(k) / float(e_e)
					if vv > v0 + 1e-6 and vv < v1 - 1e-6:
						poly.append(Vector2(u1, vv))
			poly.append(Vector2(u1, v1))
			if j == nv - 1 and e_n > nu:
				for k in range(e_n - 1, 0, -1):
					var uu2: float = float(k) / float(e_n)
					if uu2 > u0 + 1e-6 and uu2 < u1 - 1e-6:
						poly.append(Vector2(uu2, v1))
			poly.append(Vector2(u0, v1))
			if ii == 0 and e_w > nv:
				for k in range(e_w - 1, 0, -1):
					var vv2: float = float(k) / float(e_w)
					if vv2 > v0 + 1e-6 and vv2 < v1 - 1e-6:
						poly.append(Vector2(u0, vv2))

			var cnt: int = poly.size()
			var pp := PackedVector3Array()
			var nn := PackedVector3Array()
			pp.resize(cnt)
			nn.resize(cnt)
			for k in range(cnt):
				var p: Vector3 = _patch(x, z, poly[k].x, poly[k].y)
				pp[k] = _world_point(x, z, poly[k].x, poly[k].y, p.x)
				nn[k] = _normal_from(p)
			if cnt == 4:
				# 与 _cell_sag 同一套对角线选择：中线更贴曲面的那条
				var sc2: float = _patch(x, z, (u0 + u1) * 0.5, (v0 + v1) * 0.5).x
				var use_b2: bool = absf((pp[0].y + pp[2].y) * 0.5 - sc2) 					> absf((pp[1].y + pp[3].y) * 0.5 - sc2)
				if use_b2:
					_tri(v, n, uv, c, pp[0], nn[0], pp[1], nn[1], pp[3], nn[3])
					_tri(v, n, uv, c, pp[1], nn[1], pp[2], nn[2], pp[3], nn[3])
				else:
					_tri(v, n, uv, c, pp[0], nn[0], pp[1], nn[1], pp[2], nn[2])
					_tri(v, n, uv, c, pp[0], nn[0], pp[2], nn[2], pp[3], nn[3])
			else:
				for k in range(1, cnt - 1):
					_tri(v, n, uv, c, pp[0], nn[0], pp[k], nn[k], pp[k + 1], nn[k + 1])


## 追加一个三角面。顶点法线是**解析法线**（逐顶点平滑），颜色仍是逐面（保留块面感）。
##
## 绕序：Godot 正面是顺时针，所以俯视可见面的几何法线 (b-a)×(d-a) 应与解析法线反向。
## 这里直接用解析法线当判据翻转，不再像旧版那样靠"最低顶点方向"猜外法线
## ——曲面上每点都有真实法线，不需要启发式。
func _tri(v: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array,
		c: PackedColorArray, a: Vector3, na: Vector3,
		b: Vector3, nb: Vector3, d: Vector3, nd: Vector3) -> void:
	var navg: Vector3 = na + nb + nd
	if navg.length_squared() < 0.0000001:
		navg = Vector3.UP
	else:
		navg = navg.normalized()
	var geo: Vector3 = (b - a).cross(d - a)
	if geo.dot(navg) > 0.0:
		var tb: Vector3 = b
		var tnb: Vector3 = nb
		b = d
		nb = nd
		d = tb
		nd = tnb
	v.append(a)
	v.append(b)
	v.append(d)
	n.append(na)
	n.append(nb)
	n.append(nd)
	# UV 用世界参数化（不是格索引）：换分辨率贴图不会跳
	uv.append(Vector2(a.x / size + 0.5, a.z / size + 0.5))
	uv.append(Vector2(b.x / size + 0.5, b.z / size + 0.5))
	uv.append(Vector2(d.x / size + 0.5, d.z / size + 0.5))
	# ★ 染色**逐顶点**求，不是逐面：逐面会在 1.8m 一格上留下可见色块，
	#   那正是旧版"迷彩布"观感的来源。逐顶点 + 三次曲面 = 平滑大色区。
	c.append(_tint_at(a, na))
	c.append(_tint_at(b, nb))
	c.append(_tint_at(d, nd))

	_tri_count += 1
	var slope_deg: float = rad_to_deg(acos(clampf(navg.y, -1.0, 1.0)))
	_max_slope_deg = maxf(_max_slope_deg, slope_deg)
	if slope_deg >= STEEP_FACE_DEG:
		_steep_tri_count += 1


# ===========================================================================
# 高度查询（与渲染网格同源：都走 _patch 解析求值）
# ===========================================================================

## 地形高度 = **渲染出来的那张三角面**在 (x,z) 处的高度。
##
## 为什么不再直接用解析曲面片（_patch）：
##   网格是拿 _patch 在 nu×nv 的采样点上取值、再两两连成三角面的。
##   两个采样点**之间**，渲染是线性插值、解析面是三次曲面 —— 差值就是"弦高"，
##   细分判据 SURFACE_TOL = 0.10 说明这个差最多 10cm。
##   于是"按解析面落地的单位/建筑/金矿"会陷进看得见的地面最多 10cm，
##   表现为下摆/地基被地形纹理吃掉一截（玩家报的"被地形穿模"）。
##   现在按**和渲染完全同一条对角线**做面插值，落点就等于玩家看到的表面。
##
## 顶点/细分中心处两种算法结果相同，所以 地形自检 的
## "height_at 与网格顶点一致 / 与四分裂中心一致" 两条断言不受影响。
func height_at(wx: float, wz: float) -> float:
	if heights.is_empty() or resolution <= 0 or _tan_u.is_empty():
		return 0.0
	var fx: float = (wx + _half) / _cell
	var fz: float = (wz + _half) / _cell
	var cx: int = clampi(floori(fx), 0, resolution - 1)
	var cz: int = clampi(floori(fz), 0, resolution - 1)
	var u: float = clampf(fx - float(cx), 0.0, 1.0)
	var v: float = clampf(fz - float(cz), 0.0, 1.0)
	return _mesh_height(cx, cz, u, v)


## 该格在参数坐标 (u,v) 处**渲染三角面**的高度。
## 渲染口径见 _cell_sag 的线性插值：每个小格沿 00-11 对角线拆两三角，
## lu >= lv 落在 (00,10,11)，否则落在 (00,11,01)。
func _mesh_height(cx: int, cz: int, u: float, v: float) -> float:
	var nu: int = maxi(_nu_at(cx, cz), 1)
	var nv: int = maxi(_nv_at(cx, cz), 1)
	var gu: float = u * float(nu)
	var gv: float = v * float(nv)
	var i: int = clampi(floori(gu), 0, nu - 1)
	var j: int = clampi(floori(gv), 0, nv - 1)
	var lu: float = clampf(gu - float(i), 0.0, 1.0)
	var lv: float = clampf(gv - float(j), 0.0, 1.0)
	var u0: float = float(i) / float(nu)
	var u1: float = float(i + 1) / float(nu)
	var v0: float = float(j) / float(nv)
	var v1: float = float(j + 1) / float(nv)
	var h00: float = _patch(cx, cz, u0, v0).x
	var h10: float = _patch(cx, cz, u1, v0).x
	var h01: float = _patch(cx, cz, u0, v1).x
	var h11: float = _patch(cx, cz, u1, v1).x
	if lu >= lv:
		return h00 * (1.0 - lu) + h10 * (lu - lv) + h11 * lv
	return h00 * (1.0 - lv) + h11 * lu + h01 * (lv - lu)


## 地形法线（解析）：N ∝ (-∂S/∂x, 1, -∂S/∂z)，恒指 +Y
func normal_at(wx: float, wz: float) -> Vector3:
	if heights.is_empty() or resolution <= 0 or _tan_u.is_empty():
		return Vector3.UP
	var fx: float = (wx + _half) / _cell
	var fz: float = (wz + _half) / _cell
	var cx: int = clampi(floori(fx), 0, resolution - 1)
	var cz: int = clampi(floori(fz), 0, resolution - 1)
	var u: float = clampf(fx - float(cx), 0.0, 1.0)
	var v: float = clampf(fz - float(cz), 0.0, 1.0)
	return _normal_from(_patch(cx, cz, u, v))


## 某点的坡度（度）。用**解析法线**直接算：acos(N.y)，
## 不再用 eps 中心差分——差分会被邻格折痕污染，也不该在曲面上有步长误差。
## eps 参数保留只为签名兼容（旧调用方都在传 0.5/0.75）。
func slope_degrees_at(wx: float, wz: float, _eps: float = 0.75) -> float:
	var n: Vector3 = normal_at(wx, wz)
	return rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))


## 某点是否陡于给定角度
func is_steep_at(wx: float, wz: float, deg: float = STEEP_FACE_DEG) -> bool:
	return slope_degrees_at(wx, wz) >= deg


# ===========================================================================
# 统计接口（自检/报告用）
# ===========================================================================

func triangle_count() -> int:
	return _tri_count


func subdivided_cell_count() -> int:
	return _subdiv_count


func height_min() -> float:
	return _height_min


func height_max() -> float:
	return _height_max


func height_range() -> float:
	return maxf(0.0, _height_max - _height_min)


func max_slope_degrees() -> float:
	return _max_slope_deg


## 陡面（>= deg 度）占全部三角面的比例
func steep_face_ratio(deg: float = STEEP_FACE_DEG) -> float:
	if _tri_count <= 0:
		return 0.0
	# 统计是在 STEEP_FACE_DEG 下累的；改阈值需要重扫，但报告只用默认 45°
	if absf(deg - STEEP_FACE_DEG) < 0.001:
		return float(_steep_tri_count) / float(_tri_count)
	return 0.0


## 某格是否四分裂
func is_subdivided_cell(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= resolution or cell.y >= resolution:
		return false
	var i: int = cell.y * resolution + cell.x
	return _cell_subdiv.size() > i and _cell_subdiv[i] != 0


## 某格中心顶点高度（未细分格返回 -1e20）；自检核对用
func cell_center_height(cell: Vector2i) -> float:
	if not is_subdivided_cell(cell):
		return -1e20
	return _cell_center_h[cell.y * resolution + cell.x]


## 某格的参数分段数 (nu,nv)；越界返回 (1,1)。诊断/自检用。
func cell_subdiv_segments(cell: Vector2i) -> Vector2i:
	if cell.x < 0 or cell.y < 0 or cell.x >= resolution or cell.y >= resolution:
		return Vector2i(1, 1)
	var i: int = cell.y * resolution + cell.x
	return Vector2i(_cell_nu[i], _cell_nv[i])


# ===========================================================================
# 材质 / 配色
# ===========================================================================

## 生成地形材质
func _make_material() -> Material:
	var path := "res://美术/材质/地形材质.tres"
	if ResourceLoader.exists(path):
		var m := load(path) as Material
		if m != null:
			# **必须 duplicate**：地形要按地图写 mat_map / biome 换色参数，
			# 直接改共享资源会把上一张图的参数带到下一张（编辑器与游戏同时存在时更明显）。
			var own := m.duplicate(true)
			_apply_material_landmarks(own)
			return own
	var std := StandardMaterial3D.new()
	std.vertex_color_use_as_albedo = true
	std.vertex_color_is_srgb = true
	std.roughness = 0.95
	std.metallic = 0.0
	std.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return std


## ── 地块材质资源（魔兽争霸 3 式双材质硬边过渡） ─────────────────────
## 图集：2048×1024，左 4×4 是 16 个"四角材质"过渡格（德布鲁因环摆位），
##       右 4×4 是 16 个纯纹理变体（上两行 A=草 8 个、下两行 B=泥 8 个）。
## 底材：512² 无缝，8m 一铺，与图集同节奏。
const ATLAS_PATH := "res://美术/贴图/地形/材质/草泥/atlas_草泥_rgba.png"
## 图集法线（Sobel 自遮罩；和 rgba 图集逐格对应）
const ATLAS_N_PATH := "res://美术/贴图/地形/材质/草泥/atlas_草泥_n.png"
const TEX_GRASS_PATH := "res://美术/贴图/地形/草地.png"
const TEX_DIRT_PATH := "res://美术/贴图/地形/泥土.png"
const TEX_CRACKED_PATH := "res://美术/贴图/地形/裂纹泥地.png"
## 崖壁细节（灰度，当噪声用；颜色由 rock_tint 给）
const ROCK_DETAIL_PATH := "res://美术/贴图/rock_albedo.png"
## 一格多少米。**必须与底材平铺距离一致**，否则交界和踩踏节奏对不上。
const TILE_M: float = 8.0


## 把地块图集 / 底材 / 格点表喂给着色器。
##
## 这里**只有一条主线**：地面材质由 8m 地块决定、交界是硬边。
## 旧版的 5 套程序化噪声 + 2 套细节法线 + 面片哈希 + 1m 格线已经全部删掉 ——
## 它们是"很杂很乱"的直接原因（10~20m 的亮黄大斑 + 1.75m 菱形碎块）。
func _apply_material_landmarks(m: Material) -> void:
	var sm := m as ShaderMaterial
	if sm == null:
		return
	sm.set_shader_parameter("mat_map", mat_map)
	sm.set_shader_parameter("tile_m", TILE_M)
	sm.set_shader_parameter("map_half", size * 0.5)
	sm.set_shader_parameter("mat_cells", maxi(mat_cells, 1))
	# 生态换色：和游戏里同一张地图、同一组参数 —— 编辑器看到的颜色就是游戏里看到的颜色
	var bt: Array = MapDef.biome_tint(biome)
	sm.set_shader_parameter("biome_color", bt[0])
	sm.set_shader_parameter("biome_mix", bt[1])
	var slots := {
		"atlas_rgba": ATLAS_PATH,
		"atlas_n": ATLAS_N_PATH,
		"tex_grass": TEX_GRASS_PATH,
		"tex_dirt": TEX_DIRT_PATH,
		"tex_cracked": TEX_CRACKED_PATH,
		"rock_detail": ROCK_DETAIL_PATH,
	}
	for key in slots:
		var path: String = slots[key]
		if not ResourceLoader.exists(path):
			continue
		var t := load(path) as Texture2D
		if t != null:
			sm.set_shader_parameter(key, t)


## 只刷地块贴图（不重建网格）：编辑器拖地表格点笔刷时逐帧调，重建整张网格会卡。
func refresh_mat_map() -> void:
	_build_mat_map()
	if _mesh_instance == null:
		return
	var sm := _mesh_instance.material_override as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter("mat_map", mat_map)


## 只刷生态换色参数（不重建网格）：编辑器换生态色带时用，改两个 uniform 就够。
func refresh_biome_tint() -> void:
	if _mesh_instance == null:
		return
	var sm := _mesh_instance.material_override as ShaderMaterial
	if sm == null:
		return
	var bt: Array = MapDef.biome_tint(biome)
	sm.set_shader_parameter("biome_color", bt[0])
	sm.set_shader_parameter("biome_mix", bt[1])


## 生成 mat_map：R8、(mat_cells+1)² 个格点，1 texel = 1 个格点 = 8m。
## 没有数据时给一张 1×1 全 0 的贴图（整图草地），着色器不会崩。
func _build_mat_map() -> void:
	var n: int = maxi(mat_cells + 1, 2)
	var img := Image.create(n, n, false, Image.FORMAT_R8)
	if mat_nodes.size() == n * n:
		var bytes := PackedByteArray()
		bytes.resize(n * n)
		for i in range(n * n):
			bytes[i] = mat_nodes[i]
		img.set_data(n, n, false, Image.FORMAT_R8, bytes)
	else:
		img.fill(Color(0.0, 0.0, 0.0, 1.0))
	mat_map = ImageTexture.create_from_image(img)



## 顶点色 = **乘法染色 + 干度**，不再承担配色。
##
## 旧版这里是"按高度/坡度挑一堆颜色常量"（草/草高/干草/土/岩/岩高/岩暗/冷/碎石 九种），
## 再叠 3 层哈希抖动 —— 每一层都说得通，合起来就是玩家说的"很杂很乱"：
## 颜色是逐三角面挑的，于是 1.8m 一格一个色块，整片地像迷彩布。
##
## 现在配色**由地块贴图负责**（草地/泥土/裂纹泥地，见 shader），
## 顶点色只做两件事：
##   rgb  = 1.0 附近的乘法染色（大尺度冷暖 ±3.5%、营地压暗、陡面偏灰）
##   a    = 干度 0..1（0 = 泥土，1 = 裂纹泥地；只在泥地那一侧起作用）
func _tint_at(pos: Vector3, normal: Vector3) -> Color:
	var rng: float = maxf(height_range(), 0.001)
	var alt: float = clampf((pos.y - _height_min) / rng, 0.0, 1.0)
	var up: float = clampf(normal.y, 0.0, 1.0)
	# ── 大尺度冷暖（40~90m 波长）：只 ±3.5%，是"光照/季节的偏移"，不是色块 ──
	var warm: float = sin(pos.x * 0.052 + pos.z * 0.031) * 0.55 \
		+ sin(pos.z * 0.074 - pos.x * 0.021 + 1.7) * 0.45
	var k: float = 1.0 + warm * 0.035
	var tr: float = k * 1.012
	var tg: float = k
	var tb: float = k * 0.978

	# ── 干度：高处更干（裂纹泥地），低洼处保持普通泥土 ──
	var dry: float = smoothstep(0.30, 0.95, alt) * 0.85 + warm * 0.12

	# ── 陡面：偏灰、偏冷。真正的颜色由 shader 的岩石层接管，这里只让它别"绿" ──
	var steep: float = 1.0 - up
	if steep > 0.06:
		var st: float = clampf((steep - 0.06) / 0.30, 0.0, 1.0)
		tr = lerpf(tr, 0.92, st * 0.7)
		tg = lerpf(tg, 0.94, st * 0.7)
		tb = lerpf(tb, 1.02, st * 0.7)
		dry *= 1.0 - st * 0.6

	# ── 营地：踩实的地面（压暗 ~8%，干裂纹减半），不让建筑脚下"破了" ──
	var camp: float = 0.0
	if not base_points.is_empty():
		var p2 := Vector2(pos.x, pos.z)
		for bp in base_points:
			camp = maxf(camp, 1.0 - smoothstep(15.0, 34.0, p2.distance_to(bp)))
		if camp > 0.001:
			var dark: float = lerpf(1.0, 0.925, camp)
			tr *= dark
			tg *= dark
			tb *= dark
			dry *= lerpf(1.0, 0.45, camp)

	return Color(clampf(tr, 0.0, 1.6), clampf(tg, 0.0, 1.6), clampf(tb, 0.0, 1.6),
		clampf(dry, 0.0, 1.0))


## 确定性 0..1 哈希
func _hash01(x: int, z: int) -> float:
	var v: float = sin(float(x) * 12.9898 + float(z) * 78.233) * 43758.5453
	return v - floorf(v)


# ===========================================================================
# 远景山脊（纯视觉）
# ===========================================================================

## 地图外圈再叠三层低多边形山峰。
##
## 为什么必须加：场景外是一张平板，光把围栏削出断口，断口后面还是"平板天空"，
## 一眼就能看出是围栏。三层远近不同的山脊加雾，外围就变成"盆地外的群山"，
## 镜头转到任何角度都有纵深。
##
## 不写 HeightMap、不进 height_at：相机保护/寻路/可走性完全不受影响。
## 边缘压平：最外 `rings` 圈格点按"越靠边权重越大"拉向四条边的平均高度。
## 目的：`_build_skirt()` 的顶边是直线，断崖不会跟着地形锯齿变成一圈狗牙。
func _flatten_border(rings: int) -> void:
	var row: int = resolution + 1
	if heights.size() < row * row or rings <= 0:
		return
	var sum: float = 0.0
	var cnt: int = 0
	for i in range(row):
		sum += heights[i]
		sum += heights[(row - 1) * row + i]
		sum += heights[i * row]
		sum += heights[i * row + (row - 1)]
		cnt += 4
	if cnt == 0:
		return
	var avg: float = sum / float(cnt)
	for gz in range(row):
		for gx in range(row):
			var d: int = mini(mini(gx, gz), mini(resolution - gx, resolution - gz))
			if d >= rings:
				continue
			var w: float = 1.0 - float(d) / float(rings)
			var idx: int = gz * row + gx
			heights[idx] = lerpf(heights[idx], avg, w)


## 边界裙边：沿四条边向下拉 26m 的垂直崖壁。
##
## 为什么需要：关掉远景山脊之后，地图四周就是"网格断口"——俯视能看到一圈
## 参差不齐的三角形边缘，那不像"世界边界"，像"还没做完"。
## 加一圈整齐的断崖，边界立刻从"截断"变成"设计出来的"。
func _build_skirt() -> void:
	if _skirt != null and is_instance_valid(_skirt):
		_skirt.queue_free()
		_skirt = null
	var row: int = resolution + 1
	if heights.size() < row * row:
		return
	var hw: float = size * 0.5
	var cell: float = size / float(resolution)
	var depth: float = maxf(18.0, size * 0.12)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	# 岩石灰：断崖要看得见是一道崖，不是一团黑影。
	# 旧版压到 0.19 的近黑，"底部"读起来是一团脏影 —— 这里整体提亮一档。
	var low := Color(0.242, 0.226, 0.206)
	var high := Color(0.412, 0.386, 0.344)
	# 四条边：{沿哪根轴走, 固定格, 外侧法线}
	var edges: Array = [
		{"axis": 0, "fixed": 0, "n": Vector3(0.0, 0.0, -1.0)},
		{"axis": 0, "fixed": resolution, "n": Vector3(0.0, 0.0, 1.0)},
		{"axis": 1, "fixed": 0, "n": Vector3(-1.0, 0.0, 0.0)},
		{"axis": 1, "fixed": resolution, "n": Vector3(1.0, 0.0, 0.0)},
	]
	for e in edges:
		var n: Vector3 = e["n"]
		for i in range(resolution):
			var g0: Vector2i
			var g1: Vector2i
			if int(e["axis"]) == 0:
				g0 = Vector2i(i, int(e["fixed"]))
				g1 = Vector2i(i + 1, int(e["fixed"]))
			else:
				g0 = Vector2i(int(e["fixed"]), i)
				g1 = Vector2i(int(e["fixed"]), i + 1)
			var p0 := Vector3(-hw + float(g0.x) * cell, heights[g0.y * row + g0.x],
				-hw + float(g0.y) * cell)
			var p1 := Vector3(-hw + float(g1.x) * cell, heights[g1.y * row + g1.x],
				-hw + float(g1.y) * cell)
			var q0 := Vector3(p0.x, p0.y - depth, p0.z)
			var q1 := Vector3(p1.x, p1.y - depth, p1.z)
			var tris: Array = [[p0, q0, q1], [p0, q1, p1]]
			for tri in tris:
				for v in tri:
					verts.append(v)
					normals.append(n)
					var t: float = clampf((v.y - (p0.y - depth)) / maxf(depth, 0.1), 0.0, 1.0)
					colors.append(low.lerp(high, t))
					# UV 沿墙面走（水平 = 沿边弧长 / 6，竖直 = 高度 / 6）：
					# 给岩石细节贴图一个不拉伸的参数化，断崖才有"石"的读法。
					var along: float = float(i) * cell / 6.0
					uvs.append(Vector2(along, v.y / 6.0))
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_skirt = MeshInstance3D.new()
	_skirt.name = "边界裙边"
	_skirt.mesh = mesh
	_skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	_skirt.material_override = mat
	add_child(_skirt)


func _build_far_ridges() -> void:
	if _far_ridges != null and is_instance_valid(_far_ridges):
		_far_ridges.queue_free()
		_far_ridges = null
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	# 半径按地图尺寸**等比放大**：这一层原来写死 142/184/252m（给 200m 图配的），
	# 套到 224m 图上第一圈就落在 112m 的地图边缘外 30m —— 俯视时是一圈贴脸的大灰锥。
	# 现在最内圈 = size*0.95，保证永远在地图之外，而且越远越低、越蓝（雾色）。
	var f: float = maxf(1.0, size / 200.0) * 1.18
	var layers: Array = [
		{"r": 142.0 * f, "spread": 18.0 * f, "base": -20.0, "h": 34.0, "n": 46,
			"low": Color(0.105, 0.145, 0.130), "high": Color(0.170, 0.215, 0.195)},
		{"r": 184.0 * f, "spread": 24.0 * f, "base": -24.0, "h": 54.0, "n": 56,
			"low": Color(0.125, 0.158, 0.185), "high": Color(0.215, 0.255, 0.300)},
		{"r": 252.0 * f, "spread": 34.0 * f, "base": -28.0, "h": 78.0, "n": 64,
			"low": Color(0.160, 0.188, 0.228), "high": Color(0.280, 0.315, 0.375)},
	]
	for li in range(layers.size()):
		var L: Dictionary = layers[li]
		var count: int = int(L["n"])
		for k in range(count):
			var hs: float = _hash01(k * 13 + li * 71, li * 37 + 11)
			var hs2: float = _hash01(k * 29 + li * 17, li * 53 + 7)
			var hs3: float = _hash01(k * 7 + li * 43, li * 19 + 3)
			var ang: float = TAU * (float(k) + hs * 0.55) / float(count)
			var rr: float = float(L["r"]) + (hs2 - 0.5) * float(L["spread"])
			var height: float = float(L["h"]) * (0.52 + 0.95 * hs3)
			var base_r: float = 8.0 + 13.0 * hs
			var center := Vector3(cos(ang) * rr, float(L["base"]), sin(ang) * rr)
			var low: Color = L["low"]
			var high: Color = L["high"]
			_add_far_peak(verts, normals, colors, center, base_r, height,
				ang, low, high, hs2)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_far_ridges = MeshInstance3D.new()
	_far_ridges.name = "远景山脊"
	_far_ridges.mesh = mesh
	_far_ridges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	_far_ridges.material_override = mat
	add_child(_far_ridges)


## 一座低多边形山峰：6 段锥体 + 一个错开的副峰，硬面着色
func _add_far_peak(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		center: Vector3, base_r: float, height: float, ang: float,
		low: Color, high: Color, tint: float) -> void:
	var seg: int = 6
	var apex := center + Vector3(cos(ang) * base_r * 0.35, height, sin(ang) * base_r * 0.35)
	var ring: Array[Vector3] = []
	for s in range(seg):
		var a: float = TAU * float(s) / float(seg) + tint * 2.0
		var rr: float = base_r * (0.72 + 0.55 * _hash01(s * 11 + int(tint * 97.0), int(ang * 100.0)))
		ring.append(center + Vector3(cos(a) * rr, 0.0, sin(a) * rr))
	for s in range(seg):
		var p0: Vector3 = ring[s]
		var p1: Vector3 = ring[(s + 1) % seg]
		var mid: Vector3 = (p0 + p1) * 0.5
		# 山腰：把锥面拆成两截，轮廓更像山而不是三角锥
		var shoulder := mid.lerp(apex, 0.48)
		shoulder.y += height * 0.04
		_add_far_tri(v, n, c, p0, p1, shoulder, low, high)
		_add_far_tri(v, n, c, p0, shoulder, apex, low, high)
		_add_far_tri(v, n, c, shoulder, p1, apex, low, high)


func _add_far_tri(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		a: Vector3, b: Vector3, d: Vector3, low: Color, high: Color) -> void:
	var geo: Vector3 = (b - a).cross(d - a)
	if geo.length_squared() < 0.0001:
		return
	var light: Vector3 = geo.normalized()
	if light.y < 0.0:
		light = -light
	# 用面心高度做"山脚暗、山脊亮"的冷色渐变
	var yy: float = (a.y + b.y + d.y) / 3.0
	var g: float = clampf((yy + 14.0) / 96.0, 0.0, 1.0)
	var col: Color = low.lerp(high, clampf(g * 1.25, 0.0, 1.0))
	v.append(a)
	v.append(b)
	v.append(d)
	for _i in range(3):
		n.append(light)
		c.append(col)


# ===========================================================================
# 水面
# ===========================================================================

## 生成一片水面（水潭）
func build_water(center: Vector2, radius: float, level_y: float) -> void:
	if water != null and is_instance_valid(water):
		water.queue_free()
	water = MeshInstance3D.new()
	water.name = "水面"
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.25
	disc.radial_segments = 28
	disc.rings = 1
	water.mesh = disc
	water.position = Vector3(center.x, level_y, center.y)
	var mat: Material = null
	var path := "res://美术/材质/水材质.tres"
	if ResourceLoader.exists(path):
		mat = load(path)
	if mat == null:
		var std := StandardMaterial3D.new()
		std.albedo_color = Color(0.16, 0.36, 0.52, 0.85)
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.roughness = 0.12
		std.metallic = 0.35
		mat = std
	# v3.3：把波纹法线喂进水面着色器（俯视角下水面不再像一块静止蓝玻璃）
	var sm := mat as ShaderMaterial
	if sm != null:
		var rp := "res://美术/贴图/water_normal.png"
		if ResourceLoader.exists(rp):
			sm.set_shader_parameter("ripple_normal", load(rp))
	water.material_override = mat
	add_child(water)