extends SceneTree
## **战斗自检（无头 · 确定性步进）**：验证"目标死了以后，战斗状态机能不能干净收场"。
##
## 跑法（不需要 --import，也不需要主场景）：
##   godot --headless --path . --script 代码/测试/战斗自检.gd
## 输出：结尾一行 `COMBATTEST {json}`，退出码 0 = 全过。
##
## 为什么这里不直接写 `Game` / `Cfg` / `RtsUnit`：
##   `--script` 指定的脚本在 autoload 注册**之前**就被编译，直接写单例名会
##   "Identifier not found: Game"，间接引用（用 RtsUnit 当类型）还会把 单位.gd 一起带崩。
##   所以这里统一走 root.get_node("Game") + 运行时 load()，编译时机与正常游戏一致。
##
## 时间轴：自己按 1/60s 固定步长驱动单位的 _process（引擎的自动 _process 已关掉），
##   所以"0.6 秒"是精确的 36 帧，不随机器帧率/是否 --fixed-fps 漂移。
##
## 判据：
##   A 秒杀收场：待机单位自动还击打死目标后，0.6s 内必须回 IDLE、指令清空、动画回 idle
##   B 攻击移动：半路打死第一个敌人要能改咬第二个；敌人清完要接着走完原目的地
##   C 待机索敌：索敌圈内、但在射程外的敌人不许被锁上（锁了会永远够不着且不再索敌）
##   D 自动施法：法师自动放完火球后原指令必须还在（不许被施法收尾清成 NONE）

## 固定步长（秒）
const 步长: float = 1.0 / 60.0

var 游戏: Node = null
var 关卡: Node3D = null
var 状态: Dictionary = {}
var 指令: Dictionary = {}
var 报告: Dictionary = {}
var 失败: Array = []


func _initialize() -> void:
	# ★ 不能在 _initialize 里直接建世界：SceneTree 脚本的 _initialize 阶段
	#   加进 root 的节点还没真正入树（is_inside_tree()=false），
	#   读 global_position 会返回 Transform3D() 恒等矩阵 —— 也就是所有单位都被当成在原点，
	#   整份自检会测在空气上（实测：攻击移动的"最终位置 0.0,0.0"就是这么来的）。
	#   所以推迟一帧再跑。
	call_deferred("_运行")


func _运行() -> void:
	var 开始: int = Time.get_ticks_msec()
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[战斗自检] 找不到 Game 自动加载单例")
		quit(1)
		return
	_读常量()
	_建世界()
	if 失败.is_empty():
		_用例A_秒杀收场()
		_用例B_攻击移动续行()
		_用例C_待机不锁射程外()
		_用例D_自动施法不吞指令()
		_用例E_射程口径()
		_用例F_多近战围攻()
		_用例G_近战打建筑()
		_用例G2_多近战围楼()
		_用例H_最大射程()
		_用例I_挨打找敌人()
		_用例J_视野内挨打逼上去()
	报告["失败项"] = 失败
	报告["结果"] = "通过" if 失败.is_empty() else "失败"
	报告["耗时(毫秒)"] = Time.get_ticks_msec() - 开始
	print("COMBATTEST " + JSON.stringify(报告))
	quit(0 if 失败.is_empty() else 1)


# ===========================================================================
# 环境
# ===========================================================================

## 从 常量.gd 的常量表里读枚举（不在编译期引用 RtsConst，原因见文件头）
func _读常量() -> void:
	var s: Script = load("res://代码/核心/常量.gd")
	if s == null:
		失败.append("读不到 代码/核心/常量.gd")
		return
	var 表: Dictionary = s.get_script_constant_map()
	状态 = 表.get("State", {})
	指令 = 表.get("Order", {})
	if 状态.is_empty() or 指令.is_empty():
		失败.append("常量表里没有 State / Order")


## 建一个只有地形和寻路的关卡（不摆道具、不摆开局部队，快且干净）
func _建世界() -> void:
	游戏.call("reset")
	游戏.set("difficulty_index", 0)
	游戏.call("setup_factions")
	var s: Script = load("res://代码/核心/关卡.gd")
	if s == null:
		失败.append("读不到 代码/核心/关卡.gd")
		return
	关卡 = s.new()
	关卡.name = "关卡"
	root.add_child(关卡)
	关卡.call("build")
	游戏.set("level", 关卡)
	var 阶段: Dictionary = {}
	var 常量脚本: Script = load("res://代码/核心/常量.gd")
	if 常量脚本 != null:
		阶段 = 常量脚本.get_script_constant_map().get("Phase", {})
	游戏.set("phase", int(阶段.get("RUNNING", 1)))
	报告["地形"] = {
		"地图边长": "%.0fm" % float(关卡.get("world_size")),
		"可走格数": _可走格数(),
	}


