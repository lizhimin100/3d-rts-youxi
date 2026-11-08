extends SceneTree
## **据点自检（无头）**：地图中央资源箱的刷新 / 占据 / 结算 / 争夺清零。
##
## 跑法：godot --headless --fixed-fps 60 --path . --script 代码/测试/据点自检.gd
## 结尾一行 `SPTEST {json}`，退出码 0 = 全过。
##
## 判据（玩家 2026-11-08 口径）：
##   A 刷新节奏：开局 180s 第一次，结算后 120s 下一次；
##   B 占据判定：单一阵营连续待满 15s → 资源入账，箱子消失；
##   C 争夺清零：两个阵营同时在圈里 → 计时不动（谁也别想白拿）；
##   D 价值判断：空圈 1.0 / 敌占 1.6 / 我们占 0.25 / 没箱子 0；
##   E 不白送：圈里只有野怪（team 0）不算占点。

## 步长用**真实帧**（1/60）：据点内部每 0.2s 才判一次，
## 如果测试也拿 0.2 当 delta，就永远测不出"只累加当帧 delta"那个 bug（2026-11-08 踩过）。
const 步长: float = 1.0 / 60.0
## ★ 不能在文件头 preload 据点.gd：`--script` 的脚本在 autoload 注册**之前**编译，
##   而 据点.gd 里引用了 `Game` 单例 → 整份脚本编译失败（战斗自检文件头写过同一个坑）。
##   改成运行时 load。
var SP_SCRIPT: Script = null

var 游戏: Node = null
var 关卡: Node3D = null
var 据点: Node3D = null
var 报告: Dictionary = {}
var 失败: Array = []


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var 开始: int = Time.get_ticks_msec()
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[据点自检] 找不到 Game")
		quit(1)
		return
	SP_SCRIPT = load("res://代码/系统/据点.gd")
	if SP_SCRIPT == null:
		push_error("[据点自检] 读不到 代码/系统/据点.gd")
		quit(1)
		return
	_建世界()
	_用例A_刷新节奏()
	_用例B_占据结算()
	_用例C_争夺清零()
	_用例D_价值判断()
	_用例E_野怪不算()
	报告["失败项"] = 失败
	报告["结果"] = "通过" if 失败.is_empty() else "失败"
	报告["耗时(毫秒)"] = Time.get_ticks_msec() - 开始
	print("SPTEST " + JSON.stringify(报告))
	quit(0 if 失败.is_empty() else 1)


func _建世界() -> void:
	游戏.call("reset")
	游戏.set("difficulty_index", 0)
	游戏.call("setup_factions")
	var s: Script = load("res://代码/核心/关卡.gd")
	关卡 = s.new()
	关卡.name = "关卡"
	root.add_child(关卡)
	关卡.call("build")
	游戏.set("level", 关卡)
	var 常量: Script = load("res://代码/核心/常量.gd")
	var 阶段: Dictionary = 常量.get_script_constant_map().get("Phase", {}) if 常量 != null else {}
	游戏.set("phase", int(阶段.get("RUNNING", 1)))
	# 中立敌对（野怪）阵营：平时由 野怪.gd 建
	var fs: Script = load("res://代码/数据/阵营.gd")
	if 游戏.get("neutral_faction") == null:
		var nf = fs.new()
		nf.set("index", 9)
		nf.set("team", 0)
		nf.set("is_player", false)
		nf.set("is_ai", true)
		nf.set("display_name", "中立敌对")
		nf.set("color", Color(0.64, 0.40, 0.36))
		游戏.set("neutral_faction", nf)
	_新建据点()


## 清场：把上一组用例留下的兵全摘掉（否则"圈里有几家阵营"会串味）
func _清场() -> void:
	for u in 游戏.call("all_units").duplicate():
		if u == null or not is_instance_valid(u):
			continue
		游戏.call("unregister", u)
		u.queue_free()


func _新建据点() -> void:
	_清场()
	if 据点 != null and is_instance_valid(据点):
		据点.queue_free()
	var mid: Vector3 = 关卡.call("walkable_pos", Vector3.ZERO)
	据点 = SP_SCRIPT.new()
	据点.name = "据点"
	root.add_child(据点)
	据点.call("setup", mid)
	游戏.set("strongpoint", 据点)


func _走(秒: float) -> void:
	var n: int = int(round(秒 / 步长))
	for i in n:
		据点.call("_process", 步长)


func _造(阵营: String, id: StringName, 偏移: Vector3):
	var 派 = 游戏.get(阵营)
	var pos: Vector3 = 关卡.call("walkable_pos", (据点.call("crate_pos") as Vector3) + 偏移)
	var n = 游戏.call("spawn_unit", 派, id, pos, 关卡)
	if n == null:
		失败.append("生成 %s 失败" % id)
		return null
	n.set_process(false)
	var v = n.visual
	if v != null and is_instance_valid(v):
		v.set_process(false)
	return n


func _记(名: String, 明细: Dictionary) -> void:
	报告[名] = 明细
	print("[据点自检] %s %s" % [名, JSON.stringify(明细)])


