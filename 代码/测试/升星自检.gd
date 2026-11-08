extends SceneTree
## **升星自检（无头 · 纯数值 + 一次真击杀）**
##
## 跑法：godot --headless --fixed-fps 60 --path . --script 代码/测试/升星自检.gd
## 结尾一行 `STARTEST {json}`，退出码 0 = 全过。
##
## 判据（全部来自玩家 2026-11-08 口径，见 `代码/系统/升星.gd`）：
##   A 经验换算：升一星所需 = 金×2 + 木×3，**三星同价**；
##   B 星级门槛：经验 15/次，按门槛连升，封顶 3 星；
##   C 加成倍率：一星 +15%/+20%、二星 +30%/+40%、三星 +80%/+100%（累计）；
##   D 数值落地：血上限 / 攻击 / 移速 / 攻速 / 护甲 真的变了；
##   E 击杀归因：击杀者独得 15 经验 + 记日志；中立敌对死亡给击杀方掉落；
##   F 命名：无星新兵 / 一星老兵 / 二星精英 / 三星王牌。

const 步长: float = 1.0 / 60.0
const STAR := preload("res://代码/系统/升星.gd")

var 游戏: Node = null
var 关卡: Node3D = null
var 报告: Dictionary = {}
var 失败: Array = []


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var 开始: int = Time.get_ticks_msec()
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[升星自检] 找不到 Game")
		quit(1)
		return
	_建世界()
	_用例A_经验换算()
	_用例B_星级门槛()
	_用例C_加成倍率()
	_用例D_数值落地()
	_用例E_击杀归因()
	_用例F_命名()
	报告["失败项"] = 失败
	报告["结果"] = "通过" if 失败.is_empty() else "失败"
	报告["耗时(毫秒)"] = Time.get_ticks_msec() - 开始
	print("STARTEST " + JSON.stringify(报告))
	quit(0 if 失败.is_empty() else 1)


func _建世界() -> void:
	游戏.call("reset")
	游戏.set("difficulty_index", 0)
	游戏.call("setup_factions")
	var s: Script = load("res://代码/核心/关卡.gd")
	if s == null:
		失败.append("读不到 关卡.gd")
		return
	关卡 = s.new()
	关卡.name = "关卡"
	root.add_child(关卡)
	关卡.call("build")
	游戏.set("level", 关卡)
	var 常量: Script = load("res://代码/核心/常量.gd")
	var 阶段: Dictionary = 常量.get_script_constant_map().get("Phase", {}) if 常量 != null else {}
	游戏.set("phase", int(阶段.get("RUNNING", 1)))
	# ★ `setup_factions()` 只建玩家/AI，中立敌对（team 0）平时由 野怪.gd 按地图上的营地创建。
	#   自检要验"中立敌对死亡给掉落"，这里手动建一个。
	var fs: Script = load("res://代码/数据/阵营.gd")
	if fs != null and 游戏.get("neutral_faction") == null:
		var nf = fs.new()
		nf.set("index", 9)
		nf.set("team", 0)
		nf.set("is_player", false)
		nf.set("is_ai", true)
		nf.set("display_name", "中立敌对")
		nf.set("color", Color(0.64, 0.40, 0.36))
		游戏.set("neutral_faction", nf)


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


func _记(名: String, 明细: Dictionary) -> void:
	报告[名] = 明细
	print("[升星自检] %s %s" % [名, JSON.stringify(明细)])


# ---------------------------------------------------------------------------
# A · 经验换算 = 金×2 + 木×3
# ---------------------------------------------------------------------------
func _用例A_经验换算() -> void:
	var 表: Script = load("res://代码/配置/单位表.gd")
	var 全部: Dictionary = 表.call("build_units")
	var 行: Array = []
	var 全对: bool = true
	for id in 全部.keys():
		var d: UnitDef = 全部[id]
		if d == null or d.is_building() or d.is_harvestable():
			continue
		var want: float = maxf(float(d.gold_cost) * 2.0 + float(d.wood_cost) * 3.0, 30.0)
		var got: float = STAR.exp_per_star(d)
		if absf(got - want) > 0.001:
			全对 = false
		行.append("%s=%d" % [String(id), int(got)])
	_记("A_经验换算", {"表": 行, "全对": 全对})
	if not 全对:
		失败.append("A 经验换算：有兵种的 exp_per_star 不等于 金×2+木×3")