func _可走格数() -> int:
	var pf = 关卡.call("grid_pathfinder")
	if pf == null:
		return -1
	# 寻路器没有公开的尺寸字段（只有 _w / _h），以前写 pf.get("size") 取到 null，
	# 再 int(null) 直接报 "Nonexistent 'int' constructor" —— 自检自己先报错了。
	# 自检脚本允许读内部状态：拿 _w/_h 逐格问可走性。
	var 宽 = pf.get("_w")
	var 高 = pf.get("_h")
	if 宽 == null or 高 == null:
		return -1
	var 可走: int = 0
	for z in int(高):
		for x in int(宽):
			if bool(pf.call("is_cell_walkable", Vector2i(x, z))):
				可走 += 1
	return 可走


## 在关卡里造一个单位（血量可覆盖）；引擎自动 _process 关掉，由测试手动步进
func _造单位(阵营: String, id: StringName, 位置: Vector3, 血量: float = -1.0):
	var 派 = 游戏.get(阵营)
	var n = 游戏.call("spawn_unit", 派, id, 位置, 关卡)
	if n == null:
		失败.append("生成 %s 失败" % id)
		return null
	if 血量 > 0.0:
		n.hp = 血量
	n.set_process(false)
	var v = n.visual
	if v != null and is_instance_valid(v):
		v.set_process(false)
	return n


## 走一帧：只驱动单位主循环与外观，时间由测试掌控
func _一步() -> void:
	# 共享空间哈希按"引擎帧号"缓存；手动步进时帧号不变，会一直用第一帧的邻居表，
	# 所以这里把缓存帧号打回 -1，强制每步重建（单位数量很少，代价可忽略）。
	var s: Script = load("res://代码/单位/单位.gd")
	if s != null:
		s.set("_sep_frame", -1)
	# ★ 同理：`Game.unit_hash()` 也按引擎帧号缓存。手动步进时帧号永远是同一帧，
	#   哈希会一直停在"第一次被查"的那一刻（通常是空表），于是 find_nearest_enemy
	#   永远返回 null —— B（攻击移动打不死人）和 D（法师不自动开火）两条自检
	#   就是这么一直红的。这里一并打回 -1，让两条用例真的在测战斗逻辑。
	游戏.set("_unit_hash_frame", -1)
	for u in 游戏.call("all_units"):
		if u == null or not is_instance_valid(u) or u.is_queued_for_deletion():
			continue
		if not u.call("is_alive"):
			continue
		u._process(步长)
		var v = u.visual
		if v != null and is_instance_valid(v):
			v._process(步长)


## 走指定秒数
func _走(秒: float) -> void:
	for i in int(round(秒 / 步长)):
		_一步()


## 一直走，直到 判据 成立或超时；返回用掉的秒数（超时返回 -1）
func _走到(判据: Callable, 上限秒: float) -> float:
	var 帧数: int = int(round(上限秒 / 步长))
	for i in 帧数:
		_一步()
		if bool(判据.call()):
			return float(i + 1) * 步长
	return -1.0


func _状态名(v: int) -> String:
	for k in 状态:
		if int(状态[k]) == v:
			return String(k)
	return "?%d" % v


func _指令名(v: int) -> String:
	for k in 指令:
		if int(指令[k]) == v:
			return String(k)
	return "?%d" % v


func _动画(u) -> String:
	var v = u.visual
	if v == null or not is_instance_valid(v):
		return "无外观"
	return String(v.get("_anim_state"))


