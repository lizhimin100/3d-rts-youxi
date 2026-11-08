extends RefCounted
## **体积 → 模型缩放 / 碰撞半径 / 判定圈半径 的唯一出口**
##
## 2026-11-08 玩家口径：
##   「卡上新增'体积'字段，体积是主参数，由我在卡上填；模型缩放、碰撞体积、
##     判定圈半径都从体积派生。」
##
## 所以卡上**只有一个数**要填（`volume`），别的都从这里算出来。
## 这张文件是唯一公式所在地：`UnitTable` 建 UnitDef 时调它一次，运行期只读结果。
##
## ---------------------------------------------------------------------------
## 判定圈半径的三种候选（★ 还没拍板，玩家要实测后选）
## ---------------------------------------------------------------------------
##   模式 1  半径 = 体积                  （体积写"半径米数"，0.5 就是半径 0.5m）
##   模式 2  半径 = 体积 ÷ 2              （体积写"直径米数"，0.5 就是半径 0.25m）
##   模式 3  体积只缩放模型，判定圈另填   （体积 1.0 = 标准体型，半径读卡上的数）
##
## 默认用 **模式 2**：现存卡的 body_radius 都在 0.42~0.58，
##   按"直径"填体积（0.84~1.16）读起来最像"这个兵多粗"，而且和旧数值逐项对得上
##   （体积 = 旧 body_radius × 2 → 派生回来的半径 == 旧值，改完没人变）。
##
## 切换方式：改 `MODE` 这一个常量（`--volume-test` 会把三种模式并排打出来给你挑）。
## **不要**在别处再写一遍公式。
const MODE_RADIUS_EQUALS_VOLUME := 1
const MODE_RADIUS_IS_HALF := 2
const MODE_SEPARATE := 3

## 当前生效的判定圈公式（待玩家拍板，先按"体积 = 直径"）
const MODE := MODE_RADIUS_IS_HALF

## 标定用的候选体积（`--volume-test` 打表用；单位是"标准体型 = 1.0"）
const SAMPLES: Array[float] = [0.6, 0.8, 0.9, 1.0, 1.1, 1.2, 1.4, 1.8, 2.4]

## 体积下限：小于它的体积一定是填错了（0 = 没填，走回退）
const VOLUME_MIN := 0.2

## **判定圈贴体余量**（2026-11-08 玩家拍板：选模式 2，但圈要"更贴切"）。
##
## 模式 2 的半径 = 体积 ÷ 2 = 旧 body_radius，正好压在模型轮廓上：
## 方块人的肩/披风比碰撞圆宽一点，圈画在 0.50 时会切进模型边缘。
## 乘 1.08 之后（步兵 0.54）圈刚好贴住轮廓 —— 圈内一定打得中、圈外看起来也说得通。
const JUDGE_MARGIN := 1.08


## **模型缩放**：体积就是"相对标准体型的倍数"，1.0 = 模型原尺寸。
## 这条三种模式都一样 —— 玩家要的是"体积大了模型就大"。
static func model_scale(volume: float) -> float:
	if volume <= 0.0:
		return 1.0
	return clampf(volume, VOLUME_MIN, 6.0)


## **碰撞半径**（推挤 / 寻路留缝用）。和判定圈同一把尺：
## 模式 3 时碰撞半径仍然按"半径 = 体积÷2"算（否则模式 3 的碰撞会退化成 0）。
static func body_radius(volume: float, fallback: float = 0.45) -> float:
	if volume <= 0.0:
		return fallback
	match MODE:
		MODE_RADIUS_EQUALS_VOLUME:
			return clampf(volume, 0.1, 4.0)
		_:
			return clampf(volume * 0.5, 0.1, 4.0)


## **判定圈半径**（命中判定 + 选中圈画多大）。
## separate_radius 只在模式 3 下生效（卡上另填的判定半径）。
static func judge_radius(volume: float, separate_radius: float = 0.5) -> float:
	return radius_for_mode(volume, MODE, separate_radius)


## 指定口径算半径（**唯一公式**；`judge_radius` 和标定工具都走这里，
## 不要在别处再抄一遍三种模式）。mode 传 1 / 2 / 3。
static func radius_for_mode(volume: float, mode: int, separate_radius: float = 0.5) -> float:
	if volume <= 0.0:
		return maxf(separate_radius, 0.1)
	match mode:
		MODE_RADIUS_EQUALS_VOLUME:
			return clampf(volume, 0.1, 4.0)
		MODE_RADIUS_IS_HALF:
			# 模式 2：体积写"直径"，半径 = 体积 ÷ 2，再乘贴体余量（见 JUDGE_MARGIN）
			return clampf(volume * 0.5 * JUDGE_MARGIN, 0.1, 4.0)
		_:
			return maxf(separate_radius, 0.1)


## 当前模式的中文名（自检 / 标定表用）
static func mode_name() -> String:
	match MODE:
		MODE_RADIUS_EQUALS_VOLUME:
			return "模式1 半径=体积"
		MODE_RADIUS_IS_HALF:
			return "模式2 半径=体积÷2"
		_:
			return "模式3 只缩放模型"


## 把三种模式并排算出来（`--volume-test` 打表）。
## 返回 [{体积, 模型缩放, 模式1半径, 模式2半径, 模式3半径}]
static func table() -> Array:
	var out: Array = []
	for v in SAMPLES:
		out.append({
			"体积": v,
			"模型缩放": model_scale(v),
			"模式1半径=体积": radius_for_mode(v, MODE_RADIUS_EQUALS_VOLUME),
			"模式2半径=体积÷2": radius_for_mode(v, MODE_RADIUS_IS_HALF),
			"模式3=另填": radius_for_mode(v, MODE_SEPARATE, v),
		})
	return out
