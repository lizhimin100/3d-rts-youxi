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

## 一整天的真实秒数。210 秒 ≈ 3.5 分钟：一局里能完整经历 3~5 个昼夜，
## 又不会让玩家"等天黑等到忘了在打 RTS"。
const DAY_LENGTH := 210.0
## 开局时刻：早上 7 点（t=0）。**不要设 6:00**：那一刻太阳刚出地平线，
## 画面暗得像阴天，玩家一进游戏会以为"游戏坏了"。
const START_HOUR := 7.0
## 夜晚区间（24 小时制）。20:00 入夜、05:30 破晓 —— 和野怪总攻同一口径。
const NIGHT_FROM := 20.0
const NIGHT_TO := 5.5

## 白天的光（与 主场景.tscn 里的主光完全一致，保证开局画面不变）
const DAY_SUN := Color(1.0, 0.94, 0.83)
const DAY_SUN_E := 2.35
const DAY_FILL := Color(0.46, 0.61, 0.95)
const DAY_FILL_E := 0.30
## 黄昏：橙红、低角度
const DUSK_SUN := Color(1.0, 0.55, 0.30)
## 夜里：冷蓝月光 + 抬高一档补光（否则全场纯黑，玩家什么都看不见）
const NIGHT_SUN := Color(0.42, 0.52, 0.86)
const NIGHT_SUN_E := 0.58
const NIGHT_FILL := Color(0.34, 0.45, 0.88)
const NIGHT_FILL_E := 0.92
const NIGHT_BG_E := 0.70

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
	_apply(true)


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
		_env.ambient_light_energy = lerpf(0.72, 1.0, k)


## 0 = 全黑（深夜），1 = 全亮（白天）。带 smoothstep，避免明暗切换"啪"一下
func _daylight(h: float) -> float:
	var k: float
	if h < 5.5 or h > 19.5:
		return 0.0
	elif h < 7.5:
		k = (h - 5.5) / 2.0
	elif h <= 17.5:
		k = 1.0
	else:
		k = (19.5 - h) / 2.0
	k = clampf(k, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


## 自检用：把时钟拨到指定小时（不推进 t）
func debug_set_hour(h: float) -> void:
	t = fmod((h - START_HOUR) / 24.0 + 1.0, 1.0)
	_apply(false)