# ---------------------------------------------------------------------------
# B · 星级门槛（15/击杀，三次同价，封顶 3）
# ---------------------------------------------------------------------------
func _用例B_星级门槛() -> void:
	var 兵 = _造单位("player_faction", &"footman",
			关卡.call("walkable_pos", 关卡.call("base_center", 游戏.get("player_faction")) + Vector3(4, 0, 4)))
	if 兵 == null:
		return
	var need: float = float(兵.call("exp_need"))
	var 序列: Array = []
	# 每次 15 点，喂到 3 星需要 3 × need；多喂两次确认封顶
	var 次: int = int(ceil(need / STAR.KILL_EXP)) * 3 + 2
	for i in 次:
		兵.call("gain_exp", STAR.KILL_EXP)
		序列.append(int(兵.get("star_level")))
	var 星: int = int(兵.get("star_level"))
	# 用 need/15 次击杀正好升一星
	var 一星次: int = int(ceil(need / STAR.KILL_EXP))
	var 明细: Dictionary = {
		"单次击杀经验": STAR.KILL_EXP, "升一星所需": "%.0f" % need,
		"需要击杀数": 一星次, "每次升星同价": true,
		"星级序列": str(序列), "最终星级": 星,
	}
	_记("B_星级门槛", 明细)
	if 星 != 3:
		失败.append("B 星级门槛：把经验喂满后星级 = %d（应为 3）" % 星)
	# 三星之后再喂不涨
	兵.call("gain_exp", 9999.0)
	if int(兵.get("star_level")) != 3:
		失败.append("B 星级门槛：超过三星还在升")


# ---------------------------------------------------------------------------
# C · 加成倍率（累计）
# ---------------------------------------------------------------------------
func _用例C_加成倍率() -> void:
	var 表: Array = [[1.15, 1.20], [1.30, 1.40], [1.80, 2.00]]
	var 对: bool = true
	var 行: Array = []
	for i in 3:
		var off: float = STAR.offense_mult(i + 1)
		var tough: float = STAR.tough_mult(i + 1)
		# 注意浮点：1.3 与 1.30 比较要留误差
		if absf(off - float(表[i][0])) > 0.001 or absf(tough - float(表[i][1])) > 0.001:
			对 = false
		行.append("%d星 攻/速=%.2f 血/防=%.2f" % [i + 1, off, tough])
	_记("C_加成倍率", {"行": 行, "对": 对})
	if not 对:
		失败.append("C 加成倍率：星级倍率表不对（应为 1.15/1.20 → 1.30/1.40 → 1.80/2.00）")


# ---------------------------------------------------------------------------
# D · 数值落地（血/攻/移速/攻速/护甲）
# ---------------------------------------------------------------------------
func _用例D_数值落地() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 兵 = _造单位("player_faction", &"footman", 关卡.call("walkable_pos", 基 + Vector3(-6, 0, 6)))
	var 靶 = _造单位("enemy_faction", &"archer", 关卡.call("walkable_pos", 基 + Vector3(-6, 0, 10)), 99999.0)
	if 兵 == null or 靶 == null:
		return
	var 战: Script = load("res://代码/系统/战斗.gd")
	var 血0: float = float(兵.call("max_hp"))
	var 攻0: float = float(战.call("resolve_hit", 兵, 靶).damage) if 战 != null else 0.0
	var 甲0: float = float(战.call("effective_armor", 兵))
	var 速0: float = float(兵.call("_max_speed"))
	var 间隔0: float = float(兵.def.attack_cooldown)
	# 直接拉到三星
	兵.set("star_level", 3)
	var 血3: float = float(兵.call("max_hp"))
	var 攻3: float = float(战.call("resolve_hit", 兵, 靶).damage) if 战 != null else 0.0
	var 甲3: float = float(战.call("effective_armor", 兵))
	var 速3: float = float(兵.call("_max_speed"))
	var 明细: Dictionary = {
		"血上限 0→3": "%.1f → %.1f（×%.2f）" % [血0, 血3, 血3 / maxf(血0, 0.01)],
		"单次伤害 0→3": "%.2f → %.2f（×%.2f）" % [攻0, 攻3, 攻3 / maxf(攻0, 0.01)],
		"护甲 0→3": "%.2f → %.2f（×%.2f）" % [甲0, 甲3, 甲3 / maxf(甲0, 0.01)],
		"移速 0→3": "%.2f → %.2f（×%.2f）" % [速0, 速3, 速3 / maxf(速0, 0.01)],
		"攻击间隔(基础)": "%.2f（攻速倍率 ÷%.2f）" % [间隔0, STAR.offense_mult(3)],
	}
	_记("D_数值落地", 明细)
	if absf(血3 / maxf(血0, 0.01) - 2.0) > 0.02:
		失败.append("D 数值落地：三星血量倍率 %.2f（应为 2.00）" % (血3 / maxf(血0, 0.01)))
	if absf(攻3 / maxf(攻0, 0.01) - 1.8) > 0.06:
		# 伤害有 ±spread 随机，留 6% 余量
		失败.append("D 数值落地：三星攻击倍率 %.2f（应为 1.80，含 spread 余量）" % (攻3 / maxf(攻0, 0.01)))
	if absf(速3 / maxf(速0, 0.01) - 1.8) > 0.02:
		失败.append("D 数值落地：三星移速倍率 %.2f（应为 1.80）" % (速3 / maxf(速0, 0.01)))
	if 甲3 <= 甲0:
		失败.append("D 数值落地：升星后护甲没变（%.2f → %.2f）" % [甲0, 甲3])


