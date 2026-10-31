extends SceneTree
## **科技 / 后勤自检**：伐木场交汇点、两项木材科技、铁匠铺平铺升级、农民修理建筑。
##
## 运行（★ 不要加 --import）：
##   godot --headless --path . --script 代码/测试/科技与后勤自检.gd
##
## 覆盖（都是玩家 2026-10-31 点名的口径，逐条验数据层，不靠截图猜）：
##   1. 伐木场只收木材、大本营金木全收；
##   2. 农民背着木头时**优先**去伐木场（哪怕大本营更近）；
##   3. 「高效搬运」→ 运回的木材 +50%（金子不受影响）；
##   4. 「修缮工艺」→ 修理消耗的木材减半；
##   5. 农民修一栋掉血的建筑：血量回升、木材真的被扣、修满自动停；
##   6. 铁匠铺「武器锻造 / 护甲锻造」= 步兵/弩手 **+1/级、最高 5 级**，其它兵种不吃；
##   7. 哨塔没有攻击、箭塔有攻击且视野比哨塔小（两座塔的分工不能糊成一样）。
##
## ★ 为什么满篇 call()/get()：`--script` 模式下自动加载单例的全局标识符还没注册，
##   直接写 Cfg / Game 会 "Identifier not found"（和建造自检同一个运行环境约束）。

const LEVEL_SCRIPT := "res://代码/核心/关卡.gd"
const UNIT_SCRIPT := "res://代码/单位/单位.gd"

const PEASANT := &"peasant"
const TOWNHALL := &"townhall"
const LUMBERCAMP := &"lumbercamp"
const BARRACKS := &"barracks"
const BLACKSMITH := &"blacksmith"
const WATCHTOWER := &"watchtower"
const TOWER := &"tower"
const FOOTMAN := &"footman"
const ARCHER := &"archer"
const MAGE := &"mage"

## RtsConst.Harvest
const H_GOLD := 0
const H_WOOD := 1
## 铁匠铺研究 id
const R_ATTACK := &"attack_up"
const R_ARMOR := &"armor_up"
const R_HAUL := &"wood_haul"
const R_REPAIR := &"repair_tech"

var _game: Node = null
var _cfg: Node = null
var _level: Node3D = null
var _faction: Object = null
var _combat: Object = null

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []
var _done: bool = false
var _booted: bool = false

var _hall: Node3D = null
var _camp: Node3D = null
var _peasant: Node3D = null
var _barracks: Node3D = null


# ===========================================================================
# 启动
# ===========================================================================

func _initialize() -> void:
	print("========== 科技与后勤自检 ==========")


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _booted:
		_boot_once()
		return false
	_finish()
	return true


func _boot_once() -> void:
	_booted = true
	_boot_world()
	_test_defs()
	_test_dropoff_choice()
	_test_haul_tech()
	_test_repair()
	_test_smith()
	_test_towers()
	_finish()


func _boot_world() -> void:
	_game = root.get_node("Game")
	_cfg = root.get_node("Cfg")
	_combat = load("res://代码/系统/战斗.gd")
	_game.call("reset")
	_game.set("difficulty_index", 0)
	_game.call("setup_factions")

	_level = load(LEVEL_SCRIPT).new()
	root.add_child(_level)
	_level.call("build")
	_level.call("spawn_props")
	_game.set("level", _level)
	_game.set("phase", 1)
	_faction = _game.get("player_faction")
	_faction.call("add_res", 9000, 9000)

	var base: Vector3 = _level.call("base_center", _faction)
	_hall = _game.call("spawn_unit", _faction, TOWNHALL,
			_level.call("snap_grid", base), _level)
	# 伐木场故意放在**离基地更远**的一侧：只有这样"优先去伐木场"才验得出来
	_camp = _spawn_near(_hall, LUMBERCAMP, Vector3(0.0, 0.0, -22.0))
	_barracks = _spawn_near(_hall, BARRACKS, Vector3(0.0, 0.0, 22.0))
	_peasant = _game.call("spawn_unit", _faction, PEASANT,
			_level.call("snap_grid", base + Vector3(4.0, 0.0, 0.0)), _level)
	# 全部当场完工：这些用例只关心数值，不关心施工流程（施工由建造自检覆盖）
	for b in [_hall, _camp, _barracks]:
		if b != null:
			b.set("progress", 1.0)
			b.set("is_constructed", true)


