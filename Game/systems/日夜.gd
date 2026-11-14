class_name RtsDayNight
extends Node
## **日夜循环** —— 只管光：主光（太阳/月亮）的颜色与强度、补光、背景能量。
##
## 为什么要它：玩家 2026-11-01 要求"每到晚上（日夜系统）野怪会出现一大批进攻所有玩家"。
## 那就必须有一个**玩家看得见、能预期**的昼夜节律，而不是悄悄刷一波怪。
##
## 三条纪律：
##   1. 只改 `DirectionalLight3D` 与 `Environment` 的少量参数，**不建任何新节点**；
##   2. 时间用"一天 = DAY_LENGTH 秒"的归一化 t（0=清晨 06:00），
##      `hour()` 是唯一的口径出口，别的地方不要再自己算；
##   3. 夜色只在**光照**上表达，不动地形/材质的颜色 —— 换色夜间会把建筑图集搞花。

signal night_started
signal day_started

## 一整天的真实秒数。**360 秒 = 6 分钟走完一次昼夜**（玩家 2026-11-08 口径）。
## 旧值 210s（3.5 分钟）在长局里昼夜切换太碎，玩家来不及"打完一波再收队"。
const DAY_LENGTH := 360.0
## 开局时刻：早上 7 点（t=0）。**不要设 6:00**：那一刻太阳刚出地平线，
## 画面暗得像阴天，玩家一进游戏会以为"游戏坏了"。
const START_HOUR := 7.0
## 夜晚区间（24 小时制）。20:00 入夜、06:00 破晓 —— 和野怪总攻同一口径。
const NIGHT_FROM := 20.0
const NIGHT_TO := 6.0

## ---------------------------------------------------------------------------
## 过渡段（2026-11-01 玩家口径："黄昏太短、晚上太黑"）
## ---------------------------------------------------------------------------
## 破晓 / 黄昏各占 **3 小时**（= 26 秒真实时间，一整天的 12.5%）。
## 以前各 2 小时（17.5s），玩家原话"黄昏一带而过"—— 抬到 3 小时后，
## 天色从金橙慢慢压到深蓝，白天/夜晚之间有了"预告"，夜袭不再是突然黑屏。
## ★ 这两个常数是**唯一口径**：`_daylight()` / `is_night()` / HUD 倒计时全从这里推，
##   不要在别的脚本里再写一遍 17 / 20 这种数字。
const DAWN_START := 5.0
const DAWN_END := 8.0
const DUSK_START := 17.0
const DUSK_END := 20.0

## 白天的光（与 主场景.tscn 里的主光完全一致，保证开局画面不变）
const DAY_SUN := Color(1.0, 0.94, 0.83)
const DAY_SUN_E := 2.35
const DAY_FILL := Color(0.46, 0.61, 0.95)
const DAY_FILL_E := 0.30
## 黄昏：**金橙**，不是"红滤镜"。
## 第一版用了 (1.0, 0.55, 0.30)，配上地表本来的红棕泥土，整张地图像泡在血里
## （2026-11-01 实测截图：地面全红、单位看不清）。饱和度和亮度必须往"夕阳"调，
## 让地表原有的黄绿/土黄还在，只是被镀了一层暖光。
const DUSK_SUN := Color(1.0, 0.74, 0.52)
## 夜里：冷蓝月光 + 抬高一档补光。
## ★ 2026-11-01 调亮（0.58/0.92/0.70 → 1.05/1.25/0.88）：
##   玩家原话"晚上太黑了、看不见"，而夜晚的目的是**渲染氛围**，不是"关灯惩罚"。
##   判据是"能看清兵种颜色和地形纹路"，不是"和白天一样亮"——
##   所以主光仍然是冷蓝、能量只有白天的 45%，只是把黑压压的暗部抬起来。
const NIGHT_SUN := Color(0.56, 0.68, 1.00)
const NIGHT_SUN_E := 1.18
const NIGHT_FILL := Color(0.42, 0.55, 0.98)
const NIGHT_FILL_E := 1.25
const NIGHT_BG_E := 0.92
## 夜里环境光下限（白天 = 1.0）。0.85 是"暗但有层次"的临界点：
## 再低，建筑阴影里的细节就糊成一片黑。
const NIGHT_AMBIENT_E := 0.90

var t: float = 0.0
var _night: bool = false
var _sun: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _env: Environment = null
var _bg_e: float = 1.0
var _apply_t: float = 0.0
var _ready_ok: bool = false


## 挂到主场景：传三盏灯的引用（缺哪个就跳过哪个，绝不报错）
func setup(sun: DirectionalLight3D, fill: DirectionalLight3D, world_env: WorldEnvironment) -> void:
	_sun = sun
	_fill = fill
	if world_env != null and world_env.environment != null:
		# ★ 必须 duplicate：战斗环境.tres 是共享资源，直接改会把编辑器里的资源一起改掉。
		_env = world_env.environment.duplicate() as Environment
		world_env.environment = _env
		_bg_e = _env.background_energy_multiplier
	t = 0.0
	_ready_ok = true
	# 营火 / 火把 / 其它需要"天黑才点亮"的东西都靠这个组找本节点，
	# **不要**去 `get_node("../日夜")`：主场景改层级它们就全哑了。
	add_to_group("日夜")
	_apply(true)