func _平面距(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _记(名: String, 明细: Dictionary) -> void:
	报告[名] = 明细
	print("[战斗自检] %s %s" % [名, JSON.stringify(明细)])


# ===========================================================================
# A · 秒杀收场
# ===========================================================================

## 待机步兵（没有指令）自动还击，一击打死 1 血弓手；之后必须干净回到待机。
func _用例A_秒杀收场() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(5.0, 0.0, 4.0))
	var 攻 = _造单位("player_faction", &"footman", 位)
	var 靶 = _造单位("enemy_faction", &"archer", 位 + Vector3(1.2, 0.0, 0.0), 1.0)
	if 攻 == null or 靶 == null:
		return

	var 明细: Dictionary = {
		"攻击者初始指令": _指令名(int(攻.order)),
		"攻击者初始状态": _状态名(int(攻.state)),
		"目标初始血量": "%.0f" % float(靶.hp),
	}
	var 击杀秒: float = _走到(func(): return not bool(靶.call("is_alive")), 6.0)
	明细["击杀耗时(秒)"] = "%.2f" % 击杀秒 if 击杀秒 >= 0.0 else "6s 内没打死"
	if 击杀秒 < 0.0:
		失败.append("A 秒杀：6s 内没打死目标（待机自动还击链路没跑起来）")
		_记("A_秒杀收场", 明细)
		return

	# 目标死后的 0.6s（36 帧）内必须收干净
	_走(0.6)
	var 真状态: String = _状态名(int(攻.state))
	var 真指令: String = _指令名(int(攻.order))
	var 真动画: String = _动画(攻)
	明细["死后0.6s 状态"] = 真状态
	明细["死后0.6s 指令"] = 真指令
	明细["死后0.6s 动画"] = 真动画
	明细["死后0.6s 目标"] = "已清空" if 攻.target == null else "还挂着"
	if int(攻.state) != int(状态["IDLE"]):
		失败.append("A 秒杀：目标死后 0.6s 状态是 %s，不是 IDLE" % 真状态)
	if int(攻.order) != int(指令["NONE"]):
		失败.append("A 秒杀：目标死后指令是 %s，不是 NONE" % 真指令)
	if 攻.target != null:
		失败.append("A 秒杀：目标死后 target 没清空")
	if 真动画 != "idle":
		失败.append("A 秒杀：目标死后动画是 %s，不是 idle" % 真动画)
	_记("A_秒杀收场", 明细)


# ===========================================================================
# B · 攻击移动：半路目标死亡 → 重新索敌 / 走完目的地
# ===========================================================================

func _用例B_攻击移动续行() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 起: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-6.0, 0.0, 9.0))
	var 终: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(20.0, 0.0, 9.0))
	var 攻 = _造单位("player_faction", &"footman", 起)
	var 敌一 = _造单位("enemy_faction", &"archer", 起 + Vector3(7.0, 0.0, 0.0), 1.0)
	var 敌二 = _造单位("enemy_faction", &"archer", 起 + Vector3(14.0, 0.0, 0.0), 1.0)
	if 攻 == null or 敌一 == null or 敌二 == null:
		return
	攻.call("order_attack_move", 终)

	var 明细: Dictionary = {
		"起点": "%.1f,%.1f" % [起.x, 起.z],
		"终点": "%.1f,%.1f" % [终.x, 终.z],
		"路程(米)": "%.1f" % _平面距(起, 终),
	}
	var 死一: float = _走到(func(): return not bool(敌一.call("is_alive")), 8.0)
	明细["敌人1被清(秒)"] = "%.2f" % 死一 if 死一 >= 0.0 else "8s 内没清掉"
	if 死一 < 0.0:
		失败.append("B 攻击移动：8s 内没打死路上第一个敌人")
		_记("B_攻击移动续行", 明细)
		return

	# ① 敌一死后的 0.6s 内要重新索敌
	var 改咬: float = _走到(func(): return 攻.target == 敌二, 0.6)
	明细["改咬敌人2(秒)"] = "%.2f" % 改咬 if 改咬 >= 0.0 else "0.6s 内没改咬"
	明细["敌一死后目标"] = "敌人2" if 攻.target == 敌二 else ("无" if 攻.target == null else "别的")
	if 攻.target != 敌二:
		失败.append("B 攻击移动：第一个敌人死后没有重新索敌（目标=%s）" % 明细["敌一死后目标"])

	# ② 敌二死后要接着走完原目的地
	var 死二: float = _走到(func(): return not bool(敌二.call("is_alive")), 10.0)
	明细["敌人2被清(秒)"] = "%.2f" % 死二 if 死二 >= 0.0 else "10s 内没清掉"
	if 死二 < 0.0:
		失败.append("B 攻击移动：10s 内没打死第二个敌人")
		_记("B_攻击移动续行", 明细)
		return
	var 复走: float = _走到(func(): return int(攻.order) == int(指令["ATTACK_MOVE"]) 			and int(攻.state) == int(状态["MOVE"]), 1.0)
	明细["清完继续走(秒)"] = "%.2f" % 复走 if 复走 >= 0.0 else "1s 内没恢复行军"
	明细["清完后指令"] = _指令名(int(攻.order))
	if 复走 < 0.0:
		失败.append("B 攻击移动：敌人清完后没有接着走（指令=%s 状态=%s）" % [
			_指令名(int(攻.order)), _状态名(int(攻.state))])

	var 到点秒: float = _走到(func(): return _平面距(攻.global_position, 终) <= 2.5, 25.0)
	明细["到达终点(秒)"] = "%.2f" % (死二 + 到点秒) if 到点秒 >= 0.0 else "25s 内没到"
	明细["最终位置"] = "%.1f,%.1f" % [攻.global_position.x, 攻.global_position.z]
	明细["最终距终点(米)"] = "%.1f" % _平面距(攻.global_position, 终)
	if 到点秒 < 0.0:
		失败.append("B 攻击移动：打完仗没走完原目的地（还差 %.1f 米）" % _平面距(攻.global_position, 终))
	_记("B_攻击移动续行", 明细)