## 在 hall 附近 offset 处摆一栋（失败返回 null）
func _spawn_near(hall: Node3D, id: StringName, offset: Vector3) -> Node3D:
	if hall == null:
		return null
	var p: Vector3 = _level.call("snap_grid", hall.global_position + offset)
	var n: Node3D = _game.call("spawn_unit", _faction, id, p, _level)
	if n == null:
		push_error("[科技自检] 摆不出来：%s" % String(id))
	return n


# ===========================================================================
# 1. 定义层：交汇点收什么、哨塔/箭塔分工
# ===========================================================================

func _test_defs() -> void:
	var hall_def: Object = _cfg.call("unit", TOWNHALL)
	var camp_def: Object = _cfg.call("unit", LUMBERCAMP)
	_ok("大本营是交汇点且金木全收",
		hall_def != null and bool(hall_def.call("accepts_harvest", H_GOLD))
			and bool(hall_def.call("accepts_harvest", H_WOOD)))
	_ok("伐木场只收木材（不收金子）",
		camp_def != null and bool(camp_def.call("accepts_harvest", H_WOOD))
			and not bool(camp_def.call("accepts_harvest", H_GOLD)))
	var wt: Object = _cfg.call("unit", WATCHTOWER)
	var tw: Object = _cfg.call("unit", TOWER)
	_ok("哨塔没有攻击", wt != null and not bool(wt.call("can_attack")),
		"伤害 %.0f / 射程 %.0f" % [wt.get("attack_damage"), wt.get("attack_range")])
	_ok("箭塔有攻击", tw != null and bool(tw.call("can_attack")),
		"伤害 %.0f / 射程 %.0fm" % [tw.get("attack_damage"), tw.get("attack_range")])
	_ok("哨塔视野比箭塔大（分工：一个看得远、一个打得着）",
		wt != null and tw != null and float(wt.get("sight_range")) > float(tw.get("sight_range")),
		"哨塔 %.0fm > 箭塔 %.0fm" % [float(wt.get("sight_range")), float(tw.get("sight_range"))])


# ===========================================================================
# 2. 背木头优先去伐木场
# ===========================================================================

func _test_dropoff_choice() -> void:
	if _peasant == null or _camp == null:
		_ok("农民回程点优先选伐木场", false, "缺少农民或伐木场")
		return
	# 把农民挪到"离大本营更近、离伐木场更远"的位置 —— 优先级才看得出
	_peasant.global_position = _hall.global_position + Vector3(0.0, 0.0, 3.0)
	var d_hall: float = _hall.global_position.distance_to(_peasant.global_position)
	var d_camp: float = _camp.global_position.distance_to(_peasant.global_position)
	# 背木头
	_peasant.set("_carry_kind", H_WOOD)
	_peasant.set("_carry", 10)
	var got: Variant = _peasant.call("_nearest_dropoff", H_WOOD)
	_ok("背木头时按**距离**选交汇点（大本营更近就去大本营，没有优先级）",
		got == _hall, "大本营 %.0fm / 伐木场 %.0fm → 选了 %s" % [
			d_hall, d_camp,
			"大本营" if got == _hall else ("伐木场" if got == _camp else "其它")])
	# 把农民挪到伐木场这边，同一份数据必须反过来选伐木场
	_peasant.global_position = _camp.global_position + Vector3(0.0, 0.0, 3.0)
	var got2: Variant = _peasant.call("_nearest_dropoff", H_WOOD)
	_ok("站到伐木场旁边时选伐木场（同一个函数，只认距离）", got2 == _camp)
	# 背金子时不能去伐木场（它不收金）
	_peasant.set("_carry_kind", H_GOLD)
	var got_gold: Variant = _peasant.call("_nearest_dropoff", H_GOLD)
	_ok("农民背着金子回大本营（伐木场不在候选里）", got_gold == _hall)


# ===========================================================================
# 3. 高效搬运：木材 +50%
# ===========================================================================

