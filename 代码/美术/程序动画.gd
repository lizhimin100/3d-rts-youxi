class_name ProcAnim
extends Node
## 程序动画（ANVIL 提供）—— 按**部件节点名**驱动的类骨骼动画，不依赖 AnimationPlayer。
##
## 契约（条令 §9.2）：角色 GLB 里必须有
##   Root / Body / Torso / Head / ArmL / ForearmL / HandL / ArmR / ForearmR / HandR
##   LegL / ShinL / FootL / LegR / ShinR / FootR / Weapon / Shield
## **找不到的部件会静默跳过**——只有一个 mesh 的模型也能跑，不报错、不崩。
##
## 用法：
##   var pa := ProcAnim.new()
##   add_child(pa)
##   pa.bind(角色根节点)          # ArtKit 会自动调
##   pa.set_state("move", 1.0)    # idle / move / attack / cast / gather / build / death / hurt
##
## 实现方式（关键取舍）：全部走 `_process(delta)` 里的**相位时间 + sin**，
## 每帧把 offset 累加到 `_基准` 变换上。**不用 Tween**：
## Tween 一旦在跑就没法被新状态干净打断（会叠出中间态），RTS 里单位状态一秒能变三次，
## 相位法可以随时切、随时回，且零对象分配。

enum 状态 { 待机, 移动, 攻击, 施法, 采集, 建造, 死亡, 受击 }

const 状态名: Array[String] = ["idle", "move", "attack", "cast", "gather", "build", "death", "hurt"]

# ---------------------------------------------------------------- 可调幅度（@export）
@export_group("待机")
## 呼吸幅度（弧度）
@export var 待机呼吸: float = 0.055
## 呼吸速度（周期/秒）
@export var 待机频率: float = 1.15
## 待机时手臂轻晃幅度
@export var 待机臂摆: float = 0.055

@export_group("移动")
## 大腿摆幅（弧度）
@export var 移动腿摆: float = 0.62
## 小腿摆幅
@export var 移动膝摆: float = 0.72
## 手臂反相摆幅
@export var 移动臂摆: float = 0.52
## 躯干前倾
@export var 移动前倾: float = 0.10
## 上下弹跳幅度（米）
@export var 移动弹跳: float = 0.026
## 一个完整步态周期的频率
@export var 移动频率: float = 2.05

@export_group("攻击")
## 蓄力时长（秒）
@export var 攻击蓄力: float = 0.26
## 打击时长（要短、要脆）
@export var 攻击打击: float = 0.10
## 回收时长
@export var 攻击回收: float = 0.31
## 抬手高度
@export var 攻击抬臂: float = 1.85
## 下劈终点
@export var 攻击落臂: float = -0.55
## 躯干扭转幅度
@export var 攻击扭腰: float = 0.34

@export_group("施法")
@export var 施法抬臂: float = 2.15
@export var 施法颤抖: float = 0.05
@export var 施法时长: float = 1.25

@export_group("采集 / 建造")
## 镐头抡起高度
@export var 采集抬臂: float = 1.65
## 砸下终点
@export var 采集落臂: float = -0.42
@export var 采集频率: float = 1.45

@export_group("死亡 / 受击")
## 倒地角度
@export var 死亡前扑: float = 1.45
## 下沉距离
@export var 死亡下沉: float = 0.34
## 死亡耗时
@export var 死亡时长: float = 0.95
## 受击后仰幅度
@export var 受击后仰: float = 0.30
## 受击时长
@export var 受击时长: float = 0.34

# ---------------------------------------------------------------- 运行时
var _部件: Dictionary = {}          # String -> Node3D
var _基准位置: Dictionary = {}       # String -> Vector3
var _基准旋转: Dictionary = {}       # String -> Vector3
var _已绑定: bool = false
var _当前状态: int = 状态.待机
var _速度比: float = 1.0
var _相位: float = 0.0              # 主相位（sin 驱动）
var _状态时间: float = 0.0           # 进入当前状态后累计秒数
var _受击剩余: float = 0.0
var _过渡: float = 0.0              # 0..1，切换状态时的姿态混合

const 需要的部件: Array[String] = [
	"Body", "Torso", "Head",
	"ArmL", "ForearmL", "HandL", "ArmR", "ForearmR", "HandR",
	"LegL", "ShinL", "FootL", "LegR", "ShinR", "FootR",
	"Weapon", "Shield",
]