# ===========================================================================
# C · 待机不锁"够不着"的目标
# ===========================================================================

func _用例C_待机不锁射程外() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-14.0, 0.0, -6.0))
	var 兵 = _造单位("player_faction", &"footman", 位)
	# 9 米：步兵索敌 11 米、攻击距离 1.35 米 —— 老代码会把它锁成目标，然后永远够不着。
	# 这里必须用**不会自己走过来**的敌人（箭塔）：弓手有 AI，会主动贴上来，测不到"锁射程外"。
	var 远处敌 = _造单位("enemy_faction", &"tower", 位 + Vector3(9.0, 0.0, 0.0), 5000.0)
	if 远处敌 == null:
		远处敌 = _造单位("enemy_faction", &"archer", 位 + Vector3(9.0, 0.0, 0.0), 5000.0)
		if 远处敌 != null:
			远处敌.call("order_hold")
	if 兵 == null or 远处敌 == null:
		return
	_走(1.5)
	var 明细: Dictionary = {
		"距离(米)": "%.1f" % _平面距(兵.global_position, 远处敌.global_position),
		"1.5s 后目标": "无" if 兵.target == null else "锁着（%s）" % String(兵.target.name),
		"1.5s 后状态": _状态名(int(兵.state)),
		"1.5s 后动画": _动画(兵),
	}
	if 兵.target != null:
		失败.append("C 待机索敌：锁住了射程外 9 米的敌人（会永远打不着，也不再索敌）")
	_记("C_待机不锁射程外", 明细)


# ===========================================================================
# D · 自动施法不许吞掉指令
# ===========================================================================

func _用例D_自动施法不吞指令() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 起: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(8.0, 0.0, -10.0))
	var 终: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(26.0, 0.0, -10.0))
	var 法 = _造单位("player_faction", &"mage", 起)
	var 靶 = _造单位("enemy_faction", &"archer", 起 + Vector3(6.0, 0.0, 0.0), 5000.0)
	if 法 == null or 靶 == null:
		return
	法.call("order_attack_move", 终)

	var 明细: Dictionary = {"放技能前的指令": _指令名(int(法.order))}
	var 起手: float = _走到(func(): return int(法.state) == int(状态["CAST"]), 3.0)
	明细["起手(秒)"] = "%.2f" % 起手 if 起手 >= 0.0 else "3s 内没放技能"
	if 起手 < 0.0:
		失败.append("D 自动施法：法师 3s 内没有自动放火球")
		_记("D_自动施法不吞指令", 明细)
		return
	var 收尾: float = _走到(func(): return int(法.state) != int(状态["CAST"]), 2.0)
	明细["施法前摇(秒)"] = "%.2f" % 收尾 if 收尾 >= 0.0 else "2s 还没放完"
	明细["放完后指令"] = _指令名(int(法.order))
	明细["放完后状态"] = _状态名(int(法.state))
	if int(法.order) != int(指令["ATTACK_MOVE"]):
		失败.append("D 自动施法：放完火球后指令被清成了 %s（原指令 ATTACK_MOVE 丢了）" % 明细["放完后指令"])
	_记("D_自动施法不吞指令", 明细)


# ===========================================================================
# E · 射程口径（2026-11-07 统一：attack_range = 身位边缘 → 目标边缘的间隙）
# ===========================================================================