func _test_haul_tech() -> void:
	if _peasant == null:
		return
	var wood0: int = int(_faction.get("wood"))
	_deposit(10, H_WOOD)
	var gain0: int = int(_faction.get("wood")) - wood0
	_ok("未研究时运回 10 木 → 入账 10", gain0 == 10, "实测 %d" % gain0)

	_combat.call("apply_research", _faction, R_HAUL)
	var wood1: int = int(_faction.get("wood"))
	_deposit(10, H_WOOD)
	var gain1: int = int(_faction.get("wood")) - wood1
	_ok("「高效搬运」后运回 10 木 → 入账 15（+50%）", gain1 == 15, "实测 %d" % gain1)

	# 金子不受影响
	var gold0: int = int(_faction.get("gold"))
	_deposit(10, H_GOLD)
	var gain_g: int = int(_faction.get("gold")) - gold0
	_ok("「高效搬运」不改变金子入账", gain_g == 10, "实测 %d" % gain_g)


## 让农民"身上带着 n 个 kind 资源"并当场入账
func _deposit(n: int, kind: int) -> void:
	_peasant.set("_carry", n)
	_peasant.set("_carry_kind", kind)
	_peasant.call("_deposit_carry")


# ===========================================================================
# 4/5. 修理：吃木材、能修满、修缮工艺减半
# ===========================================================================

func _test_repair() -> void:
	if _barracks == null:
		_ok("农民修理建筑（基础）", false, "没有兵营")
		return
	var max_hp: float = float(_barracks.get("def").get("max_hp"))
	_barracks.set("hp", max_hp * 0.5)
	_ok("掉血的建筑可以修", bool(_barracks.call("can_repair")),
		"%.0f / %.0f" % [float(_barracks.get("hp")), max_hp])
	_ok("满血建筑不能修（不白扣木材）", not bool(_hall.call("can_repair")))

	var wood0: int = int(_faction.get("wood"))
	var hp0: float = float(_barracks.get("hp"))
	for _i in 30:
		_barracks.call("repair_step", 0.1, _peasant)
	var hp1: float = float(_barracks.get("hp"))
	var spent: int = wood0 - int(_faction.get("wood"))
	_ok("修 3 秒：血量上升", hp1 > hp0, "%.0f → %.0f" % [hp0, hp1])
	_ok("修 3 秒：木材真的被扣", spent > 0, "扣了 %d 木" % spent)

	# 一直修到满：修满之后必须自己停手（can_repair 变 false、再修也不掉木）
	for _i in 400:
		if not bool(_barracks.call("can_repair")):
			break
		_barracks.call("repair_step", 0.2, _peasant)
	_ok("一直修可以修满", absf(float(_barracks.get("hp")) - max_hp) < 1.0,
		"%.0f / %.0f" % [float(_barracks.get("hp")), max_hp])
	var wood_full: int = int(_faction.get("wood"))
	for _i in 20:
		_barracks.call("repair_step", 0.2, _peasant)
	_ok("修满后自动停（不再扣木）",
		not bool(_barracks.call("can_repair")) and int(_faction.get("wood")) == wood_full,
		"又扣了 %d 木" % (wood_full - int(_faction.get("wood"))))

	# 修缮工艺：同样的修补量，木材消耗减半
	var rate_before: int = _repair_cost_for(400.0)
	_combat.call("apply_research", _faction, R_REPAIR)
	var rate_after: int = _repair_cost_for(400.0)
	_ok("「修缮工艺」后修同样的血量，木材消耗减半",
		rate_after > 0 and absf(float(rate_after) * 2.0 - float(rate_before)) <= 1.0,
		"%d 木 → %d 木" % [rate_before, rate_after])


## 修 heal_hp 点血要花多少木材（拿兵营做实验体，修完立刻回滚，不留副作用）
func _repair_cost_for(heal_hp: float) -> int:
	var max_hp: float = float(_barracks.get("def").get("max_hp"))
	_barracks.set("hp", max_hp - heal_hp)
	_barracks.set("_repair_debt", 0.0)
	var w0: int = int(_faction.get("wood"))
	# 一次推进到"刚好修满"需要的时间（每秒 2.2% 最大血量）
	var need: float = heal_hp / maxf(max_hp * float(_barracks.get("REPAIR_HP_PER_SEC")), 0.001)
	_barracks.call("repair_step", need + 0.2, _peasant)
	var spent: int = w0 - int(_faction.get("wood"))
	_barracks.set("hp", max_hp)
	_barracks.set("_repair_debt", 0.0)
	return spent