## 绑定角色根节点：按契约名递归找部件并记下基准变换。
func bind(root: Node3D) -> void:
	_部件.clear()
	_基准位置.clear()
	_基准旋转.clear()
	_已绑定 = false
	if root == null:
		return
	for nm in 需要的部件:
		var n := root.find_child(nm, true, false) as Node3D
		if n != null:
			_部件[nm] = n
			_基准位置[nm] = n.position
			_基准旋转[nm] = n.rotation
	_已绑定 = _部件.has("Torso") or _部件.has("Body")
	_复位()


## 切换状态。speed_ratio 影响相位推进速度（0.5 = 半速，1.6 = 快走）。
func set_state(state: String, speed_ratio: float = 1.0, force: bool = false) -> void:
	var idx: int = 状态名.find(state)
	if idx < 0:
		idx = 状态.待机
	_速度比 = clampf(speed_ratio, 0.05, 4.0)
	# force：强制从这一招的第 0 帧重来（连续挥砍要每一下都有动作）
	if idx != _当前状态 or force:
		_当前状态 = idx
		_状态时间 = 0.0
		_过渡 = 0.0
		if _当前状态 == 状态.受击:
			_受击剩余 = 受击时长


## 当前状态名（调试 / HUD 用）
func 当前状态名() -> String:
	return 状态名[_当前状态]


## 是否已成功绑定到模型
func 已绑定() -> bool:
	return _已绑定


func _process(delta: float) -> void:
	if not _已绑定:
		return
	var dt: float = delta * _速度比
	_状态时间 += dt
	_过渡 = minf(1.0, _过渡 + delta * 6.0)

	var 状态前 := _当前状态
	match _当前状态:
		状态.待机:
			_做待机(dt)
		状态.移动:
			_做移动(dt)
		状态.攻击:
			_做攻击()
		状态.施法:
			_做施法(dt)
		状态.采集, 状态.建造:
			_做采集(dt)
		状态.死亡:
			_做死亡(dt)
		状态.受击:
			_受击剩余 -= delta
			_做受击()
			if _受击剩余 <= 0.0:
				_当前状态 = 状态.待机
				_状态时间 = 0.0
	if 状态前 != _当前状态:
		_过渡 = 0.0


# ---------------------------------------------------------------- 各状态姿态
func _做待机(dt: float) -> void:
	_相位 += dt * TAU * 待机频率
	var s: float = sin(_相位)
	var s2: float = sin(_相位 * 0.63 + 1.1)
	# ★ 待机原来做得太细（躯干位移只有 1.6 毫米），玩家根本看不出来，
	#   被投诉"待机跟没切一样"。这里把幅度提到**肉眼可见**：
	#   躯干起伏 ~1.4cm、俯仰 ~3°、脑袋左右看 ~6°、手臂摆 ~5°。
	var dip: float = 1.0 - cos(_相位)          # 0..2，模拟吸气快呼气慢
	var soft: float = pow(dip * 0.5, 0.7)      # 非线性呼吸曲线
	_加位置Y("Torso", 0.014 * soft)
	_加旋转("Torso", 0.055 * (soft - 0.5) + 0.015, 0.0, 0.02 * s2)
	_加旋转("Head", -0.03 * (soft - 0.5), 0.10 * s2, 0.0)
	_加旋转("ArmL", 0.09 * s * 0.6, 0.0, -0.10)
	_加旋转("ArmR", -0.09 * s * 0.6, 0.0, 0.10)
	_加旋转("ForearmL", 0.10 + 0.07 * s2, 0.0, 0.0)
	_加旋转("ForearmR", 0.10 - 0.07 * s2, 0.0, 0.0)
	# 腿微微屈伸，别像两根柱子
	_加旋转("LegL", 0.02 * soft, 0.0, 0.0)
	_加旋转("LegR", 0.02 * soft, 0.0, 0.0)