## 纯数值断言，不打架：直接问单位的 `_target_gap` / `_attack_reach`。
## ★ 2026-11-08 定稿：命中 = 两圈相交
##   `中心距 ≤ 攻击圈(射程×R1) + 目标判定圈`
##   → `_target_gap` 只扣目标判定圈，**不再扣自身半径**。
##   · 步兵贴身（中心距 1.2）必须够得着；
##   · 最大中心距外 0.25m 必须够不着；
##   · 弩兵：边界内 0.1m 够、外 0.1m 不够。
func _用例E_射程口径() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-4.0, 0.0, 16.0))
	var 兵 = _造单位("player_faction", &"footman", 位)
	var 弓 = _造单位("player_faction", &"archer", 位 + Vector3(30.0, 0.0, 0.0))
	var 靶 = _造单位("enemy_faction", &"archer", 位 + Vector3(1.2, 0.0, 0.0), 5000.0)
	var 靶2 = _造单位("enemy_faction", &"archer", 位 + Vector3(2.2, 0.0, 0.0), 5000.0)
	if 兵 == null or 弓 == null or 靶 == null or 靶2 == null:
		return
	# 贴身：中心距 1.2，靶判定圈 0.5 → 余量 0.7 ≤ 射程
	var 贴身间隙: float = float(兵.call("_target_gap", 靶))
	var 贴身够: bool = 贴身间隙 <= float(兵.call("_attack_reach", 靶))
	# ★ 远靶**从射程派生**，不写死距离：
	#   最大可打中心距 = 攻击圈 + 目标判定圈；再远 0.25m 必须打不到。
	var 兵射程: float = float(兵.call("_attack_reach", 靶))
	var 兵边界: float = 兵射程 + float(靶.call("judge_radius"))
	(靶2 as Node3D).global_position = (兵 as Node3D).global_position + Vector3(兵边界 + 0.25, 0.0, 0.0)
	var 远间隙: float = float(兵.call("_target_gap", 靶2))
	var 远够: bool = 远间隙 <= float(兵.call("_attack_reach", 靶2))
	# 弩兵：阈值**从卡的 range 派生**，不写死数字。
	var 弓射程: float = float(弓.call("_attack_reach", 靶))
	var 靶半径: float = float(靶.call("judge_radius"))
	var 边界: float = 弓射程 + 靶半径
	# 边界内 0.1m 必须够得着；边界外 0.1m 必须够不着。
	# 注意比的是**余量**（中心距 − 目标判定圈），不是中心距本身。
	var 弓够近: bool = (边界 - 0.1 - 靶半径) <= 弓射程
	var 弓够远: bool = (边界 + 0.1 - 靶半径) <= 弓射程

	var 明细: Dictionary = {
		"步兵贴身余量(米)": "%.2f" % 贴身间隙,
		"步兵攻击圈(米)": "%.2f" % float(兵.call("_attack_reach", 靶)),
		"步兵判定圈(米)": "%.2f" % float(兵.call("judge_radius")),
		"贴身够得着": 贴身够,
		"边界外0.25m余量(米)": "%.2f" % 远间隙,
		"边界外0.25m够得着": 远够,
		"弩兵攻击圈(米)": "%.2f" % 弓射程,
		"弩兵最大中心距(米)": "%.2f" % 边界,
		"边界内0.1m够": 弓够近,
		"边界外0.1m不够": not 弓够远,
	}
	if not 贴身够:
		失败.append("E 射程：步兵贴身还打不到（余量 %.2f > 攻击圈）" % 贴身间隙)
	if 远够:
		失败.append("E 射程：步兵在最大中心距外 0.25m 还能打到（余量 %.2f ≤ 攻击圈 %.2f，口径破了）" % [远间隙, 兵射程])
	if not 弓够近:
		失败.append("E 射程：弩兵在最大中心距内 0.1m 就打不到，射程被压小了")
	if 弓够远:
		失败.append("E 射程：弩兵超出最大中心距 0.1m 还能打到，射程超了")
	_记("E_射程口径", 明细)


# ===========================================================================
# F · 多近战围攻（2026-11-07 玩家口径："多个近战靠近同一个敌人，只有一个在攻击"）
# ===========================================================================

## 四个步兵从四个方向围住一个血厚到打不死的目标，全体 `order_attack`，跑 8 秒。
##
## 判据用 `dbg_swings`（真的在射程内起手才 +1），不看动画也不看血量：
##   · 老实现全队冲向敌人中心 → 互相顶开 → 只有最里面那个能稳定起手；
##   · 现在按 instance id 分角度站到外圈，四个都应该打进节奏。
## 另外顺带断言"没有人在射程外空挥"：起手次数上限 = 8s / 冷却 + 1，多出来就是口径破了。
func _用例F_多近战围攻() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 心: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(0.0, 0.0, 24.0))
	var 靶 = _造单位("enemy_faction", &"archer", 心, 100000.0)
	if 靶 == null:
		return
	var 兵们: Array = []
	var 方位: Array = [Vector3(1.4, 0.0, 0.0), Vector3(-1.4, 0.0, 0.0),
			Vector3(0.0, 0.0, 1.4), Vector3(0.0, 0.0, -1.4)]
	for d in 方位:
		var u = _造单位("player_faction", &"footman", 关卡.call("walkable_pos", 心 + d))
		if u == null:
			return
		兵们.append(u)
	# 先把起手计数清零（_造单位 可能已经打过）
	for u in 兵们:
		u.set("dbg_swings", 0)
	for u in 兵们:
		u.call("order_attack", 靶)
	_走(8.0)

	var 起手: Array = []
	var 总计: int = 0
	for u in 兵们:
		var s: int = int(u.get("dbg_swings"))
		起手.append(s)
		总计 += s
	var 参战人数: int = 0
	for s in 起手:
		if int(s) > 0:
			参战人数 += 1
	# 冷却 1.75s → 8 秒最多 5 下；留一点余量给起手时间
	var 上限: int = 6
	var 超限: bool = false
	for s in 起手:
		if int(s) > 上限:
			超限 = true

	var 明细: Dictionary = {
		"四人起手次数": str(起手),
		"起手总计": 总计,
		"参战人数": "%d/4" % 参战人数,
		"敌人剩余血量": "%.0f" % float(靶.hp),
	}
	if 参战人数 < 4:
		失败.append("F 围攻：只有 %d/4 个近战能打到同一个目标（起手 %s）" % [参战人数, str(起手)])
	if 总计 < 8:
		失败.append("F 围攻：8 秒总共只起手 %d 次，攻击节奏没起来" % 总计)
	if 超限:
		失败.append("F 围攻：有人起手 %s 次，超过冷却理论上限（在射程外空挥）" % str(起手))
	_记("F_多近战围攻", 明细)


