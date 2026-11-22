class_name RtsTileSpec
extends RefCounted
## 职责：战术格子里"建筑站哪儿 / 多大 / 朝哪"的**唯一实现**（纯表现层规格，不含任何玩法判定）。
## 属于：Screens/world/art（表现层）
##
## 为什么单独一份：棋盘要画"建筑位"标记、建筑层要摆模型、截图验收要量占地比例 ——
## 三处各算一遍必然错开。这里把它们收敛成一份，参数全部来自 `planning.json` 的 `board.building`。
##
## 口径（2026-11-22 定稿）：
##   · **水平占地 = 单格边长的 38%~44%**（`footprint_ratio`）。此前的"缩到格子 92%"等于让建筑
##     压满整格、把出兵位和邻格全遮住 —— 那不是"占一格"，那是"填一格"。
##   · 底座中心落在格子的**左上象限**（本地 -X / -Z 方向各偏 0.26 格），
##     于是建筑整体不越出格子的左上边界，而格子正中心（出兵位）自然空出来。
##   · 玩家侧建筑正面朝 **+Z**（面向游玩镜头）。工程约定"模型正面 = -Z"，
##     所以玩家侧要额外转 180°；敌方格子的 yaw 在底壳里本来就是 180°，不再叠加。
##   · 锚点仍以 Model 给的 `building_x / building_z`（左上角角点）为基准 ——
##     这里只在它基础上沿格子本地轴推 (0.5 + anchor_u) 格，绝不另起一套角点算法。

## 水平占地的合法区间（占格边长的比例）：低于 38% 像盆景，高于 44% 压邻格。
const FOOTPRINT_MIN := 0.38
const FOOTPRINT_MAX := 0.44
const FOOTPRINT_DEFAULT := 0.41

## 建筑底座中心相对格中心的本地偏移（单位 = 格边长）。负 X / 负 Z = 左上象限。
const ANCHOR_U_DEFAULT := -0.26
const ANCHOR_V_DEFAULT := -0.26

## 各方位的朝向增量（度）。玩家侧 +180 让"模型正面 -Z"转向 +Z（面向镜头）。
const FACING_PLAYER_DEFAULT := 180.0
const FACING_ENEMY_DEFAULT := 0.0

## 从规划表取出这套规格（缺字段补默认值，并夹进合法区间 —— 手改 JSON 也不会画出越界建筑）。
static func spec_from(planning: Dictionary) -> Dictionary:
	var b: Variant = planning.get("placement", {})
	var d: Dictionary = b if b is Dictionary else {}
	var facing: Variant = d.get("facing_deg", {})
	var fd: Dictionary = facing if facing is Dictionary else {}
	return {
		"footprint_ratio": clampf(float(d.get("footprint_ratio", FOOTPRINT_DEFAULT)),
			FOOTPRINT_MIN, FOOTPRINT_MAX),
		"anchor_u": float(d.get("anchor_u", ANCHOR_U_DEFAULT)),
		"anchor_v": float(d.get("anchor_v", ANCHOR_V_DEFAULT)),
		"facing_player_deg": float(fd.get("player", FACING_PLAYER_DEFAULT)),
		"facing_enemy_deg": float(fd.get("enemy", FACING_ENEMY_DEFAULT)),
	}


## 归一化缩放：把 AABB 的最大水平边压到 `ratio × 格子短边`，返回统一缩放系数。
## 传的是**已经乘过 model_scale 的包围盒尺寸**，所以换模型/改 model_scale 都不用改代码。
static func fit_scale(box_size: Vector3, tile_w: float, tile_d: float, ratio: float) -> float:
	var span := clampf(ratio, FOOTPRINT_MIN, FOOTPRINT_MAX) * minf(maxf(tile_w, 0.01), maxf(tile_d, 0.01))
	var widest := maxf(maxf(box_size.x, box_size.z), 0.001)
	return span / widest


## 建筑底座中心的世界 XZ。`anchor_world` = Model 给的左上角角点（building_x / building_z）。
static func center(tile: Dictionary, anchor_world: Vector2, spec: Dictionary) -> Vector2:
	var w := float(tile.get("w", 7.0))
	var d := float(tile.get("d", 7.0))
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	# 从角点沿格子本地轴往右下推 (0.5 + anchor_u) 格 = 左上象限中心
	var lx := (0.5 + float(spec.get("anchor_u", ANCHOR_U_DEFAULT))) * w
	var lz := (0.5 + float(spec.get("anchor_v", ANCHOR_V_DEFAULT))) * d
	var c := cos(yaw)
	var s := sin(yaw)
	return Vector2(anchor_world.x + lx * c + lz * s, anchor_world.y - lx * s + lz * c)


## 建筑朝向（度）：格子 yaw + 方位朝向增量。玩家侧正面朝 +Z。
static func yaw_deg(tile: Dictionary, spec: Dictionary, side: String) -> float:
	var facing := float(spec.get("facing_player_deg", FACING_PLAYER_DEFAULT)) \
		if side == "player" else float(spec.get("facing_enemy_deg", FACING_ENEMY_DEFAULT))
	return float(tile.get("yaw", 0.0)) + facing


## 一个格子边长（用于棋盘画"建筑位"标记的尺寸：标记大小跟着占地比例走）。
static func span_of(tile: Dictionary, ratio: float) -> float:
	return clampf(ratio, FOOTPRINT_MIN, FOOTPRINT_MAX) * minf(float(tile.get("w", 7.0)), float(tile.get("d", 7.0)))
