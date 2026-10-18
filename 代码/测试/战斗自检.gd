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
	var 尺寸: int = int(pf.get("size"))
	return 尺寸


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