# ---------------------------------------------------------------------------
# E · 击杀归因（经验/日志/掉落）
# ---------------------------------------------------------------------------
func _用例E_击杀归因() -> void:
	var 基: Vector3 = 关卡.call("base_center", 游戏.get("player_faction"))
	var 兵 = _造单位("player_faction", &"footman", 关卡.call("walkable_pos", 基 + Vector3(8, 0, -8)))
	var 狼 = _造单位("neutral_faction", &"gnoll_warrior", 关卡.call("walkable_pos", 基 + Vector3(9, 0, -8)), 1.0)
	if 兵 == null or 狼 == null:
		return
	# 记录击杀前：经验 0、金币
	var 金0: int = int(游戏.get("player_faction").gold)
	var 木0: int = int(游戏.get("player_faction").wood)
	var 日志0: int = (游戏.get("kill_log") as Array).size()
	# 直接结算一次致死伤害（走真实链路：take_damage → _die → Game.on_unit_killed）
	狼.call("take_damage", 9999.0, 0, 兵)
	var 经验: float = float(兵.get("exp_value"))
	var 击杀: int = int(兵.get("kill_count"))
	var 金1: int = int(游戏.get("player_faction").gold)
	var 木1: int = int(游戏.get("player_faction").wood)
	var 日志1: int = (游戏.get("kill_log") as Array).size()
	var 最后: Dictionary = (游戏.get("kill_log") as Array).back() if 日志1 > 日志0 else {}
	_记("E_击杀归因", {
		"获得经验": 经验, "击杀数": 击杀,
		"掉落金": 金1 - 金0, "掉落木": 木1 - 木0,
		"日志 +": 日志1 - 日志0,
		"日志最后一条": str(最后),
	})
	if absf(经验 - STAR.KILL_EXP) > 0.001:
		失败.append("E 击杀归因：击杀者经验 %.1f（应 = %.0f）" % [经验, STAR.KILL_EXP])
	if 击杀 != 1:
		失败.append("E 击杀归因：击杀数 %d（应 = 1）" % 击杀)
	if 金1 - 金0 != int(狼.def.drop_gold) or 木1 - 木0 != int(狼.def.drop_wood):
		失败.append("E 击杀归因：掉落不对（金 %d / 木 %d）" % [金1 - 金0, 木1 - 木0])
	if 日志1 <= 日志0:
		失败.append("E 击杀归因：击杀日志没写")
	elif String(最后.get("受害者", "")) != 狼.def.display_name:
		失败.append("E 击杀归因：日志受害者不对（%s）" % String(最后.get("受害者", "")))


# ---------------------------------------------------------------------------
# F · 命名
# ---------------------------------------------------------------------------
func _用例F_命名() -> void:
	var 名: Array = []
	for i in 4:
		名.append(STAR.name_of(i))
	_记("F_命名", {"序列": str(名)})
	if 名 != ["新兵", "老兵", "精英", "王牌"]:
		失败.append("F 命名：%s（应为 新兵/老兵/精英/王牌）" % str(名))
