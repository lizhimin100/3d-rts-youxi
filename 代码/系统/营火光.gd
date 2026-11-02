extends OmniLight3D
## **营火光** —— 挂在营火那盏 OmniLight 上，负责"天黑才亮、白天几乎不亮"。
##
## 为什么需要它：OmniLight 本身不会看时间。如果常亮，白天的营地会在地上留一圈
## 暖黄光斑（和太阳光打架，看着像贴图错误）；如果彻底关掉，夜里又照不亮。
##
## 三条纪律：
##   1. **不新建节点、不改材质**：只改自己的 `light_energy`（和一点点抖动）；
##   2. 日夜节点靠**组名 "日夜"** 找（日夜.gd 在 setup 里 add_to_group），
##      不要 `get_node("../日夜")` —— 主场景改层级它就哑了；
##   3. 找不到日夜节点时**保持微亮**（0.35 基准），别让营火变成一根黑棍子。
##
## 用法（唯一入口）：`代码/美术/营火外观.gd` 造灯时 `set_script(营火光脚本)`。

## 深夜时的满功率
const NIGHT_ENERGY := 3.6
## 白天保留的一点点（火苗还有余烬，完全 0 会让"营火"看起来是熄灭的）
const DAY_RATIO := 0.10
## 找不到日夜系统时的兜底亮度比例
const FALLBACK_RATIO := 0.45
## 火光抖动幅度（±12%）与频率
const FLICKER := 0.12
const FLICKER_HZ := 3.1
## 表现层随机流（相位错开）。玩法随机仍走全局 randf，见 表现随机.gd
const Fx := preload("res://代码/美术/表现随机.gd")
## 刷新节流（秒）：光照缓变，10Hz 足够，省下每帧的属性写
const TICK := 0.1

var _t: float = 0.0
var _acc: float = 0.0
var _day: Node = null
var _phase: float = 0.0


func _ready() -> void:
	# 每盏灯错开一点相位，一排营火不会"整齐地一起闪"（那看起来像呼吸灯 bug）
	_phase = Fx.rand() * TAU
	light_color = Color(1.0, 0.62, 0.28)
	shadow_enabled = false
	omni_range = 13.5
	omni_attenuation = 1.15


func _process(delta: float) -> void:
	_t += delta
	_acc += delta
	if _acc < TICK:
		return
	_acc = 0.0
	var ratio: float = FALLBACK_RATIO
	if _day == null or not is_instance_valid(_day):
		_day = get_tree().get_first_node_in_group("日夜")
	if _day != null and _day.has_method("light_level"):
		# k = 1 白天 / 0 深夜 → 夜里给满功率
		ratio = lerpf(1.0, DAY_RATIO, float(_day.call("light_level")))
	var flick: float = 1.0 + sin(_t * TAU * FLICKER_HZ + _phase) * FLICKER
	light_energy = NIGHT_ENERGY * ratio * flick