# ---------------------------------------------------------------------------
func _用例A_刷新节奏() -> void:
	_新建据点()
	var 初始: float = float(据点.call("countdown"))
	_走(179.0)
	var 还在等: bool = not bool(据点.get("crate_active"))
	_走(2.0)
	var 出了: bool = bool(据点.get("crate_active"))
	_记("A_刷新节奏", {"初始倒计时": "%.0f" % 初始, "179s 还没出": 还在等, "181s 出了": 出了})
	if absf(初始 - 180.0) > 0.5:
		失败.append("A 刷新节奏：初始倒计时 %.1fs（应为 180s）" % 初始)
	if not 还在等:
		失败.append("A 刷新节奏：179 秒就刷了箱子（应为 180 秒）")
	if not 出了:
		失败.append("A 刷新节奏：181 秒还没刷箱子")


# ---------------------------------------------------------------------------
func _用例B_占据结算() -> void:
	_新建据点()
	据点.call("_spawn_crate")
	var 金0: int = int(游戏.get("player_faction").gold)
	_造("player_faction", &"footman", Vector3(1.0, 0.0, 0.0))
	_走(14.0)
	var 中途: float = float(据点.call("hold_ratio"))
	var 还没给: bool = int(游戏.get("player_faction").gold) == 金0
	_走(2.0)
	var 金1: int = int(游戏.get("player_faction").gold)
	var 箱子没了: bool = not bool(据点.get("crate_active"))
	var 下次: float = float(据点.call("countdown"))
	_记("B_占据结算", {
		"14s 进度": "%.2f" % 中途, "14s 还没给钱": 还没给,
		"16s 到手金": 金1 - 金0, "箱子消失": 箱子没了, "下次倒计时": "%.0f" % 下次,
	})
	if 中途 < 0.85:
		失败.append("B 占据结算：14 秒时进度只有 %.2f（应 ≈0.93）" % 中途)
	if not 还没给:
		失败.append("B 占据结算：不到 15 秒就给钱了")
	if 金1 - 金0 != int(SP_SCRIPT.CRATE_GOLD):
		失败.append("B 占据结算：到手 %d 金（应为 %d）" % [金1 - 金0, SP_SCRIPT.CRATE_GOLD])
	if not 箱子没了:
		失败.append("B 占据结算：结算完箱子还在")
	if absf(下次 - 120.0) > 1.0:
		失败.append("B 占据结算：下次刷新倒计时 %.0fs（应为 120s）" % 下次)


# ---------------------------------------------------------------------------
func _用例C_争夺清零() -> void:
	_新建据点()
	据点.call("_spawn_crate")
	_造("player_faction", &"footman", Vector3(1.0, 0.0, 0.0))
	_走(6.0)
	var 单人进度: float = float(据点.call("hold_ratio"))
	_造("enemy_faction", &"footman", Vector3(-1.0, 0.0, 0.0))
	_走(2.0)
	var 争夺后: float = float(据点.call("hold_ratio"))
	_记("C_争夺清零", {"单人 6s 进度": "%.2f" % 单人进度, "敌人进场后": "%.2f" % 争夺后})
	if 单人进度 < 0.3:
		失败.append("C 争夺清零：单人 6 秒进度只有 %.2f" % 单人进度)
	if 争夺后 > 0.001:
		失败.append("C 争夺清零：两人同时在圈里，计时没清零（%.2f）" % 争夺后)


# ---------------------------------------------------------------------------
func _用例D_价值判断() -> void:
	_新建据点()
	var 无箱: float = float(据点.call("value_score", 游戏.get("player_faction")))
	据点.call("_spawn_crate")
	var 空圈: float = float(据点.call("value_score", 游戏.get("player_faction")))
	_造("player_faction", &"footman", Vector3(1.0, 0.0, 0.0))
	_走(0.4)
	var 我们占: float = float(据点.call("value_score", 游戏.get("player_faction")))
	_新建据点()
	据点.call("_spawn_crate")
	_造("enemy_faction", &"footman", Vector3(1.0, 0.0, 0.0))
	_走(0.4)
	var 敌占: float = float(据点.call("value_score", 游戏.get("player_faction")))
	_记("D_价值判断", {"无箱": "%.2f" % 无箱, "空圈": "%.2f" % 空圈,
		"我们占": "%.2f" % 我们占, "敌占": "%.2f" % 敌占})
	if 无箱 > 0.001:
		失败.append("D 价值判断：没箱子还给了 %.2f 分" % 无箱)
	if absf(空圈 - 1.0) > 0.01:
		失败.append("D 价值判断：空圈 %.2f（应为 1.0）" % 空圈)
	if absf(我们占 - 0.25) > 0.01:
		失败.append("D 价值判断：我们占着 %.2f（应为 0.25，交给驻防）" % 我们占)
	if 敌占 < 1.5:
		失败.append("D 价值判断：敌人在占只有 %.2f 分（应 ≥1.5）" % 敌占)


# ---------------------------------------------------------------------------
func _用例E_野怪不算() -> void:
	_新建据点()
	据点.call("_spawn_crate")
	_造("neutral_faction", &"gnoll_warrior", Vector3(1.0, 0.0, 0.0))
	_走(16.0)
	var 还在: bool = bool(据点.get("crate_active"))
	var 圈内阵营: Array = 据点.call("factions_in_zone")
	_记("E_野怪不算", {"16s 后箱子还在": 还在, "圈内阵营数": 圈内阵营.size()})
	if not 还在:
		失败.append("E 野怪不算：野怪站在圈里把箱子拿了")