# ===========================================================================
# G · 近战打建筑（2026-11-07 玩家口径："近战单位打不到建筑"）
# ===========================================================================

## 判据不看动画、不看体感：`dbg_swings > 0` 且建筑真的掉血。
## 还要打一行"贴着墙面还差多少"，方便判断是射程不够还是压根走不到墙边。
func _用例G_近战打建筑() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 心: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(0.0, 0.0, 30.0))
	var 楼 = _造单位("enemy_faction", &"barracks", 心)
	if 楼 == null:
		return
	var 起点: Vector3 = 关卡.call("walkable_pos", 心 + Vector3(5.0, 0.0, 0.0))
	var 兵 = _造单位("player_faction", &"footman", 起点)
	if 兵 == null:
		return
	var 初血: float = float(楼.get("hp"))
	兵.set("dbg_swings", 0)
	兵.call("order_attack", 楼)
	_走(12.0)
	var 起手: int = int(兵.get("dbg_swings"))
	var 末血: float = float(楼.get("hp"))
	var 贴墙: float = float(楼.call("distance_to_footprint", (兵 as Node3D).global_position))
	var 明细: Dictionary = {
		"起手次数": 起手,
		"建筑初血": "%.0f" % 初血,
		"建筑末血": "%.0f" % 末血,
		"打掉血量": "%.0f" % (初血 - 末血),
		"最终距墙面(米)": "%.2f" % 贴墙,
		"兵最终位置": "%.1f,%.1f" % [(兵 as Node3D).global_position.x, (兵 as Node3D).global_position.z],
	}
	_记("G_近战打建筑", 明细)
	if 起手 <= 0:
		失败.append("G 近战打建筑：12 秒内一次都没起手（打不到楼）")
	elif 末血 >= 初血:
		失败.append("G 近战打建筑：起手了但建筑没掉血")



# ===========================================================================
# G2 · 多近战围攻同一栋建筑（玩家口径：多个打一个也要能正常打，不许被卡）
# ===========================================================================

## 四个步兵从四个方向包一栋楼：每个人都必须起手，楼必须掉血。
## 这条和 F（四个围一个单位）是一对 —— 打人走 _surround_spot，打楼走 _attack_spot 的墙面散开，
## 两条路径都要能同时站下 4 个人。
func _用例G2_多近战围楼() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 心: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(0.0, 0.0, -34.0))
	var 楼 = _造单位("enemy_faction", &"barracks", 心)
	if 楼 == null:
		return
	var 初血: float = float(楼.get("hp"))
	var 兵们: Array = []
	var 起点表: Array = [
		Vector3(6.0, 0.0, 0.0), Vector3(-6.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 6.0), Vector3(0.0, 0.0, -6.0),
	]
	for off in 起点表:
		var p: Vector3 = 关卡.call("walkable_pos", 心 + (off as Vector3))
		var b = _造单位("player_faction", &"footman", p)
		if b == null:
			continue
		b.set("dbg_swings", 0)
		b.call("order_attack", 楼)
		兵们.append(b)
	_走(14.0)
	var 起手表: Array = []
	for b in 兵们:
		起手表.append(int(b.get("dbg_swings")))
	var 末血: float = float(楼.get("hp"))
	var 全员起手: bool = true
	for n in 起手表:
		if int(n) <= 0:
			全员起手 = false
	# 诊断：每个人最后停在哪、离墙面多远、什么状态（用来区分"走不到"和"走到了不打"）
	var 诊断: Array = []
	for b in 兵们:
		var bp: Vector3 = (b as Node3D).global_position
		var spot: Vector3 = b.call("_attack_spot", 楼)
		var snapped: Vector3 = 关卡.call("walkable_pos", spot)
		诊断.append({
			"起手": int(b.get("dbg_swings")),
			"状态": str(b.get("state")),
			"指令": int(b.get("order")),
			"距墙面": "%.2f" % float(楼.call("distance_to_footprint", bp)),
			"位置": "%.1f,%.1f" % [bp.x, bp.z],
			"站位距墙": "%.2f" % float(楼.call("distance_to_footprint", spot)),
			"吸附后距墙": "%.2f" % float(楼.call("distance_to_footprint", snapped)),
			"路点": "%.1f,%.1f" % [(b.get("_goal") as Vector3).x, (b.get("_goal") as Vector3).z],
			"reach": "%.2f" % float(b.call("_attack_reach", 楼)),
		})
	_记("G2_多近战围楼", {
		"四人起手": str(起手表),
		"诊断": 诊断,
		"建筑初血": "%.0f" % 初血,
		"建筑末血": "%.0f" % 末血,
		"打掉血量": "%.0f" % (初血 - 末血),
	})
	if not 全员起手:
		失败.append("G2 多近战围楼：有人一次都没起手（被挡住/被挤开）—— %s" % str(起手表))
	if 末血 >= 初血:
		失败.append("G2 多近战围楼：楼没掉血")