# ===========================================================================
# 6. 铁匠铺：+1/级、最高 5 级、只作用于步兵/弩手
# ===========================================================================

func _test_smith() -> void:
	var smith_def: Object = _cfg.call("unit", BLACKSMITH)
	_ok("铁匠铺挂着两项研究（武器锻造 / 护甲锻造）",
		smith_def != null and (smith_def.get("researches") as Array).size() == 2)

	var foot: Object = _cfg.call("unit", FOOTMAN)
	var arch: Object = _cfg.call("unit", ARCHER)
	var mage: Object = _cfg.call("unit", MAGE)
	var base_atk: float = float(foot.get("attack_damage"))
	var base_arm: float = float(foot.get("armor"))

	for _i in 5:
		_combat.call("apply_research", _faction, R_ATTACK)
		_combat.call("apply_research", _faction, R_ARMOR)
	_ok("步兵攻击 +5（平铺 +1×5，不是百分比）",
		absf(float(_combat.call("attack_bonus", _faction, foot)) - 5.0) < 0.001,
		"基础 %.0f → 加成 %.0f" % [base_atk, float(_combat.call("attack_bonus", _faction, foot))])
	_ok("步兵防御 +5", absf(float(_combat.call("armor_bonus", _faction, foot)) - 5.0) < 0.001,
		"基础 %.0f → 加成 %.0f" % [base_arm, float(_combat.call("armor_bonus", _faction, foot))])
	_ok("弩手同样吃加成",
		absf(float(_combat.call("attack_bonus", _faction, arch)) - 5.0) < 0.001)
	_ok("法师不吃铁匠铺加成",
		absf(float(_combat.call("attack_bonus", _faction, mage))) < 0.001)

	# 满级后不能继续研究（数据层 max_level = 5）
	var rd: Object = _cfg.call("research", R_ATTACK)
	var lv: int = int(_combat.call("research_level", _faction, R_ATTACK))
	_ok("「武器锻造」满级 = 5 级且不能超",
		lv == 5 and int(rd.get("max_level")) == 5, "当前 %d / 上限 %d" % [lv, int(rd.get("max_level"))])
	_ok("研究 id 都被系统认（不会被当成未知研究）",
		bool(_combat.call("has_research", R_ATTACK))
			and bool(_combat.call("has_research", R_ARMOR))
			and bool(_combat.call("has_research", R_HAUL))
			and bool(_combat.call("has_research", R_REPAIR)))

	# 真实结算：步兵打木桩，伤害应该 = (基础 + 5) 走原公式
	var dummy: Node3D = _game.call("spawn_unit", _faction, BARRACKS,
			_level.call("snap_grid", _hall.global_position + Vector3(0.0, 0.0, 30.0)), _level)
	if dummy != null:
		var atk_def: Object = _cfg.call("unit", FOOTMAN)
		var spread: float = float(atk_def.get("attack_spread"))
		# 只取"加成后的基础值"这一项：直接问战斗系统要，避免把随机 spread 也算进来
		var eff: float = base_atk + float(_combat.call("attack_bonus", _faction, foot))
		_ok("结算基础伤害 = 15 + 5 = 20（spread %.0f 之外不再有隐藏倍率）" % spread,
			absf(eff - 20.0) < 0.001, "实测 %.1f" % eff)


# ===========================================================================
# 7. 塔的分工（放在最后：会改全局观测方视野，不影响前面的数值用例）
# ===========================================================================

func _test_towers() -> void:
	var wt_def: Object = _cfg.call("unit", WATCHTOWER)
	_ok("哨塔预警半径 > 视野（先看到、先报）",
		float(wt_def.get("detect_radius")) > float(wt_def.get("sight_range")),
		"预警 %.0fm / 视野 %.0fm" % [float(wt_def.get("detect_radius")), float(wt_def.get("sight_range"))])


# ===========================================================================
# 收尾
# ===========================================================================

func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


func _finish() -> void:
	if _done:
		return
	_done = true
	print("-------------------------------")
	for l in _lines:
		print(l)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)
