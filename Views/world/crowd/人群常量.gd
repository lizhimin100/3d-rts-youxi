extends RefCounted
## **人群管线常量** —— 数据导向层的地基（无 Node3D、无 Variant、无整数除余）。
##
## 为什么这里全是常量而不是配置卡：这一层是**性能地基**，尺寸一旦变成运行时变量，
## 索引就不能再写成位运算，会退回到 `int /`、`int %`。实测（Godot 4.7.2，20 核）：
##   · 线程里 `int /` 是 0.60×、`int %` 是 0.57×，线程越多越慢；
##   · `>>` / `&` 是 5.5×，浮点乘 5.9×，都近线性。
## 详见 `Documents/万单位与SC2管线_可行性评估.md` §2。
##
## 三套坐标同时存在，别搞混：
##   1. **世界米**（pos_x/pos_z）：浮点，唯一对外的坐标；
##   2. **寻路格**（1m）：`cell = (floori(w) + 128) & 255`，256×256；
##   3. **空间桶**（4m）：`bucket = ((floori(w) + 128) >> 2) & 63`，64×64。
## 偏移 128 是为了把地图的负坐标抬成非负；`& 255` 保证任何越界坐标都落回环内。

# ---------------------------------------------------------------------------
# 世界与网格
# ---------------------------------------------------------------------------
## 世界半边长（米）。地图 224m，取 256m 覆盖，留 16m 余量给追出边界的单位。
const WORLD_HALF: float = 128.0
## 寻路格边长（米）—— 必须是 2 的幂，`GRID_SHIFT` 跟着它走。
const CELL: float = 1.0
## 1m → 0 位；若改成 2m 格，这里写 1。
const CELL_SHIFT: int = 0
const GRID_N: int = 256
const GRID_MASK: int = 255
const GRID_TOTAL: int = 65536

## 空间桶边长（米）—— 4m，64×64。桶越大，邻居查询越省，但重叠越多。
const BUCKET: float = 4.0
const BUCKET_SHIFT: int = 2
const BUCKET_N: int = 64
const BUCKET_MASK: int = 63
const BUCKET_TOTAL: int = 4096

# ---------------------------------------------------------------------------
# 容量与节拍
# ---------------------------------------------------------------------------
## 单位容量。**固定上限**：所有 SoA 数组一次分配到位，运行期不再扩容
## （扩容会让线程池持有的块边界失效）。
const MAX_UNITS: int = 16384
## 逻辑频率。20Hz = 每 tick 50ms；渲染 60fps 时每 tick 插 3 帧。
const TICK_HZ: int = 20
const TICK_DT: float = 0.05
## 单帧最多补几个 tick（卡顿时防止雪崩；1 个 tick = 50ms 逻辑）。
const MAX_CATCHUP: int = 3
## 线程池分块下限：块小于 ~512 个单位时，调度开销大于收益。
const CHUNK_MIN: int = 512

# ---------------------------------------------------------------------------
# 行为参数
# ---------------------------------------------------------------------------
## 推挤总增益（每 tick 推开重叠的比例）。大了会抖，小了挤不动。
const PUSH_GAIN: float = 0.4
## 分离推力上限（米/秒）
const SEP_MAX: float = 1.8
## 半径外扩余量：贴墙时留 0.12m，**不能为零**——零余量会被分离推 1mm 就掉出可走区，
## 然后被墙推回来，每帧对拉（主线 `网格寻路.gd:45-52` 记的就是这个事故）。
const SKIN: float = 0.12
## 看路：前方探测距离 = 半径 × 该系数 + 基础值
const LOOK_AHEAD: float = 2.2
## 看路采样角度（度），正前方左右各 3 档 + 更宽的两档。
## 用未类型化 Array 字面量：`PackedFloat32Array([...])` 不是常量表达式，不能作 const。
const LOOK_ANGLES: Array = [0.0, 25.0, -25.0, 50.0, -50.0, 80.0, -80.0]
## 侧向意图保持时间（秒）：避免"你往哪我往哪"的跳舞
const SIDE_HOLD: float = 0.35
## 路径窗口：单位只记接下来两个拐点（SC2 口径），偏离折线超过该值就重算
const PATH_DEVIATE: float = 0.9
## 流场重算周期（秒）。目标不变时流场不用重算——地图是静的，2s 只是兜底。
const FLOW_TTL: float = 2.0

# ---------------------------------------------------------------------------
# 状态位
# ---------------------------------------------------------------------------
const ST_IDLE: int = 0
const ST_MOVE: int = 1
const ST_HOLD: int = 2
const ST_AIR: int = 3
const ST_ATTACK: int = 4

# ---------------------------------------------------------------------------
# 索引工具（全部位运算，热循环里可以放心调）
# ---------------------------------------------------------------------------

## 世界米 → 寻路格索引（0..65535）。越界坐标会被 `& 255` 折回，调用方自己判 bounds。
static func cell_index(wx: float, wz: float) -> int:
	var cx: int = (floori(wx) + 128) & GRID_MASK
	var cz: int = (floori(wz) + 128) & GRID_MASK
	return (cz << 8) | cx


## 世界米 → 空间桶索引（0..4095）
static func bucket_index(wx: float, wz: float) -> int:
	var bx: int = ((floori(wx) + 128) >> BUCKET_SHIFT) & BUCKET_MASK
	var bz: int = ((floori(wz) + 128) >> BUCKET_SHIFT) & BUCKET_MASK
	return (bz << 6) | bx


## 桶索引 → 桶中心世界坐标（x）
static func bucket_center_x(b: int) -> float:
	return float((b & BUCKET_MASK) << BUCKET_SHIFT) - 128.0 + BUCKET * 0.5


## 桶索引 → 桶中心世界坐标（z）
static func bucket_center_z(b: int) -> float:
	return float((b >> 6) << BUCKET_SHIFT) - 128.0 + BUCKET * 0.5


## 格索引 → 格中心 x
static func cell_center_x(c: int) -> float:
	return float(c & GRID_MASK) - 128.0 + CELL * 0.5


## 格索引 → 格中心 z
static func cell_center_z(c: int) -> float:
	return float(c >> 8) - 128.0 + CELL * 0.5


## 世界坐标是否在地图内
static func in_world(wx: float, wz: float) -> bool:
	return wx >= -WORLD_HALF and wx < WORLD_HALF and wz >= -WORLD_HALF and wz < WORLD_HALF