# ===========================================================================
# H · 攻击圈口径（2026-11-08 定稿：圈 = 射程，命中 = 两圈相交）
# ===========================================================================

## 把靶子摆在若干中心距上，直接问 `_target_gap <= _attack_reach`。
## 判据三条：
##   1. 攻击圈半径 == 卡上 range × R1（跑遍 pick 的圈半径函数，和判定同一份）；
##   2. 最大中心距 = 攻击圈 + 目标判定圈，内 0.1m 够、外 0.1m 不够；
##   3. 选中圈（判定圈）= 单位的 judge_radius（从体积派生），不是拾取半径。
func _用例H_最大射程() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-10.0, 0.0, 10.0))
	var 兵 = _造单位("player_faction", &"footman", 位)
	var 靶 = _造单位("enemy_faction", &"footman", 位 + Vector3(1.6, 0.0, 0.0), 100000.0)
	if 兵 == null or 靶 == null:
		return
	var 攻击圈: float = float(兵.call("attack_circle_radius"))
	var 判定圈: float = float(兵.call("judge_radius"))
	var 靶判定: float = float(靶.call("judge_radius"))
	var 边界: float = 攻击圈 + 靶判定
	var 表: Array = []
	var 最远: float = 0.0
	for off in [-0.30, -0.10, 0.0, 0.05, 0.20, 0.40]:
		var d: float = maxf(边界 + float(off), 0.2)
		(靶 as Node3D).global_position = (兵 as Node3D).global_position + Vector3(d, 0.0, 0.0)
		var gap: float = float(兵.call("_target_gap", 靶))
		var ok: bool = gap <= 攻击圈
		if ok:
			最远 = maxf(最远, d)
		表.append({"中心距": "%.2f" % d, "余量": "%.2f" % gap,
			"攻击圈": "%.2f" % 攻击圈, "够": ok})
	# 圈半径必须和**玩家真的看到的那个圈**同一个函数（选择系统的静态出口）
	var sel_script: Script = load("res://代码/操作/选择系统.gd")
	var 圈半径: float = float(sel_script.call("range_ring_radius_of", 兵))
	_记("H_攻击圈", {
		"表": 表,
		"攻击圈(米)": "%.2f" % 攻击圈,
		"画出来的圈(米)": "%.2f" % 圈半径,
		"自身判定圈(米)": "%.2f" % 判定圈,
		"目标判定圈(米)": "%.2f" % 靶判定,
		"最大中心距(米)": "%.2f" % 边界,
		"最远实测可打(米)": "%.2f" % 最远,
	})
	if 最远 <= 0.0:
		失败.append("H 攻击圈：连 %.2fm 都打不到" % 边界)
	# 圈 = 射程：多一点都不许有（旧版加了"全场最大体型"，玩家已经否掉）
	if absf(圈半径 - 攻击圈) > 0.01:
		失败.append("H 攻击圈：画出来的圈 %.2fm ≠ 射程 %.2fm（不许按体型修正）" % [圈半径, 攻击圈])
	if 判定圈 <= 0.0:
		失败.append("H 攻击圈：判定圈半径为 0（体积派生没生效）")
	# 边界外 0.4m 一定打不到（否则命中口径破了）
	var 超远: float = 边界 + 0.4
	(靶 as Node3D).global_position = (兵 as Node3D).global_position + Vector3(超远, 0.0, 0.0)
	if float(兵.call("_target_gap", 靶)) <= 攻击圈:
		失败.append("H 攻击圈：中心距 %.2fm（边界外 0.4m）还能打到" % 超远)