func _做移动(dt: float) -> void:
	_相位 += dt * TAU * 移动频率
	var p: float = _相位
	var s: float = sin(p)
	var c: float = cos(p)
	# 腿：大腿正摆 → 小腿带相位差屈膝（两段式，这是"像走路"的关键）
	_加旋转("LegL", 移动腿摆 * s, 0.0, 0.0)
	_加旋转("LegR", -移动腿摆 * s, 0.0, 0.0)
	_加旋转("ShinL", -移动膝摆 * maxf(0.0, sin(p - 0.85)), 0.0, 0.0)
	_加旋转("ShinR", -移动膝摆 * maxf(0.0, sin(p + PI - 0.85)), 0.0, 0.0)
	_加旋转("FootL", -移动腿摆 * 0.35 * s, 0.0, 0.0)
	_加旋转("FootR", 移动腿摆 * 0.35 * s, 0.0, 0.0)
	# 手臂反相
	_加旋转("ArmL", -移动臂摆 * s * 0.85, 0.0, -0.06)
	_加旋转("ArmR", 移动臂摆 * s * 0.85, 0.0, 0.06)
	_加旋转("ForearmL", 0.22 + 0.18 * maxf(0.0, -s), 0.0, 0.0)
	_加旋转("ForearmR", 0.22 + 0.18 * maxf(0.0, s), 0.0, 0.0)
	# 躯干：前倾 + 每步一次弹跳（2 倍频）+ 侧摆
	_加旋转("Torso", 移动前倾, 0.0, 0.055 * c)
	_加位置Y("Torso", 移动弹跳 * absf(s))
	_加位置Y("Body", 移动弹跳 * 0.35 * absf(s))
	_加旋转("Head", -移动前倾 * 0.55, -0.06 * c, 0.0)


func _做攻击() -> void:
	var t: float = _状态时间
	var 蓄: float = maxf(0.01, 攻击蓄力)
	var 打: float = maxf(0.01, 攻击打击)
	var 收: float = maxf(0.01, 攻击回收)
	var 总: float = 蓄 + 打 + 收
	# ★ 一次攻击只挥**一刀**（2026-11-07 玩家口径：不要"快速砍两刀三刀"）。
	#   旧版用 fmod(t, 总) → 只要 state 停在 ATTACK 就一直循环挥砍，
	#   攻击间隔比动作长时会连着挥 2~3 刀，看起来像"这个兵有好几种攻击"。
	#   现在钳到 [0, 总]：挥完就停在收势，等下一次 _begin_swing 的 force 重播。
	var 循环时间: float = clampf(t, 0.0, 总)
	var 臂角: float = 0.0
	var 腰角: float = 0.0
	if 循环时间 < 蓄:
		# 蓄力：慢（ease-out），抬到最高、向后拧腰
		var u: float = 循环时间 / 蓄
		var e: float = 1.0 - pow(1.0 - u, 2.0)
		臂角 = lerpf(0.0, 攻击抬臂, e)
		腰角 = lerpf(0.0, -攻击扭腰, e)
	elif 循环时间 < 蓄 + 打:
		# 打击：极快（ease-in 的平方），从最高点砸到落点
		var u: float = (循环时间 - 蓄) / 打
		var e: float = u * u
		臂角 = lerpf(攻击抬臂, 攻击落臂, e)
		腰角 = lerpf(-攻击扭腰, 攻击扭腰 * 0.85, e)
	else:
		# 回收
		var u: float = (循环时间 - 蓄 - 打) / 收
		var e: float = u * u * (3.0 - 2.0 * u)
		臂角 = lerpf(攻击落臂, 0.0, e)
		腰角 = lerpf(攻击扭腰 * 0.85, 0.0, e)
	_加旋转("ArmR", 臂角, 0.0, 0.0)
	_加旋转("ForearmR", -minf(臂角, 0.9) * 0.25 + 0.10, 0.0, 0.0)
	_加旋转("Torso", -腰角 * 0.30, 腰角, 0.0)
	_加旋转("Head", 0.06, 腰角 * 0.4, 0.0)
	_加旋转("ArmL", 腰角 * 0.35, 0.0, -0.30)
	_加位置Y("Body", -0.02 * absf(腰角))


func _做施法(dt: float) -> void:
	var t: float = _状态时间
	var 抬: float = minf(1.0, t / 0.35)
	抬 = 1.0 - pow(1.0 - 抬, 2.0)
	var 颤: float = sin(t * 26.0) * 施法颤抖 * 抬
	var 释放: float = 0.0
	if 施法时长 > 0.4 and t > 施法时长 - 0.28:
		释放 = (t - (施法时长 - 0.28)) / 0.28
	_加旋转("ArmR", lerpf(0.0, 施法抬臂, 抬) + 颤, 0.0, 0.0)
	_加旋转("ForearmR", lerpf(0.10, -0.20, 抬), 0.0, 0.0)
	_加旋转("ArmL", lerpf(0.0, 0.55, 抬), 0.0, -0.42 * 抬)
	_加旋转("ForearmL", lerpf(0.0, 0.85, 抬), 0.0, 0.0)
	_加旋转("Torso", -0.10 * 抬 - 释放 * 0.12, 0.0, 0.0)
	_加旋转("Head", -0.16 * 抬, 0.0, 0.0)
	_加位置Y("Body", 0.02 * 抬 * sin(t * 5.0))