## 当前"白昼程度"：1 = 正午，0 = 深夜（营火亮度、UI 提示都读它）
func light_level() -> float:
	return _daylight(hour())


func _process(delta: float) -> void:
	if not _ready_ok:
		return
	t = fmod(t + delta / maxf(DAY_LENGTH, 1.0), 1.0)
	# 10Hz 刷新足够（光照是缓变的），省下每帧三次属性写 + 阴影更新
	_apply_t += delta
	if _apply_t < 0.1:
		return
	_apply_t = 0.0
	_apply(false)


## 当前时刻（0~24 小时）
func hour() -> float:
	return fmod(START_HOUR + t * 24.0, 24.0)


## 是不是夜里（野怪总攻窗口）
func is_night() -> bool:
	var h: float = hour()
	return h >= NIGHT_FROM or h < NIGHT_TO


## 顶部资源条用的时刻文本："06:30 ☀" / "21:10 ☾"
func clock_text() -> String:
	var h: float = hour()
	var hh: int = int(floor(h))
	var mm: int = int(floor((h - float(hh)) * 60.0))
	return "%02d:%02d %s" % [hh, mm, "☾" if is_night() else "☀"]


## 距离天黑还有多少秒（白天）/ 距离天亮还有多少秒（夜里）。
## HUD 用它提示"还有 40 秒天黑，准备防守"。
func seconds_to_turn() -> float:
	var h: float = hour()
	var target_h: float = NIGHT_FROM if not is_night() else NIGHT_TO
	var delta_h: float = target_h - h
	if delta_h < 0.0:
		delta_h += 24.0
	return delta_h / 24.0 * DAY_LENGTH


## 把当前时刻写进三盏灯
func _apply(first: bool) -> void:
	var night_now: bool = is_night()
	if night_now != _night:
		_night = night_now
		if not first:
			if _night:
				night_started.emit()
			else:
				day_started.emit()

	var h: float = hour()
	# 亮度曲线（**不要用 sin 太阳高度**）：sin 在 6:00 是 0、8:00 才 0.5，
	# 于是"早上七点"只有 17% 亮度 —— 一进游戏整张地图是黑的（第一版就翻在这）。
	# 现实里日出后一小时就足够亮，所以这里用"5:30 破晓 → 7:30 全亮 → 17:30 转暗 → 19:30 全黑"。
	var k: float = _daylight(h)
	if _sun != null:
		var col: Color
		if k >= 0.35:
			col = DUSK_SUN.lerp(DAY_SUN, clampf((k - 0.35) / 0.65, 0.0, 1.0))
		else:
			col = NIGHT_SUN.lerp(DUSK_SUN, clampf(k / 0.35, 0.0, 1.0))
		_sun.light_color = col
		# 能量用 pow(k,0.6)：亮度在"刚破晓"那段爬起来更快，不会半天都是灰的
		_sun.light_energy = lerpf(NIGHT_SUN_E, DAY_SUN_E, pow(k, 0.6))
		# ★ **不动朝向**：主光的角度是 .tscn 里按美术机位摆好的，
		#   跟着时间转会把影子甩到奇怪的方向（夜里甚至从地底打光）。
		#   昼夜只靠颜色 + 强度表达，这是 RTS 里最稳的做法。
	if _fill != null:
		_fill.light_color = DAY_FILL.lerp(NIGHT_FILL, 1.0 - k)
		_fill.light_energy = lerpf(NIGHT_FILL_E, DAY_FILL_E, k)
	if _env != null:
		_env.background_energy_multiplier = lerpf(NIGHT_BG_E, _bg_e, k)
		_env.ambient_light_energy = lerpf(NIGHT_AMBIENT_E, 1.0, k)


## 0 = 全黑（深夜），1 = 全亮（白天）。带 smoothstep，避免明暗切换"啪"一下。
##
## 四段（全部来自上面的 DAWN_*/DUSK_*，别在这里写死数字）：
##   05:00 之前 / 20:00 之后 → 0（夜里）
##   05:00 → 08:00           → 0 爬升到 1（破晓，3 小时）
##   08:00 → 17:00           → 1（白天）
##   17:00 → 20:00           → 1 压到 0（黄昏，3 小时）
func _daylight(h: float) -> float:
	var k: float
	if h < DAWN_START or h > DUSK_END:
		return 0.0
	elif h < DAWN_END:
		k = (h - DAWN_START) / (DAWN_END - DAWN_START)
	elif h <= DUSK_START:
		k = 1.0
	else:
		k = (DUSK_END - h) / (DUSK_END - DUSK_START)
	k = clampf(k, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


## 自检用：把时钟拨到指定小时（不推进 t）
func debug_set_hour(h: float) -> void:
	t = fmod((h - START_HOUR) / 24.0 + 1.0, 1.0)
	_apply(false)