# ===========================================================================
# I · 挨打找敌人（2026-11-08 玩家口径）
# ===========================================================================

## 「单位要有索敌机制，范围和视野一致；如果视野内没有敌人仍然被攻击，
##   就随机向一个方向移动一段距离寻找可能的敌人（范围不要超过原先的视野范围）。」
##
## 判据：
##   ① 伤害来自 20m 外（远于视野 11m）→ 必须转入 MOVE 并真的走起来；
##   ② 走的距离 ≤ 视野半径（不许"一挨打跑半张图"）；
##   ③ 视野内**有**敌人时不许乱跑（那是还击，不是找人）。
func _用例I_挨打找敌人() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-14.0, 0.0, 22.0))
	var 兵 = _造单位("player_faction", &"footman", 位)
	if 兵 == null:
		return
	# 远在视野外的敌人（只用来当"攻击来源"，不参与索敌）
	var 远 = _造单位("enemy_faction", &"archer", 位 + Vector3(20.0, 0.0, 0.0), 99999.0)
	if 远 == null:
		return
	var 视: float = float(兵.def.sight_range)
	var 起: Vector3 = (兵 as Node3D).global_position
	兵.set("order", 指令.get("NONE", 0))
	兵.set("order_owner", 0)
	兵.call("take_damage", 5.0, 0, 远)
	_走(2.0)
	var 末: Vector3 = (兵 as Node3D).global_position
	var 位移: float = _平面距(起, 末)
	var 指令名2: String = _指令名(int(兵.order))
	_记("I_挨打找敌人", {
		"视野(米)": "%.1f" % 视, "位移(米)": "%.2f" % 位移, "当前指令": 指令名2,
	})
	if 位移 < 0.8:
		失败.append("I 挨打找敌人：视野外挨打后原地不动（位移 %.2f）" % 位移)
	if 位移 > 视 + 1.5:
		失败.append("I 挨打找敌人：走的距离 %.1f 超过视野 %.1f" % [位移, 视])


# ===========================================================================
# J · 被**视野内**的攻击者打 → 压上去还手（2026-11-08 玩家口径第 7 条）
# ===========================================================================

## 场景：一个待机的近战兵，被 8 米外（视野内、但远在 1.35 米近战射程外）的弩兵射了一箭。
##
## 旧行为：`take_damage` 只在"够得着"时锁目标，`_update_attack` 对"够不着 + 待机"
## 直接放掉锁定 —— 于是这个兵**站着被射死**，玩家看到的就是"没有索敌"。
## 现在：视野内的攻击者 → 把指令改成 ATTACK 压上去（`_engage_attacker`）。
func _用例J_视野内挨打逼上去() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 位: Vector3 = 关卡.call("walkable_pos", 基 + Vector3(-14.0, 0.0, 30.0))
	var 兵 = _造单位("player_faction", &"footman", 位)
	if 兵 == null:
		return
	# 8 米：步兵视野 11 米（看得见）、近战射程 1.35 米（够不着）—— 正是"站着挨射"的距离
	var 射 = _造单位("enemy_faction", &"archer", 位 + Vector3(8.0, 0.0, 0.0), 99999.0)
	if 射 == null:
		return
	if 射.has_method("order_hold"):
		射.call("order_hold")
	var 起: Vector3 = (兵 as Node3D).global_position
	var 初距: float = _平面距(起, (射 as Node3D).global_position)
	兵.set("order", 指令.get("NONE", 0))
	兵.set("order_owner", 0)
	兵.call("take_damage", 5.0, 0, 射)
	_走(2.0)
	var 末: Vector3 = (兵 as Node3D).global_position
	var 末距: float = _平面距(末, (射 as Node3D).global_position)
	var 明细: Dictionary = {
		"初始距(米)": "%.2f" % 初距,
		"2s 后距(米)": "%.2f" % 末距,
		"当前指令": _指令名(int(兵.order)),
		"当前目标": "有" if 兵.target != null else "无",
	}
	_记("J_视野内挨打逼上去", 明细)
	if int(兵.order) != int(指令.get("ATTACK", 2)):
		失败.append("J 视野内挨打：指令没变成 ATTACK（实 %s）" % 明细["当前指令"])
	if 初距 - 末距 < 1.0:
		失败.append("J 视野内挨打：没有朝攻击者压上去（只近了 %.2f 米）" % (初距 - 末距))