func _做采集(dt: float) -> void:
	_相位 += dt * TAU * 采集频率
	var p: float = _相位
	# 抡镐：0..0.55 抬（慢），0.55..0.85 砸（快），0.85..1 回（中）
	var u: float = fmod(p / TAU, 1.0)
	var 臂: float = 0.0
	if u < 0.55:
		var k: float = u / 0.55
		臂 = lerpf(0.0, 采集抬臂, 1.0 - pow(1.0 - k, 2.0))
	elif u < 0.85:
		var k2: float = (u - 0.55) / 0.30
		臂 = lerpf(采集抬臂, 采集落臂, k2 * k2)
	else:
		var k3: float = (u - 0.85) / 0.15
		臂 = lerpf(采集落臂, 0.0, k3 * k3 * (3.0 - 2.0 * k3))
	_加旋转("ArmR", 臂, 0.0, 0.0)
	_加旋转("ArmL", 臂 * 0.82, 0.0, 0.24)
	_加旋转("ForearmR", 0.14 - 0.22 * maxf(0.0, sin(u * PI)), 0.0, 0.0)
	_加旋转("ForearmL", 0.20, 0.0, 0.0)
	_加旋转("Torso", -0.16 * sin(u * TAU) + 0.10, 0.0, 0.0)
	_加旋转("Head", 0.18, 0.0, 0.0)
	_加旋转("LegL", 0.10, 0.0, 0.0)
	_加旋转("LegR", -0.10, 0.0, 0.0)


func _做死亡(dt: float) -> void:
	var u: float = clampf(_状态时间 / maxf(0.05, 死亡时长), 0.0, 1.0)
	var e: float = u * u * (3.0 - 2.0 * u)
	_加旋转("Body", 死亡前扑 * e, 0.0, 0.30 * e)
	_加位置Y("Body", -死亡下沉 * e)
	_加旋转("Torso", 0.22 * e, 0.0, 0.0)
	_加旋转("Head", 0.34 * e, 0.0, 0.20 * e)
	_加旋转("ArmL", -0.55 * e, 0.0, -0.45 * e)
	_加旋转("ArmR", -0.65 * e, 0.0, 0.40 * e)
	_加旋转("LegL", 0.28 * e, 0.0, 0.0)
	_加旋转("LegR", 0.16 * e, 0.0, 0.0)
	_加旋转("ShinL", -0.45 * e, 0.0, 0.0)


func _做受击() -> void:
	var u: float = 1.0 - clampf(_受击剩余 / maxf(0.05, 受击时长), 0.0, 1.0)
	# 前 30% 猛后仰，之后弹性回位（越到后面衰减越快）
	var 衰减: float = pow(1.0 - u, 2.0)
	var 抖: float = sin(u * 46.0) * 0.35 + 1.0
	_加旋转("Torso", -受击后仰 * 衰减 * 抖, 0.0, 0.12 * 衰减 * sin(u * 30.0))
	_加旋转("Head", -受击后仰 * 1.2 * 衰减, 0.0, 0.16 * 衰减)
	_加旋转("ArmL", -受击后仰 * 0.6 * 衰减, 0.0, -0.20 * 衰减)
	_加旋转("ArmR", -受击后仰 * 0.5 * 衰减, 0.0, 0.20 * 衰减)
	_加位置Y("Body", -0.02 * 衰减)


# ---------------------------------------------------------------- 变换读写
func _复位() -> void:
	for nm in _部件.keys():
		var n: Node3D = _部件[nm]
		n.position = _基准位置[nm]
		n.rotation = _基准旋转[nm]


func _加旋转(部件: String, rx: float, ry: float, rz: float) -> void:
	var n: Node3D = _部件.get(部件)
	if n == null:
		return
	var b: Vector3 = _基准旋转[部件]
	# 直接赋值（基准 + 偏移），不做插值：相位本身连续，插值反而会吃掉打击帧的脆感
	n.rotation = Vector3(b.x + rx, b.y + ry, b.z + rz)


func _加位置Y(部件: String, dy: float) -> void:
	var n: Node3D = _部件.get(部件)
	if n == null:
		return
	var b: Vector3 = _基准位置[部件]
	n.position = Vector3(b.x, b.y + dy, b.z)
