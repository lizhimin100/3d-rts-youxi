extends SceneTree
## 职责：`run-game --check` 的全部无窗口体检（唯一入口）
## 属于：Tests/checks
## 用法：godot --headless --path . --script Tests/checks/check_all.gd
##
## 纪律：
##   · 检查调用**真实代码**（Model 内核 / I18n / Keys / 场景文件），不在检查里重推公式；
##   · 每条检查都要能"故意改坏"打红；
##   · 失败退出码非 0；通过也要打印计数，避免"0 条断言算通过"。
##
## 2026-11-22：旧单兵系统物理删除后，本文件同步重写 —— 删掉了所有"读旧 GDScript 源码找字符串"
## 的断言（那种断言在文件消失后会变成 `_read` 空串假通过），改成**读真实数据 + 真跑内核**。

const JsonFile := preload("res://Engine/util/json_file.gd")

const SCREENS := "res://Content/data/screens.json"
const COMBAT_JSON := "res://Content/data/combat.json"
const UNITS_JSON := "res://Content/data/units.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const SHELLS_JSON := "res://Content/data/map_shells.json"
const LAYOUTS_JSON := "res://Content/data/player_layouts.json"
const ENCOUNTERS_JSON := "res://Content/data/enemy_encounters.json"
const SQUAD_JSON := "res://Content/data/squad.json"

const UI_THEME := "res://Content/ui/main_theme.tres"
const UI_SHOWCASE := "res://Screens/ui/ThemeShowcase.tscn"
const UI_STYLE_GUIDE := "res://Content/docs/ui_style_guide.md"

const BATTLE_SCENE := "res://Screens/scenes/战役.tscn"
const BATTLE_SCRIPT := "res://Screens/world/battle/战役战场.gd"
const CAMERA_SCRIPT := "res://Screens/world/battle/战役镜头.gd"
const BOARD_SCRIPT := "res://Screens/world/battle/战役棋盘.gd"
const BUILDINGS_SCRIPT := "res://Screens/world/battle/战役建筑层.gd"
const TERRAIN_SCRIPT := "res://Screens/world/battle/战役地形.gd"
const UNIT_LAYER := "res://Screens/world/units/单兵层.gd"
const BLOOD_LAYER := "res://Screens/world/units/单位血条.gd"
const HUD_SCRIPT := "res://Screens/hud/战役HUD.gd"
const HUD_SCENE := "res://Screens/hud/战役HUD.tscn"
const CARD_SCENE := "res://Screens/hud/卡牌.tscn"
const BACKLOG := "res://Content/docs/backlog.md"

const TOP_DIRS := ["Engine", "Model", "Screens", "Game", "Content", "Tests", "Tools", "Documents"]
const LEGACY_DIRS := ["代码", "场景", "美术", "音频", "地图", "工具", "文档"]
## 2026-11-22 起只留这 7 个自动加载：Cfg / Game 两个旧单兵单例随旧系统一起下线。
const AUTOLOADS := ["App=", "Keys=", "I18n=", "SaveSvc=", "AudioSvc=", "Platform=", "DbgBridge="]
## 旧单兵 / 旧寻路 / 旧测试图：必须**物理不存在**
const PURGED_PATHS := [
	"Screens/input",
	"Screens/world/crowd",
	"Screens/camera/魔兽镜头.gd",
	"Screens/scenes/主场景.tscn",
	"Screens/scenes/小队战场.tscn",
	"Screens/scenes/人群演示.tscn",
	"Screens/scenes/四季演示.tscn",
	"Screens/world/规划沙盘.gd",
	"Screens/world/squad",
	"Model/Squad/SquadFormation.cs",
	"Screens/hud/HUD.gd",
	"Screens/hud/选择网格.gd",
	"Game/core",
	"Game/units",
	"Game/systems",
	"Game/map",
	"Game/config",
	"Game/adapters/damage.gd",
	"Game/adapters/economy.gd",
	"Game/adapters/skirmish.gd",
	"Model/Battle/LaneBattle.cs",
	"Model/Battle/LevelRunner.cs",
	"Model/Battle/LevelSimulator.cs",
	"Model/Battle/Skirmish.cs",
	"Model/Core/Damage.cs",
	"Tests/suites",
	"Content/maps/_四季演示.tres",
	"Content/maps/_测试地图.tres",
]

const REF_SCAN_DIRS := ["Engine", "Model", "Screens", "Game", "Content", "Tests", "Tools", "addons"]
const RE_PRELOAD := "preload\\(\\s*[\"'](res://[^\"']+)[\"']"
const RE_RES_PATH := "path=\"(res://[^\"]+)\""
const RE_ANY_RES := "(res://[^\"',)\\s]+)"
const MODEL_FORBIDDEN_CS := ["using Godot", "Godot.", "GodotObject", "GD.", "partial class",
	"NodePath", "[Export]", "[GlobalClass]", "Variant"]

var _pass := 0
var _fail := 0
var _names: Array[String] = []
var _content_cache: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 地基体检（run-game --check） ==========")
	_check_layout()
	_check_hard_paths()
	_check_json_tables()
	_check_units_data()
	_check_planning_data()
	_check_level_data()
	_check_shell_data()
	_check_layouts_and_encounters()
	_check_model_purity()
	_check_distance_law()
	_check_combat_formula()
	_check_arena()
	_check_squad_roles()
	_check_phase2_rules()
	_check_squad_sim()
	_check_phase1_kinematics()
	_check_battle_scene()
	_check_squad_visuals()
	_check_camera_rules()
	_check_board_rules()
	_check_scene_visuals()
	_check_hud_rules()
	_check_screens()
	_check_i18n()
	_check_assets()
	_check_asset_manifest()
	_check_manifest()
	_check_engine_pin()
	_check_ui_theme()
	_check_docs()
	_check_legacy_removed()
	_finish()


# ===========================================================================
# 1. 目录 / 自动加载 / 主场景
# ===========================================================================
func _check_layout() -> void:
	var missing: Array[String] = []
	for d in TOP_DIRS:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://" + d)):
			missing.append(d)
	_ok("七块砖目录齐全（%s）" % ", ".join(TOP_DIRS), missing.is_empty(), "缺：" + ", ".join(missing))

	var legacy: Array[String] = []
	for d in LEGACY_DIRS:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://" + d)):
			legacy.append(d)
	_ok("旧目录已清空", legacy.is_empty(), "残留：" + ", ".join(legacy))

	var text := _read("res://project.godot")
	var lack: Array[String] = []
	for a in AUTOLOADS:
		if not text.contains("\n" + a):
			lack.append(a.trim_suffix("="))
	_ok("自动加载已注册（%d 个）" % AUTOLOADS.size(), lack.is_empty(), "缺：" + ", ".join(lack))
	_ok("旧的 Cfg / Game 单例已下线", not text.contains("\nCfg=") and not text.contains("\nGame="))
	_ok("主场景指向战役垂直切片", text.contains("run/main_scene=\"res://Screens/scenes/战役.tscn\""),
		"实际：" + _line_with(text, "run/main_scene"))


func _line_with(text: String, needle: String) -> String:
	for ln in text.split("\n"):
		if ln.contains(needle):
			return ln.strip_edges()
	return "(未找到)"


# ===========================================================================
# 2. 硬路径（preload / ext_resource / project.godot）
# ===========================================================================
func _check_hard_paths() -> void:
	var re_preload := RegEx.new()
	re_preload.compile(RE_PRELOAD)
	var re_res := RegEx.new()
	re_res.compile(RE_RES_PATH)
	var re_any := RegEx.new()
	re_any.compile(RE_ANY_RES)
	var problems: Array[String] = []
	var count := 0
	for d in REF_SCAN_DIRS:
		for f in _walk("res://" + d):
			var short: String = f.replace("res://", "")
			var ext: String = String(f.get_extension())
			if ext == "gd":
				var line_no := 0
				for line in _read(f).split("\n"):
					line_no += 1
					if line.strip_edges().begins_with("#"):
						continue
					for m in re_preload.search_all(line):
						count += 1
						var p: String = m.get_string(1)
						if not FileAccess.file_exists(p):
							problems.append("%s:%d preload → %s" % [short, line_no, p])
			elif ext == "tres" or ext == "tscn":
				for m in re_res.search_all(_read(f)):
					count += 1
					var p: String = m.get_string(1)
					if not FileAccess.file_exists(p):
						problems.append("%s ext_resource → %s" % [short, p])
	for m in re_any.search_all(_read("res://project.godot")):
		count += 1
		var auto_path := m.get_string(1)
		if not FileAccess.file_exists(auto_path):
			problems.append("project.godot → %s" % auto_path)
	_ok("硬路径都指向真实文件（preload / ext_resource / 自动加载 %d 条）" % count,
		problems.is_empty(), "; ".join(problems.slice(0, 6)))


# ===========================================================================
# 3. 数据表
# ===========================================================================
func _check_json_tables() -> void:
	var bad: Array[String] = []
	for p in [COMBAT_JSON, UNITS_JSON, PLANNING_JSON, LEVELS_JSON, SHELLS_JSON,
			LAYOUTS_JSON, ENCOUNTERS_JSON, SQUAD_JSON, SCREENS]:
		if JsonFile.read_dict(p, {}).is_empty():
			bad.append(p.replace("res://", ""))
	_ok("九张数据表都能解析且非空", bad.is_empty(), ", ".join(bad))

	var v: Dictionary = _content()
	if v.is_empty():
		_ok("内核数据校验（DataValidate）", false, "bridge 不可用")
		return
	_ok("内核数据校验通过（%d 兵种 / %d 张卡 / %d 关）" % [
			int(v.get("units", 0)), int(v.get("cards", 0)), _arr(v.get("levels")).size()],
		bool(v.get("ok", false)), _err_text(v.get("errors", [])))
	_ok("单场时长常量 = 60 秒（LevelDef.RoundSecondsSpec）",
		is_equal_approx(float(v.get("round_seconds", 0.0)), 60.0),
		"实际 %.1f" % float(v.get("round_seconds", 0.0)))


func _check_units_data() -> void:
	var doc := JsonFile.read_dict(UNITS_JSON, {})
	var units: Array = doc.get("units", [])
	var no_model: Array[String] = []
	var dangling: Array[String] = []
	var enabled := 0
	var visible := 0
	var visible_factions := {}
	for u in units:
		var row: Dictionary = u
		if not bool(row.get("enabled", true)):
			continue
		enabled += 1
		var render := bool(row.get("render", true))
		var path := String(row.get("model_path", ""))
		if not render:
			# 只实现逻辑、不上场：model_path 必须留空 —— 免得删了资产还留一条悬空路径
			if not path.is_empty():
				dangling.append(String(row.get("id", "?")))
			continue
		visible += 1
		visible_factions[String(row.get("faction", "?"))] = true
		if path.is_empty():
			no_model.append(String(row.get("id", "?")))
		elif not FileAccess.file_exists(path):
			no_model.append(String(row.get("id", "?")) + "(缺文件)")
	_ok("每个上场的兵种都绑定了真实 3D 模型（%d 个 / 启用 %d 个）" % [visible, enabled],
		no_model.is_empty(), ", ".join(no_model))
	_ok("不上场的兵种不留悬空 model_path", dangling.is_empty(), ", ".join(dangling))
	# 视觉口径（2026-11-22 收敛）：联盟只留 2 个兵种有模型，敌人只留 1 个阵营
	_ok("场上只画 2 个联盟兵种（步兵 / 弩兵）", _visible_count(units, "alliance") == 2,
		"实测 %d" % _visible_count(units, "alliance"))
	_ok("敌人只有一个阵营有模型（%s）" % ", ".join(visible_factions.keys()),
		visible_factions.size() == 2 and visible_factions.has("alliance"),
		"阵营：%s" % ", ".join(visible_factions.keys()))

	# --- 2026-11-22 单兵制：一批编制字段必须**物理不存在**，只留 body_radius ---
	var leftovers: Array[String] = []
	var bodies: Array[String] = []
	var pops: Array[String] = []
	for u in units:
		var row: Dictionary = u
		var uid := String(row.get("id", "?"))
		for k in ["squad_size", "formation", "squad_radius"]:
			if row.has(k):
				leftovers.append("%s.%s" % [uid, k])
		var b := float(row.get("body_radius", 0.0))
		if b < 0.15 - 0.0001 or b > 1.2 + 0.0001:
			bodies.append("%s=%.2f" % [uid, b])
		if int(row.get("pop_cost", -1)) != 0:
			pops.append("%s=%d" % [uid, int(row.get("pop_cost", -1))])
	_ok("单位卡没有小队编制字段（一个卡面 = 一名单兵）", leftovers.is_empty(), ", ".join(leftovers))
	_ok("单兵身位 body_radius 在 0.15~1.2 米（%d 个兵种）" % units.size(), bodies.is_empty(),
		", ".join(bodies))
	_ok("征召只吃 CP 不吃人口（所有兵种 pop_cost = 0）", pops.is_empty(), ", ".join(pops))
	var placeholder: Array[String] = []
	for u in units:
		var row: Dictionary = u
		if bool(row.get("use_placeholder_mesh", false)):
			placeholder.append(String(row.get("id", "?")))
	_ok("没有任何兵种退回占位网格", placeholder.is_empty(), ", ".join(placeholder))


func _visible_count(units: Array, faction: String) -> int:
	var n := 0
	for u in units:
		var row: Dictionary = u
		if String(row.get("faction", "")) == faction and bool(row.get("render", true)) \
				and bool(row.get("enabled", true)):
			n += 1
	return n


func _check_planning_data() -> void:
	var doc := JsonFile.read_dict(PLANNING_JSON, {})
	var bad: Array[String] = []
	var train_cards := 0
	var build_cards := 0
	var strategy_cards := 0
	var train_units := 0
	for c in doc.get("cards", []):
		var row: Dictionary = c
		var kind := String(row.get("kind", ""))
		var cid := String(row.get("id", "?"))
		if row.has("role"):
			bad.append(cid + " 仍有 role")
		if kind == "train":
			train_cards += 1
			train_units = maxi(train_units, int(row.get("units", 0)))
			if String(row.get("building_tag", "")).is_empty():
				bad.append(cid + " 缺 building_tag")
			if String(row.get("units_mode", "")) not in ["per_building", "split"]:
				bad.append(cid + " units_mode 非法")
			if bool(row.get("exhaust", true)):
				bad.append(cid + " 训练牌不该 exhaust")
		elif kind == "build":
			build_cards += 1
			if not bool(row.get("exhaust", false)):
				bad.append(cid + " 建造牌必须 exhaust")
		elif kind == "strategy":
			strategy_cards += 1
		else:
			bad.append(cid + " kind 非法")
	_ok("卡组：训练 ×%d / 建造 ×%d / 策略 ×%d（无 role）" % [train_cards, build_cards, strategy_cards],
		train_cards >= 1 and build_cards >= 1 and strategy_cards >= 1 and bad.is_empty(),
		", ".join(bad))
	_ok("训练牌一次产出（per_building）×%d 名" % train_units, train_units >= 1)

	var hand: Array = (doc.get("hand", {}) as Dictionary).get("opening", [])
	_ok("起手牌 %d 张（单轮死斗只准备一场）" % hand.size(), hand.size() >= 5 and hand.size() <= 10)

	var boost: Dictionary = (doc.get("strategies", {}) as Dictionary).get("train_boost", {})
	_ok("「加快训练」= 本回合征召 ×1.5", is_equal_approx(float(boost.get("train_count_mult", 0.0)), 1.5), str(boost))

	var cp: Dictionary = doc.get("cp", {})
	_ok("CP 上限 ≥ 单次规划投入（%d / %d）" % [int(cp.get("cap", 0)), int(cp.get("start", 0))],
		int(cp.get("cap", 0)) >= int(cp.get("start", 0)))

	var pop: Dictionary = doc.get("pop", {})
	var base_pop := int(pop.get("base", 0))
	var producer_pop := 0
	for b in doc.get("buildings", []):
		var row2: Dictionary = b
		if String(row2.get("kind", "")) == "producer":
			producer_pop = maxi(producer_pop, int(row2.get("pop", 0)))
	_ok("基地自带人口 %d ≥ 产兵建筑所需 %d（无农场牌也不会卡死）" % [base_pop, producer_pop],
		base_pop >= maxi(producer_pop, 1))

	var kinds := {}
	var effect_bad: Array[String] = []
	for b2 in doc.get("buildings", []):
		var bd: Dictionary = b2
		var kind2 := String(bd.get("kind", ""))
		kinds[kind2] = int(kinds.get(kind2, 0)) + 1
		if kind2 == "support" and not bd.has("aura"):
			effect_bad.append(String(bd.get("id", "?")) + " 缺 aura")
		if kind2 == "economy" and not bd.has("economy"):
			effect_bad.append(String(bd.get("id", "?")) + " 缺 economy")
		if kind2 == "defense" and not bd.has("defense"):
			effect_bad.append(String(bd.get("id", "?")) + " 缺 defense")
	_ok("建筑大类齐全（keep/producer/economy/support/defense）", kinds.size() >= 5, str(kinds))
	_ok("光环/经济/防御效果都写在数据里（不是代码分支）", effect_bad.is_empty(), ", ".join(effect_bad))
	_ok("不再有占区减伤字段 max_drain_reduction", not doc.has("max_drain_reduction"))

	# 建筑落位规格：唯一消费者是 RtsTileSpec；这里只核对数据在合法区间里
	var place: Dictionary = doc.get("placement", {})
	var ratio := float(place.get("footprint_ratio", 0.0))
	_ok("建筑水平占地配在 38%%~44%% 之间（实测 %.0f%%）" % (ratio * 100.0),
		ratio >= 0.38 - 0.0001 and ratio <= 0.44 + 0.0001,
		"placement.footprint_ratio=%.3f" % ratio)
	_ok("建筑底座中心锚在格子左上象限（anchor_u/v 都是负的）",
		float(place.get("anchor_u", 0.0)) < -0.05 and float(place.get("anchor_v", 0.0)) < -0.05,
		"u=%.2f v=%.2f" % [float(place.get("anchor_u", 0.0)), float(place.get("anchor_v", 0.0))])
	var facing: Dictionary = place.get("facing_deg", {})
	_ok("玩家侧建筑朝向增量 = 180°（模型正面 -Z → 面向镜头 +Z）",
		absf(float(facing.get("player", 0.0)) - 180.0) < 0.01, str(facing))


func _check_level_data() -> void:
	var doc := JsonFile.read_dict(LEVELS_JSON, {})
	var bad: Array[String] = []
	var asm_levels := 0
	for lv in doc.get("levels", []):
		var row: Dictionary = lv
		if (row.get("assembly", {}) as Dictionary).is_empty():
			continue
		asm_levels += 1
		var lid := String(row.get("id", "?"))
		var secs := float(row.get("round_seconds", 0.0))
		if not is_equal_approx(secs, 60.0):
			bad.append("%s 时长 %.1f" % [lid, secs])
		var rounds: Array = row.get("rounds", [])
		if rounds.is_empty():
			bad.append(lid + " 没有轮次")
		for r in rounds:
			var rd: Dictionary = r
			if rd.has("kind"):
				bad.append(lid + " 仍有 kind=attack/defend")
			var waves: Array = rd.get("enemy_waves", [])
			if waves.is_empty():
				bad.append(lid + " 有空轮次")
			for w in waves:
				var t := float((w as Dictionary).get("t", 0.0))
				if t < 0.0 or t > secs + 0.001:
					bad.append("%s 波次 t=%.1f 越界" % [lid, t])
		var bf: Dictionary = row.get("battlefield", {})
		if bf.is_empty():
			bad.append(lid + " 缺 battlefield")
		else:
			var dp := float(bf.get("deploy_player", 0.0))
			var de := float(bf.get("deploy_enemy", 0.0))
			if dp <= 0.0 or de <= 0.0 or de - dp < 1200.0:
				bad.append(lid + " 部署线非法")
			if float(bf.get("width", 0.0)) < 600.0:
				bad.append(lid + " 战场太窄")
	_ok("组装关卡 %d 个：单轮波次（无 attack/defend）、60 秒、battlefield 合法" % asm_levels,
		asm_levels >= 1 and bad.is_empty(), ", ".join(bad.slice(0, 5)))

	var hp_bad: Array[String] = []
	for lv2 in doc.get("levels", []):
		var row2: Dictionary = lv2
		if (row2.get("assembly", {}) as Dictionary).is_empty():
			continue
		var php := float(row2.get("player_base_hp", 0.0))
		var ehp := float(row2.get("enemy_base_hp", 0.0))
		if php < 30.0 or php > 120.0 or ehp < 30.0 or ehp > 120.0:
			hp_bad.append("%s=%.0f/%.0f" % [String(row2.get("id", "?")), php, ehp])
	_ok("双方基地血量在 30~120（单轮 base_damage 结算）", hp_bad.is_empty(), ", ".join(hp_bad))


func _check_shell_data() -> void:
	var doc := JsonFile.read_dict(SHELLS_JSON, {})
	var shells: Array = doc.get("shells", [])
	_ok("底壳至少 1 张", shells.size() >= 1)
	if shells.is_empty():
		return
	var sh: Dictionary = shells[0]
	var size: Dictionary = sh.get("size", {})
	var sx := float(size.get("x", 0.0))
	var sz := float(size.get("z", 0.0))
	_ok("底壳尺寸 %.0f×%.0f m（三区各一屏）" % [sx, sz], sx >= 140.0 and sz >= 36.0)

	var reg: Dictionary = sh.get("regions", {})
	var widths: Array[String] = []
	for k in ["player", "neutral", "enemy"]:
		var poly: Array = reg.get(k, [])
		if poly.size() < 3:
			widths.append(k + ":缺")
			continue
		var mn := 1e9
		var mx := -1e9
		for p in poly:
			var x := float((p as Array)[0])
			mn = minf(mn, x)
			mx = maxf(mx, x)
		_ok("势力区 %s 宽 %.0f m" % [k, mx - mn], mx - mn >= 40.0)
		widths.append(k)
	_ok("三块势力区都能读出宽度", widths.size() == 3, ", ".join(widths))

	var tiles: Array = sh.get("tiles", [])
	var player_tiles: Array = []
	var keeps := 0
	for t in tiles:
		var row: Dictionary = t
		if String(row.get("side", "")) == "player":
			player_tiles.append(row)
			if String(row.get("role", "")) == "keep":
				keeps += 1
	_ok("玩家区战术格子 %d 个（3 列 × 每列 6 格 = 18）" % (player_tiles.size() - keeps),
		player_tiles.size() - keeps == 18, "含主堡共 %d" % player_tiles.size())
	_ok("玩家区恰好 1 个主堡格", keeps == 1, "实际 %d" % keeps)

	# 3 列 × 6 格：按 Z（横向车道）分组，每组必须 6 格；组数必须 3
	var lanes := {}
	for t in player_tiles:
		var row: Dictionary = t
		if String(row.get("role", "")) == "keep":
			continue
		var z := snappedf(float(row.get("z", 0.0)), 0.01)
		lanes[z] = int(lanes.get(z, 0)) + 1
	var lane_counts: Array = lanes.values()
	lane_counts.sort()
	_ok("棋盘是 3 条车道 × 每道 6 格（实测 %d 道 / 每道 %s 格）" % [lanes.size(), str(lane_counts)],
		lanes.size() == 3 and lane_counts == [6, 6, 6], str(lanes))

	# 格间必须留缝（TacticalTile.MinGapM = 1.0）
	var min_gap := 1e9
	for i in tiles.size():
		for j in range(i + 1, tiles.size()):
			var a: Dictionary = tiles[i]
			var b: Dictionary = tiles[j]
			var dx := maxf(absf(float(a.get("x", 0.0)) - float(b.get("x", 0.0)))
				- (float(a.get("w", 0.0)) + float(b.get("w", 0.0))) * 0.5, 0.0)
			var dz := maxf(absf(float(a.get("z", 0.0)) - float(b.get("z", 0.0)))
				- (float(a.get("d", 0.0)) + float(b.get("d", 0.0))) * 0.5, 0.0)
			min_gap = minf(min_gap, maxf(dx, dz))
	_ok("任意两格边到边间隙 ≥ 1.0 m（实测 %.2f m，模型按左上角对齐不会互穿）" % min_gap,
		min_gap >= 1.0 - 0.001)

	var terr: Dictionary = sh.get("terrain", {})
	var cell := float(terr.get("cell", 1.5))
	var cols := int(round(sx / cell)) + 1
	var rows := int(round(sz / cell)) + 1
	var heights: Array = terr.get("heights", [])
	var surf: Array = (sh.get("surface", {}) as Dictionary).get("index", [])
	_ok("高度场 %d×%d = %d 点（与 size/cell 一致）" % [cols, rows, cols * rows],
		heights.size() == cols * rows, "实际 %d" % heights.size())
	_ok("地表索引与高度场同长", surf.size() == heights.size(),
		"%d vs %d" % [surf.size(), heights.size()])

	var board: Dictionary = sh.get("board", {})
	var theme: Dictionary = board.get("theme", {})
	_ok("棋盘双色主题写在底壳数据里（可换皮）",
		theme.has("light") and theme.has("dark") and theme.has("rim"),
		str(theme.keys()))

	# --- 三块战术区必须绝对平整（Y = 0）---
	# 这是"格子不陷地"的根：战术区里只要有一处起伏，格子就会一半埋进土里。
	var regions: Dictionary = sh.get("regions", {})
	var area := _region_bbox(regions)
	var outside := 0
	var worst := 0.0
	var hills := 0.0
	for row in rows:
		var wz := -sz * 0.5 + float(row) * cell
		for col in cols:
			var wx := -sx * 0.5 + float(col) * cell
			var h := absf(float(heights[row * cols + col]))
			if area.has_point(Vector2(wx, wz)):
				if h > 0.001:
					outside += 1
					worst = maxf(worst, h)
			else:
				hills = maxf(hills, h)
	_ok("三块战术区地表严格平整 Y=0（区外最高 %.1f m）" % hills,
		outside == 0 and hills > 2.0, "区内 %d 点不平，最大 %.3f m" % [outside, worst])

	# --- 底壳必须比战场大一圈：镜头贴到边界也看不到图外的虚空 ---
	var pf_half_x := maxf(absf(area.position.x), absf(area.end.x))
	var pf_half_z := maxf(absf(area.position.y), absf(area.end.y))
	var ext_x := sx * 0.5 - pf_half_x
	var ext_z := sz * 0.5 - pf_half_z
	_ok("外围地形超出镜头可移动边界 60%% 以上（X %+.0f m / Z %+.0f m）" % [ext_x, ext_z],
		ext_x >= pf_half_x * 0.6 and ext_z >= pf_half_z * 0.6,
		"X %.0f/%.0f  Z %.0f/%.0f" % [ext_x, pf_half_x * 0.6, ext_z, pf_half_z * 0.6])

	# --- 远景装饰带：战术区之外要有树/岩石 ---
	var outer_decor := 0
	for d in sh.get("decorations", []):
		var row2: Dictionary = d
		if not area.grow(2.0).has_point(Vector2(float(row2.get("x", 0.0)), float(row2.get("z", 0.0)))):
			outer_decor += 1
	_ok("远景装饰带已铺到战术区之外（%d 件）" % outer_decor, outer_decor >= 40)


## 三块势力区域多边形的外包矩形（世界 XZ）。
func _region_bbox(regions: Dictionary) -> Rect2:
	var min_x := 1e9
	var max_x := -1e9
	var min_z := 1e9
	var max_z := -1e9
	for kind in ["player", "neutral", "enemy"]:
		for row in (regions.get(kind, []) as Array):
			if row is Array and (row as Array).size() >= 2:
				min_x = minf(min_x, float(row[0]))
				max_x = maxf(max_x, float(row[0]))
				min_z = minf(min_z, float(row[1]))
				max_z = maxf(max_z, float(row[1]))
	if min_x > max_x:
		return Rect2()
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))


func _check_layouts_and_encounters() -> void:
	var shells := JsonFile.read_dict(SHELLS_JSON, {})
	var sh: Dictionary = (shells.get("shells", []) as Array)[0] if not shells.is_empty() else {}
	var tile_ids := {}
	for t in sh.get("tiles", []):
		tile_ids[int((t as Dictionary).get("index", 0))] = true

	var layouts := JsonFile.read_dict(LAYOUTS_JSON, {})
	var bad: Array[String] = []
	for lay in layouts.get("layouts", []):
		var row: Dictionary = lay
		for slot in row.get("slots", []):
			var s: Dictionary = slot
			if not tile_ids.has(int(s.get("tile", 0))):
				bad.append("%s → 格子 %d 不存在" % [String(row.get("id", "?")), int(s.get("tile", 0))])
		for t in row.get("active_tiles", []):
			if not tile_ids.has(int(t)):
				bad.append("%s → 激活格子 %d 不存在" % [String(row.get("id", "?")), int(t)])
	_ok("玩家布局卡引用的格子都存在（%d 张）" % (layouts.get("layouts", []) as Array).size(),
		bad.is_empty(), ", ".join(bad.slice(0, 5)))

	var encs := JsonFile.read_dict(ENCOUNTERS_JSON, {})
	var bad2: Array[String] = []
	for enc in encs.get("encounters", []):
		var row: Dictionary = enc
		for slot in row.get("tile_buildings", []):
			var s: Dictionary = slot
			if not tile_ids.has(int(s.get("tile", 0))):
				bad2.append("%s → 格子 %d 不存在" % [String(row.get("id", "?")), int(s.get("tile", 0))])
	_ok("敌人遭遇卡引用的格子都存在（%d 张）" % (encs.get("encounters", []) as Array).size(),
		bad2.is_empty(), ", ".join(bad2.slice(0, 5)))


# ===========================================================================
# 4. 内核边界 / 距离铁律 / 伤害公式
# ===========================================================================
func _check_model_purity() -> void:
	var hits: Array[String] = []
	var files := 0
	for f in _walk("res://Model"):
		if not f.ends_with(".cs"):
			continue
		files += 1
		var line_no := 0
		for line in _read(f).split("\n"):
			line_no += 1
			var t := line.strip_edges()
			if t.begins_with("//") or t.begins_with("///") or t.begins_with("*"):
				continue
			for bad in MODEL_FORBIDDEN_CS:
				if t.contains(bad):
					hits.append("%s:%d %s" % [f.get_file(), line_no, bad])
	_ok("Model 是纯 C#（零 Godot 引用，%d 个 .cs）" % files, hits.is_empty(),
		"; ".join(hits.slice(0, 5)))
	var proj := _read("res://战争原岛.csproj")
	_ok("宿主 csproj 排除了 Model/**/*.cs（不重复编译）", proj.contains("Model"))
	var mcs := _read("res://Model/WarIsland.Model.csproj")
	_ok("Model 项目文件不含 Godot SDK 引用",
		not mcs.contains("Sdk=\"Godot") and not mcs.contains("PackageReference Include=\"Godot"))


func _check_distance_law() -> void:
	var src := _read("res://Model/Core/RtsUnits.cs")
	_ok("R1 = 0.015 的唯一真源在 Model/Core/RtsUnits.cs", src.contains("0.015"))
	var cjk: Array[String] = []
	for f in _walk("res://Screens/world/battle") + _walk("res://Screens/world/units") \
			+ _walk("res://Screens/hud") + _walk("res://Screens/ui"):
		if not f.ends_with(".gd"):
			continue
		if _read(f).contains("0.015") or _read(f).contains("66.6"):
			cjk.append(f.replace("res://", ""))
	_ok("Screens 侧不写 0.015 字面量（一律走 r1()/米()/值()）", cjk.is_empty(),
		", ".join(cjk.slice(0, 4)))
	var mdl := _mdl()
	if mdl != null:
		_ok("桥的 R1 / 换算是直通真源（0.015 / 60 米 = 4000 游戏数值）",
			is_equal_approx(float(mdl.call("R1")), 0.015)
			and is_equal_approx(float(mdl.call("ToUnits", 60.0)), 4000.0),
			"%.4f / %.1f" % [float(mdl.call("R1")), float(mdl.call("ToUnits", 60.0))])


func _check_combat_formula() -> void:
	var mdl := _mdl()
	if mdl == null:
		_ok("六步伤害（内核）", false, "bridge=null")
		return
	var rules := JsonFile.read_dict(COMBAT_JSON, {})
	# 注意：`dodge` 在 C# 侧是**可选参数**，但 GDScript 走 call() 时必须把 8 个参数全给齐 ——
	# 少给一个，引擎会报 "Nonexistent function 'CombatProbe'"，整个函数静默中止，
	# 后面三条断言一起消失（这不是"参数不匹配的提示"，是"函数不存在"的误导性报错）。
	var mid: Dictionary = mdl.call("CombatProbe", 100.0, 0, 0.0, 0, rules, 0.5, 0.5, 0.0)
	var armored: Dictionary = mdl.call("CombatProbe", 100.0, 0, 10.0, 0, rules, 0.5, 0.5, 0.0)
	var miss: Dictionary = mdl.call("CombatProbe", 100.0, 0, 0.0, 0, rules, 0.5, 0.5, 100.0)
	_ok("零甲基准伤害 = 100（命中）",
		bool(mid.get("hit", false)) and is_equal_approx(float(mid.get("damage", 0.0)), 100.0),
		str(mid))
	_ok("护甲 10 会显著减伤但不会归零（%.1f）" % float(armored.get("damage", 0.0)),
		float(armored.get("damage", 0.0)) < 100.0 and float(armored.get("damage", 0.0)) > 1.0,
		str(armored))
	_ok("闪避 100 时命中率为 0、伤害为 0（命中步在伤害之前）",
		not bool(miss.get("hit", true)) and is_equal_approx(float(miss.get("damage", -1.0)), 0.0),
		str(miss))


# ===========================================================================
# 5. 小队内核（arena / 攻防时空 / 推演）
# ===========================================================================
func _check_arena() -> void:
	var mdl := _mdl()
	if mdl == null:
		_ok("小队战场校验", false, "bridge=null")
		return
	var res: Dictionary = mdl.call("SquadArenaValidate",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}),
		_json_level(), _json_shell(), _json_layout(), _json_encounter(),
		JsonFile.read_dict(SQUAD_JSON, {}))
	_ok("小队战场可组装（%d 格 / %d 玩家建筑 / %d 敌方建筑）" % [
			int(res.get("tiles", 0)), int(res.get("player_buildings", 0)),
			int(res.get("enemy_buildings", 0))],
		bool(res.get("ok", false)), _err_text(res.get("errors", [])))
	_ok("脊线点数 ≥ 5（A* 沿脊线推进，不是直线点对点）",
		int(res.get("ridge_points", 0)) >= 5, "实际 %d" % int(res.get("ridge_points", 0)))
	_ok("战场部署线：玩家 %d → 敌方 %d（相距 ≥ 1200 游戏数值）" % [
			int(res.get("deploy_player", 0)), int(res.get("deploy_enemy", 0))],
		int(res.get("deploy_enemy", 0)) - int(res.get("deploy_player", 0)) >= 1200)
	_ok("关卡按单轮波次解析（%d 轮，无 attack/defend 要求）" % int(res.get("rounds", 0)),
		int(res.get("rounds", 0)) >= 1)

	var probe: Dictionary = mdl.call("UnitBodyProbe",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}))
	_ok("单兵身位探针（%d 行，无小队槽位）" % _arr(probe.get("rows", [])).size(),
		bool(probe.get("ok", false)), _err_text(probe.get("errors", [])))
	var fp: Dictionary = mdl.call("FormationProbe", 9, 60.0,
		JsonFile.read_dict(SQUAD_JSON, {}))
	_ok("棋盘出生位两两 ≥ 硬核（9 人，最小 %.3f m）" % float(fp.get("min_distance_m", 0.0)),
		bool(fp.get("ok", false)), str(fp))


func _check_squad_roles() -> void:
	# 名字保留（入口不变），内容已改为**单轮单场死斗**：不再有 attack/defend 角色。
	var mdl := _mdl()
	if mdl == null:
		return
	var h := _new_session(mdl)
	if h <= 0:
		_ok("建战役会话", false, "SquadSessionNew 失败")
		return

	var st: Dictionary = mdl.call("SquadSessionState", h)
	var card := _first_train_card(st)
	_ok("起手牌里有可打的征召牌（无 role 区分）", card != "", card)
	if card != "":
		mdl.call("SquadSessionTrain", h, card)
	st = mdl.call("SquadSessionState", h)
	_ok("一张征召牌产出 %d 名（per_building：每座建筑各一批）" % int(st.get("attack_squads", 0)),
		int(st.get("attack_squads", 0)) >= 3, str(st.get("train_cards", [])))

	mdl.call("SquadSessionEndPlanning", h)
	mdl.call("SquadSessionAttack", h)
	st = mdl.call("SquadSessionState", h)
	var view: Dictionary = mdl.call("SquadView", h)
	var alive := 0
	var snap: Dictionary = {}
	for s in view.get("squads", []):
		var sq: Dictionary = s
		if not bool(sq.get("active", true)):
			continue
		alive += 1
		if snap.is_empty():
			snap = sq
	_ok("单场死斗：我方 %d 名单兵落到部署线" % alive, alive >= 3)
	_ok("单兵快照：member_count=1 + engaged/attack_cooldown/body_radius 齐全",
		int(snap.get("member_count", 0)) == 1 and snap.has("engaged")
		and float(snap.get("attack_cooldown", 0.0)) > 0.0
		and float(snap.get("body_radius", 0.0)) > 0.0,
		"member_count=%d keys=%s" % [int(snap.get("member_count", -1)), str(snap.keys())])
	var allowed := 0
	for order in ["attack", "move", "attack_move", "hold", "stop"]:
		if bool(mdl.call("SquadPlayerOrderAllowed", order)):
			allowed += 1
	_ok("玩家指令通道已关闭（单兵自动接战）", allowed == 0, "还允许 %d 条" % allowed)
	_ok("当前轮次标记为 attack（UI 两段式展示的第 1 场）", String(st.get("round_kind", "")) == "attack")

	# 第 2 场：清场 → 从 ArmyPlan 重新落地
	mdl.call("SquadSessionDefend", h)
	st = mdl.call("SquadSessionState", h)
	view = mdl.call("SquadView", h)
	var alive2 := 0
	for s2 in view.get("squads", []):
		if bool((s2 as Dictionary).get("active", true)):
			alive2 += 1
	_ok("下一轮重新落地：我方 %d 名（每轮从 ArmyPlan 重开）" % alive2, alive2 >= 3)
	_ok("第 2 场标记为 defend", String(st.get("round_kind", "")) == "defend")

	# 轮末清场：双方部队消失，建筑保留
	var built_before := (_arena_dict(mdl, h).get("player_buildings", []) as Array).size()
	mdl.call("SquadSessionEndRound", h)
	view = mdl.call("SquadView", h)
	var alive3 := 0
	for s3 in view.get("squads", []):
		if bool((s3 as Dictionary).get("active", true)):
			alive3 += 1
	var built_after := (_arena_dict(mdl, h).get("player_buildings", []) as Array).size()
	_ok("轮末清场：场上单兵归零、建筑保留（%d → %d 座）" % [built_before, built_after],
		alive3 == 0 and built_after == built_before and built_after >= 4)

	mdl.call("SquadSessionFree", h)


func _check_phase2_rules() -> void:
	# Phase 2 的规则断言全部在 C# Phase2Checks（唯一实现，含 3 项反向验错）；
	# GDScript 只负责把同一批数据喂进去并读结果，不重写任何规则。
	var mdl := _mdl()
	if mdl == null:
		_ok("Phase 2 规则自检", false, "bridge=null")
		return
	var res: Dictionary = mdl.call("Phase2SelfCheck",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}), JsonFile.read_dict(LEVELS_JSON, {}),
		JsonFile.read_dict(SHELLS_JSON, {}), JsonFile.read_dict(LAYOUTS_JSON, {}),
		JsonFile.read_dict(ENCOUNTERS_JSON, {}), JsonFile.read_dict(SQUAD_JSON, {}),
		String(_json_level().get("id", "")))
	var lines := _arr(res.get("lines", []))
	_ok("Phase 2 规则自检（4×4 / base_damage / 竖列棋盘 / 单轮 / 狂暴 / 结算 / 跳字）%d 项" % int(res.get("checks", 0)),
		bool(res.get("ok", false)) and int(res.get("checks", 0)) >= 30,
		_err_text(res.get("errors", [])))
	if not bool(res.get("ok", true)):
		for line in lines:
			if String(line).begins_with("FAIL"):
				print("  · " + String(line))


func _check_squad_sim() -> void:
	var mdl := _mdl()
	if mdl == null:
		return
	var a: Dictionary = mdl.call("SquadSimulate",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}), JsonFile.read_dict(LEVELS_JSON, {}),
		JsonFile.read_dict(SHELLS_JSON, {}), JsonFile.read_dict(LAYOUTS_JSON, {}),
		JsonFile.read_dict(ENCOUNTERS_JSON, {}), JsonFile.read_dict(SQUAD_JSON, {}),
		"level_asm_even_four__gnoll_press", 3, 7)
	var b: Dictionary = mdl.call("SquadSimulate",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}), JsonFile.read_dict(LEVELS_JSON, {}),
		JsonFile.read_dict(SHELLS_JSON, {}), JsonFile.read_dict(LAYOUTS_JSON, {}),
		JsonFile.read_dict(ENCOUNTERS_JSON, {}), JsonFile.read_dict(SQUAD_JSON, {}),
		"level_asm_even_four__gnoll_press", 3, 7)
	_ok("3 局推演能跑完", bool(a.get("ok", false)) and int(a.get("games", 0)) == 3,
		_err_text(a.get("errors", [])))
	_ok("同 seed 同数据 = 同结果（确定性）",
		int(a.get("wins", -1)) == int(b.get("wins", -2))
		and int(a.get("draws", -1)) == int(b.get("draws", -2))
		and is_equal_approx(float(a.get("avg_player_damage", 0.0)), float(b.get("avg_player_damage", -1.0))),
		"a=%d/%d b=%d/%d" % [int(a.get("wins", 0)), int(a.get("draws", 0)),
			int(b.get("wins", 0)), int(b.get("draws", 0))])
	_ok("推演有真实战报（DPS > 0、出兵 > 0）",
		float(a.get("avg_player_dps", 0.0)) > 0.0 and float(a.get("avg_player_squads", 0.0)) >= 2.0,
		"dps=%.1f squads=%.1f" % [float(a.get("avg_player_dps", 0.0)), float(a.get("avg_player_squads", 0.0))])
	# Phase 1 运动学读数（运行时）：叠模要接近 0，空挥要接近 0，朝向不要高频反转。
	_ok("运动学：分离后深叠 ≤ 4 对 / 空挥 ≤ 20 人·秒 / 朝向反转 ≤ 8/s",
		float(a.get("avg_overlap_pairs_after_max", 99.0)) <= 4.0
		and float(a.get("avg_unfired_engaged_seconds", 999.0)) <= 20.0
		and float(a.get("avg_heading_flips_per_sec", 99.0)) <= 8.0,
		"overlap_after=%.1f unfired=%.1f flips=%.2f" % [
			float(a.get("avg_overlap_pairs_after_max", -1.0)),
			float(a.get("avg_unfired_engaged_seconds", -1.0)),
			float(a.get("avg_heading_flips_per_sec", -1.0))])
	# 2026-11-24：单轮单场死斗（基地血只在 60 秒结算时按幸存 base_damage 扣）
	_ok("单轮死斗：平均轮数 ≥ 1、单轮扣血 > 0、无僵持",
		float(a.get("avg_rounds", 0.0)) >= 1.0
		and float(a.get("avg_round_base_damage", 0.0)) > 0.0
		and int(a.get("draws", 1)) == 0,
		"rounds=%.2f dmg/round=%.1f draws=%d" % [
			float(a.get("avg_rounds", -1.0)),
			float(a.get("avg_round_base_damage", -1.0)),
			int(a.get("draws", -1))])
	_ok("狂暴 / 差值结算读数存在（45 秒狂暴 + 60 秒兜底）",
		a.has("berserk_round_rate") and a.has("tie_diff_round_rate"),
		"berserk=%.1f%% tie=%.1f%%" % [
			float(a.get("berserk_round_rate", 0.0)) * 100.0,
			float(a.get("tie_diff_round_rate", 0.0)) * 100.0])


func _check_phase1_kinematics() -> void:
	var squad := JsonFile.read_dict(SQUAD_JSON, {})
	var formation: Dictionary = squad.get("formation", {})
	var combat: Dictionary = squad.get("combat", {})
	var fp := float(formation.get("file_pitch", 0.0))
	var rp := float(formation.get("rank_pitch", 0.0))
	var lg := float(formation.get("line_gap", 0.0))
	_ok("自动布阵间距 = 96 / 144 / 240（游戏数值）",
		is_equal_approx(fp, 96.0) and is_equal_approx(rp, 144.0) and is_equal_approx(lg, 240.0),
		"file=%.0f rank=%.0f gap=%.0f" % [fp, rp, lg])
	var hard := float(combat.get("hard_core_factor", 1.0))
	var stand := float(combat.get("stand_off_ratio", 1.0))
	var turn := float(combat.get("turn_rate_deg", 0.0))
	var dead := float(combat.get("facing_deadzone_deg", -1.0))
	_ok("硬核 0.90 / 停火 0.92R / 转向 540°·s⁻¹ / 死区 6°",
		is_equal_approx(hard, 0.9) and is_equal_approx(stand, 0.92)
		and is_equal_approx(turn, 540.0) and is_equal_approx(dead, 6.0),
		"hard=%.2f stand=%.2f turn=%.0f dead=%.1f" % [hard, stand, turn, dead])

	# 每个近战都必须能走进自己的开火线：HardCore(自己+任意敌人) < 自己的射程。
	var units_doc := JsonFile.read_dict(UNITS_JSON, {})
	var rows: Array = units_doc.get("units", [])
	var bad := ""
	for a in rows:
		var ua: Dictionary = a
		if not bool(ua.get("enabled", false)) or bool(ua.get("projectile", false)):
			continue
		var ra := float(ua.get("body_radius", 0.0)) / 0.015
		var range_a := float(ua.get("attack_range", 0.0))
		for b in rows:
			var ub: Dictionary = b
			if not bool(ub.get("enabled", false)):
				continue
			var rb := float(ub.get("body_radius", 0.0)) / 0.015
			var need := (ra + rb) * hard
			if need >= range_a:
				bad = "%s vs %s: %.1f ≥ %.1f" % [String(ua.get("id", "")), String(ub.get("id", "")), need, range_a]
				break
		if bad != "":
			break
	_ok("每个近战都能走进自己的开火线（HardCore < 射程）", bad == "", bad)


# ===========================================================================
# 6. 表现层约定（新场景 / 模型绑定 / 三阶段镜头 / 棋盘 / HUD）
# ===========================================================================
func _check_battle_scene() -> void:
	_ok("战役场景存在", FileAccess.file_exists(BATTLE_SCENE))
	var tscn := _read(BATTLE_SCENE)
	_ok("战役场景挂的是 战役战场.gd", tscn.contains("战役战场.gd"))
	var src := _read(BATTLE_SCRIPT)
	_ok("战役脚本零写死中文文案（全部走 I18n）", _count_cjk_literals(src) == 0,
		"实测 %d 处" % _count_cjk_literals(src))
	for k in ["phase_name", "round_kind", "built_count", "attack_squads", "defend_squads",
			"model_instances", "time_scale", "armed_card", "capture_outpost", "train_card",
			"arm_build", "begin_execution", "screen_pos_of_enemy", "select_all_squads"]:
		_ok("战役脚本对界面/截图暴露 " + k, src.contains(k))


func _check_squad_visuals() -> void:
	var src := _read(UNIT_LAYER)
	_ok("单兵层实例化真实 GLB（走 ArtKit.build_model + units.json 的 model_path）",
		src.contains("ArtKit.build_model") and src.contains("model_path"))
	_ok("单兵层没有退回纯色胶囊", not src.contains("CapsuleMesh"))
	_ok("单兵层用阵营换色（ArtKit.apply_team_color）", src.contains("apply_team_color"))
	_ok("骨骼动画接进状态机（idle / move / attack / death 四态）",
		src.contains("ArtKit.set_anim") and src.contains("\"attack\"")
		and src.contains("\"death\"") and src.contains("\"move\""))
	_ok("错峰空降：落点高度 + 重力曲线 + 0.05~0.08s 间隔",
		src.contains("DROP_HEIGHT") and src.contains("DROP_STAGGER")
		and src.contains("1.0 - p * p") and float(_const_value(src, "DROP_STAGGER")) >= 0.05
		and float(_const_value(src, "DROP_STAGGER")) <= 0.08)
	_ok("落地压扁回弹 + 脚下光圈",
		src.contains("squash") and src.contains("_land_ring") and src.contains("1.0 + squash"))
	_ok("行走颠簸/前倾 + 攻击前冲/后坐（不是静态平移）",
		src.contains("bob") and src.contains("lean") and src.contains("lunge"))
	_ok("远程有简易弹道、受击有闪白",
		src.contains("_fire_tracer") and src.contains("_mat_flash") and src.contains("material_override"))
	_ok("单兵层没有任何玩家指令入口（只画，不下令）",
		not src.contains("Order") and not src.contains("order_selected"))
	var bl := _read(BLOOD_LAYER)
	_ok("血条按人画（满血不画 / 选中必画）",
		bl.contains("BAR_W") and bl.contains("_selected.has") and bl.contains("hp >= max_hp"))
	var bl2 := _read(BUILDINGS_SCRIPT)
	_ok("建筑层用 planning.json 的 model_path 实例化（不造占位盒）",
		bl2.contains("ArtKit.build_model") and bl2.contains("model_path") and not bl2.contains("BoxMesh"))
	_ok("建筑层按左上角建筑位对齐（building_x / building_z）",
		bl2.contains("building_x") and bl2.contains("building_z"))
	_ok("建筑层把超格模型缩进格子（不压邻格）", bl2.contains("holder.scale"))
	var terr := _read(TERRAIN_SCRIPT)
	_ok("地形用底壳高度场生成网格（不是一块 PlaneMesh 涂色）",
		terr.contains("heights") and terr.contains("PRIMITIVE_TRIANGLES") and not terr.contains("PlaneMesh"))
	_ok("地形装饰实例化既有资产（RtsDecorLib，不现拼占位）", terr.contains("RtsDecorLib"))


## 读脚本里的 `const NAME := 数字`
func _const_value(src: String, name: String) -> String:
	var re := RegEx.new()
	re.compile("const\\s+" + name + "\\s*:?=\\s*([0-9.]+)")
	var m := re.search(src)
	return m.get_string(1) if m != null else "0"


func _check_camera_rules() -> void:
	var src := _read(CAMERA_SCRIPT)
	_ok("三阶段相机有 apply_phase（planning / attack / defend / result）",
		src.contains("func apply_phase") and src.contains("\"planning\"")
		and src.contains("\"attack\"") and src.contains("\"defend\""))
	_ok("规划阶段锁定（不可平移）", src.contains("_locked = true"))
	_ok("攻防阶段允许平移但夹在战场内", src.contains("_clamp_focus") and src.contains("_bounds"))
	_ok("构图靠二分距离装矩形（不靠调参，任何比例不裁切）",
		src.contains("_fit_distance") and src.contains("unproject_position"))
	_ok("最大拉远只够装一个区（两区之和装不进一屏）", src.contains("_dist_fit"))
	_ok("有自动跟随（60 秒自动战斗不看着会跑丢）", src.contains("follow_world"))


func _check_board_rules() -> void:
	var src := _read(BOARD_SCRIPT)
	_ok("棋盘读底壳 board.theme 上色（可换皮）", src.contains("_theme") and src.contains("srgb_to_linear"))
	_ok("棋盘画两种锚点（左上角建筑位 / 正中心出兵位）",
		src.contains("building_x") and src.contains("spawn_x") and src.contains("_flat_ring"))
	_ok("棋盘有挑格子的高亮通道", src.contains("set_armed") and src.contains("_rebuild_highlight"))
	# 2026-11-22 参考图：格子靠"细虚线框"读出来（不是实心色块、不是厚边框）
	_ok("棋盘用细虚线框画格子（dash/gap/line 三段真实存在）",
		src.contains("_rebuild_dashes") and src.contains("_dash_edge")
		and src.contains("dash_m") and src.contains("gap_m") and src.contains("line_m"))
	var shell_doc := JsonFile.read_dict(SHELLS_JSON, {})
	var sh: Dictionary = (shell_doc.get("shells", []) as Array)[0] \
		if not (shell_doc.get("shells", []) as Array).is_empty() else {}
	var bstyle: Dictionary = (sh.get("look", {}) as Dictionary).get("board", {})
	var dash := float(bstyle.get("dash_m", 0.0))
	var gap := float(bstyle.get("gap_m", 0.0))
	var line_m := float(bstyle.get("line_m", 0.0))
	var line_a := float(bstyle.get("line_alpha", 0.0))
	var inset := float(bstyle.get("inset_m", -1.0))
	_ok("虚线参数配在数据里（段 %.2fm / 空 %.2fm / 线宽 %.2fm）" % [dash, gap, line_m],
		dash >= 0.4 and dash <= 1.6 and gap >= 0.25 and gap <= 1.2 and line_m >= 0.04 and line_m <= 0.2)
	_ok("虚线不透明度 %.0f%%（既看得见又不盖住地表）" % (line_a * 100.0),
		line_a >= 0.35 and line_a <= 0.92 and inset >= 0.0)
	_ok("主题里有独立的线条色（换皮只改 board.theme.line）",
		(sh.get("board", {}) as Dictionary).get("theme", {}).has("line"))


# ===========================================================================
# 6b. 3D 战场观感（地形材质 / 棋盘色层 / 立体地块 / 布光）
# ===========================================================================
##
## 这一组是为了别再退回"纯色塑料布 + 瓷砖棋盘 + 薄皮地块"：
## 2026-11-22 之前的三个问题都不是"调参没调好"，而是**用了另一份实现**——
## 地形现造材质、棋盘画实心块、地块只有一张平面。断言盯的是"有没有走唯一那份实现"。
func _check_scene_visuals() -> void:
	var assets := _read("res://Screens/world/art/地表资源.gd")
	_ok("地表贴图/图集/mat_map 只有一份实现（RtsTerrainAssets）",
		assets.contains("mat_map_texture") and assets.contains("atlas_rgba")
		and assets.contains("tex_grass") and assets.contains("bind_terrain_material"))

	var terr := _read(TERRAIN_SCRIPT)
	_ok("地形用工程里的地形材质（不再现造纯色材质）",
		terr.contains("make_terrain_material") and terr.contains("bind_terrain_material"))
	_ok("地块是立体块（顶面 + 侧壁 + 倒角 + 底面）",
		terr.contains("_add_block_surfaces") and terr.contains("bevel") and terr.contains("base_y"))
	_ok("侧壁/底面吃皮肤表材质（不是纯色）",
		terr.contains("skin_material") and terr.contains("block_side"))

	var brd := _read(BOARD_SCRIPT)
	_ok("棋盘是半透明色层（透出地形纹理，不是不透明色块）",
		brd.contains("TRANSPARENCY_ALPHA") and brd.contains("fill_alpha"))
	_ok("棋盘相邻格明暗差夹在 6%~10%",
		brd.contains("TWO_TONE_MIN") and brd.contains("TWO_TONE_MAX"))
	# 2026-11-22：棋盘改成"纯色半透明漆 + 网格化软边"，**不再自己叠一张草地贴图**。
	# 早先那版让色层也三平面铺草地（8m）而地形底材走 12.5m，两层周期打架 → 重影，
	# 而且色层不受光、亮度比地面高，整片棋盘像浮着一层塑料膜。
	_ok("棋盘不吃贴图（颜色只来自顶点色，纹理细节由底层地形透出来）",
		brd.contains("albedo_texture = null") and brd.contains("vertex_color_use_as_albedo"))
	_ok("棋盘用网格化顶点色做软边（不是硬边框）",
		brd.contains("GRID") and brd.contains("_tri_c") and brd.contains("edge.lerp(fill"))

	var shell_doc := JsonFile.read_dict(SHELLS_JSON, {})
	var sh: Dictionary = (shell_doc.get("shells", []) as Array)[0] \
		if not (shell_doc.get("shells", []) as Array).is_empty() else {}
	var look: Dictionary = sh.get("look", {})
	var bstyle: Dictionary = look.get("board", {})
	var two := float(bstyle.get("two_tone", 0.0))
	_ok("棋盘相邻格观感明暗差配在 6%%~10%%（实测 %.0f%%）" % (two * 100.0),
		two >= 0.06 - 0.0001 and two <= 0.10 + 0.0001)
	_ok("棋盘半透明度配在数据里（%d%%）" % int(float(bstyle.get("fill_alpha", 0.0)) * 100.0),
		float(bstyle.get("fill_alpha", 0.0)) > 0.0 and float(bstyle.get("fill_alpha", 1.0)) < 0.8)

	var bl := _read(BUILDINGS_SCRIPT)
	_ok("建筑按 AABB 归一化到单格 38%~44%（数据驱动，不写死魔法数）",
		bl.contains("RtsTileSpec.fit_scale") and bl.contains("footprint_ratio"))
	_ok("建筑底座锚在左上象限、朝向由数据给（玩家侧面向 +Z）",
		bl.contains("RtsTileSpec.center") and bl.contains("RtsTileSpec.yaw_deg")
		and bl.contains("building_x") and bl.contains("building_z"))

	var battle := _read("res://Screens/world/battle/战役战场.gd")
	_ok("布光 = 程序天空 + ACES 色调映射 + 补光",
		battle.contains("ProceduralSkyMaterial") and battle.contains("TONE_MAPPER_ACES")
		and battle.contains("DirectionalLight3D"))
	var off := ["ssao_enabled = false", "ssil_enabled = false", "ssr_enabled = false",
		"sdfgi_enabled = false", "volumetric_fog_enabled = false"]
	var missing: Array[String] = []
	for k in off:
		if not battle.contains(k):
			missing.append(k)
	_ok("高开销特效全部关闭（SSAO / SSIL / SSR / SDFGI / 体积雾）", missing.is_empty(), ", ".join(missing))
	var proj := _read("res://project.godot")
	_ok("渲染后端是 Mobile（低中端手机）", proj.contains("rendering_method=\"mobile\""))

	var cam := _read(CAMERA_SCRIPT)
	_ok("镜头夹取范围来自战场矩形（不是底壳尺寸，扩容后不会望出图外）",
		cam.contains("playfield") and cam.contains("_playfield"))

	_check_visuals_runtime(shell_doc, sh, look)


# ===========================================================================
# 6c. 3D 战场观感 —— **真跑代码**的那一半
# ===========================================================================
#
# 6b 那批断言全是 `src.contains("...")`：写对了就绿，哪怕运行时根本没生效。
# 2026-11-22 就是被这个坑了一次 —— 地形贴图压根没画到地上、建筑实测 0.38 也看不出来，
# 检查照样 160 项全过。所以这一组改成：喂真实输入、读真实输出。
func _check_visuals_runtime(shell_doc: Dictionary, sh: Dictionary, look: Dictionary) -> void:
	# --- ① 着色器旋钮：数据里写的每个 key 都必须在着色器里真实存在 ---
	var mat_res := load("res://Content/art/材质/地形材质.tres")
	_ok("地形材质能加载且是 ShaderMaterial", mat_res is ShaderMaterial, str(mat_res))
	if mat_res is ShaderMaterial:
		var sm := mat_res as ShaderMaterial
		var have := {}
		for u in sm.shader.get_shader_uniform_list():
			have[String(u.get("name", ""))] = true
		var miss_keys: Array[String] = []
		for key in RtsTerrainAssets.LOOK_UNIFORMS.keys():
			if not have.has(String(key)):
				miss_keys.append(String(key))
		_ok("look.terrain 每个旋钮都真实存在于着色器（%d 个）" % RtsTerrainAssets.LOOK_UNIFORMS.size(),
			miss_keys.is_empty(), "着色器里没有：" + ", ".join(miss_keys))
		_ok("着色器有底材对比放大 / 细节层 / 独立平铺距离",
			have.has("base_contrast") and have.has("detail_gain") and have.has("base_tile_m"))
		var contrast := float(sm.get_shader_parameter(&"base_contrast"))
		var detail := float(sm.get_shader_parameter(&"detail_gain"))
		_ok("材质默认值已把底材花斑放大（contrast %.2f / detail %.2f）" % [contrast, detail],
			contrast > 1.0 and detail > 1.0)
		# 数据覆盖层必须能真的写进去（返回条数 > 0）
		var probe := RtsTerrainAssets.make_terrain_material()
		var applied := RtsTerrainAssets.apply_look(probe, look.get("terrain", {}))
		_ok("look.terrain 的旋钮能写进材质（%d 条）" % applied, applied > 0)

	# --- ② 地形高度场：战术区严格平整、区外必须抬起来（土坎/丘陵） ---
	var terr: Dictionary = sh.get("terrain", {})
	var cell := float(terr.get("cell", 2.0))
	var sx := float((sh.get("size", {}) as Dictionary).get("x", 400.0))
	var sz := float((sh.get("size", {}) as Dictionary).get("z", 200.0))
	var cols := int(round(sx / cell)) + 1
	var rows := int(round(sz / cell)) + 1
	var heights: Array = terr.get("heights", [])
	# 紧贴战术区外的一圈土坎：实测高度（不是看源码里有没有写常量）。
	# 采样点取"区边 +6~10m"这段 —— 土坎前面留了 6m 草地缓冲（RIM_STEP_GAP），
	# 贴着边线量只会量到缓冲带的 0。
	var regions: Dictionary = sh.get("regions", {})
	var neutral: Array = regions.get("neutral", [])
	var z_lo := -20.0
	var z_hi := 20.0
	if neutral.size() >= 3:
		z_lo = float((neutral[0] as Array)[1])
		z_hi = float((neutral[2] as Array)[1])
	var rim := 0.0
	for zc in [z_lo - 9.0, z_hi + 9.0]:
		var ci := clampi(int(round((0.0 + sx * 0.5) / cell)), 0, cols - 1)
		var ri := clampi(int(round((zc + sz * 0.5) / cell)), 0, rows - 1)
		if ri * cols + ci < heights.size():
			rim = maxf(rim, float(heights[ri * cols + ci]))
	_ok("战术区外 9m 有一圈抬起来的土坎（实测 %.2f m）" % rim, rim >= 1.5)

	# --- ③ RtsTileSpec：建筑落位的三段真实计算 ---
	var planning_doc := JsonFile.read_dict(PLANNING_JSON, {})
	var spec := RtsTileSpec.spec_from(planning_doc)
	var tile7 := {"x": 0.0, "z": 0.0, "w": 7.0, "d": 7.0, "yaw": 0.0,
		"building_x": -3.5, "building_z": -3.5}
	var k := RtsTileSpec.fit_scale(Vector3(9.0, 4.0, 5.0), 7.0, 7.0, 0.41)
	_ok("fit_scale 把最长水平边压到 0.41 格（9m 模型 → %.2f m）" % (k * 9.0),
		absf(k * 9.0 - 0.41 * 7.0) < 0.001, "k=%.4f" % k)
	var c := RtsTileSpec.center(tile7, Vector2(-3.5, -3.5), spec)
	_ok("center 把底座中心推到格子左上（偏移 %.2f / %.2f 格）" % [c.x / 7.0, c.y / 7.0],
		absf(c.x / 7.0 - float(spec.get("anchor_u", -0.26))) < 0.01
		and absf(c.y / 7.0 - float(spec.get("anchor_v", -0.26))) < 0.01, str(c))
	_ok("玩家侧朝向 = 模型正面(-Z) 转到 +Z（180°）",
		absf(RtsTileSpec.yaw_deg(tile7, spec, "player") - 180.0) < 0.01)
	_ok("敌方格（底壳 yaw 180）不叠 180，正面仍朝镜头",
		absf(RtsTileSpec.yaw_deg({"yaw": 180.0}, spec, "enemy") - 180.0) < 0.01,
		"%.0f" % RtsTileSpec.yaw_deg({"yaw": 180.0}, spec, "enemy"))
	_ok("占地比例与左上偏移写在 planning.json 的 placement 里（数据驱动）",
		planning_doc.get("placement", {}).has("footprint_ratio")
		and planning_doc.get("placement", {}).has("anchor_u"))

	# --- ④ 出场兵种必须有模型（没模型的只许留在表里、不许进关卡/卡组）---
	var units_doc := JsonFile.read_dict(UNITS_JSON, {})
	var by_id := {}
	for u in units_doc.get("units", []):
		by_id[String((u as Dictionary).get("id", ""))] = u
	var enc_by_id := {}
	for e in JsonFile.read_dict(ENCOUNTERS_JSON, {}).get("encounters", []):
		enc_by_id[String((e as Dictionary).get("id", ""))] = e
	var lv_doc := JsonFile.read_dict(LEVELS_JSON, {})
	var naked: Array[String] = []
	var playable := 0
	for lv in lv_doc.get("levels", []):
		var asm: Dictionary = (lv as Dictionary).get("assembly", {})
		if asm.is_empty():
			continue
		playable += 1
		var enc: Dictionary = enc_by_id.get(String(asm.get("enemy_encounter", "")), {})
		for role in (enc.get("unit_roles", {}) as Dictionary).values():
			var uid := String(role)
			if not by_id.has(uid) or String((by_id[uid] as Dictionary).get("model_path", "")).is_empty():
				if not naked.has(uid):
					naked.append(uid)
	# 玩家侧：卡组里出现的训练牌，其兵种也必须有模型
	var card_by_id := {}
	for c2 in planning_doc.get("cards", []):
		card_by_id[String((c2 as Dictionary).get("id", ""))] = c2
	for cid in (planning_doc.get("deck", {}) as Dictionary).get("start", []):
		var unit := String((card_by_id.get(String(cid), {}) as Dictionary).get("unit", ""))
		if unit.is_empty():
			continue
		if not by_id.has(unit) or String((by_id[unit] as Dictionary).get("model_path", "")).is_empty():
			if not naked.has(unit):
				naked.append(unit)
	_ok("可玩关卡（%d 个）里会出场的兵种都有模型" % playable, naked.is_empty(),
		"没有模型却会上场：" + ", ".join(naked))

	# --- ⑤ 敌人只有一种外观（三档数值共用同一个 GLB）---
	var looks := {}
	for u in units_doc.get("units", []):
		var row: Dictionary = u
		if String(row.get("faction", "")) != "bandit":
			continue
		var mp := String(row.get("model_path", ""))
		if not mp.is_empty():
			looks[mp] = true
	_ok("敌人只有一种外观（%d 个 GLB）" % looks.size(), looks.size() == 1,
		", ".join(looks.keys()))

	# --- ⑥ 远景雾只吃远处（深度模式），近处不许发灰 ---
	var fog: Dictionary = look.get("fog", {})
	_ok("远景距离雾用深度模式且起点 ≥ 60 m（近处不吃雾）",
		String(fog.get("mode", "")) == "depth" and float(fog.get("begin", 0.0)) >= 60.0,
		"%s begin=%.0f" % [String(fog.get("mode", "")), float(fog.get("begin", 0.0))])


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _check_hud_rules() -> void:
	# --- ① 必须是**可编辑 .tscn**（不是代码里拼出来的） ---
	var packed := load(HUD_SCENE) as PackedScene
	_ok("HUD 是可编辑 .tscn 场景（制作人可直接在编辑器微调）", packed != null, HUD_SCENE)
	var card_packed := load(CARD_SCENE) as PackedScene
	_ok("卡牌是可编辑 .tscn 场景（卡面单独一件）", card_packed != null, CARD_SCENE)
	if packed == null:
		return
	var inst: Node = packed.instantiate()
	# --- ② 分区节点齐全（顶部左/中/右、底部左/右、手牌、出牌区、信息、结算） ---
	var lack: Array[String] = []
	for n in ["TopBar", "PlayerBlock", "PlayerName", "HpValue", "GoldValue", "ScrollSlots",
			"RoundLabel", "PhaseLabel", "TimerLabel", "MapButton", "IntentPanel", "IntentLabel",
			"BottomLeftPanel", "CpOrb", "CpValue", "CpCap", "BoostBadge", "PopValue",
			"DrawValue", "DrawIcon", "BottomRightPanel", "StartButton", "OutpostButton",
			"SpeedButton", "DiscardValue", "DiscardIcon", "HandArea", "HandRow", "PlayZone",
			"Toast", "ResultPanel", "UnitInfo"]:
		if inst.find_child(String(n), true, false) == null:
			lack.append(String(n))
	_ok("HUD 场景分区节点齐全（%d 个命名节点）" % 32, lack.is_empty(), "缺：" + ", ".join(lack))
	# --- ③ 只用容器 + 锚点：真实节点树里要有 Margin/HBox/VBox/PanelContainer，且没有裸像素根 ---
	var n_panel := _count_class(inst, "PanelContainer")
	var n_box := _count_class(inst, "HBoxContainer") + _count_class(inst, "VBoxContainer")
	var n_margin := _count_class(inst, "MarginContainer")
	_ok("HUD 用容器排版（Panel %d / Box %d / Margin %d）" % [n_panel, n_box, n_margin],
		n_panel >= 6 and n_box >= 8 and n_margin >= 3)
	var n_anchor := _count_anchored(inst)
	_ok("HUD 各分区都靠锚点定位（%d 个锚定 Control，换分辨率不跑位）" % n_anchor, n_anchor >= 10)
	# --- ④ 统一挂 main_theme.tres ---
	var theme: Theme = load(UI_THEME) as Theme
	var rootc := inst as Control
	_ok("HUD 根节点挂 main_theme.tres", rootc != null and rootc.theme == theme)
	inst.free()

	# --- ⑤ 卡牌场景：费用球 + 图 + 描述 + 派系条 ---
	var card_inst: Node = card_packed.instantiate() if card_packed != null else null
	var card_lack: Array[String] = []
	if card_inst == null:
		card_lack.append("卡牌场景加载失败")
	else:
		for n in ["Visual", "Title", "Art", "Desc", "RoleTag", "Units", "CostOrb", "Cost"]:
			if card_inst.find_child(String(n), true, false) == null:
				card_lack.append(String(n))
		var ctheme := (card_inst as Control).theme if card_inst is Control else null
		if ctheme != theme:
			card_lack.append("未挂 main_theme")
		card_inst.free()
	_ok("卡牌场景节点齐全且挂主题", card_lack.is_empty(), ", ".join(card_lack))

	# --- ⑥ 脚本只绑引用/写文本/播动画：不许硬拼布局 ---
	var src := _read(HUD_SCRIPT)
	_ok("HUD 脚本不硬拼静态布局（没有 Control.new / 手写 offset 像素）",
		not src.contains("Control.new") and not src.contains("offset_left =")
		and not src.contains("custom_minimum_size = Vector2"))
	_ok("HUD 卡牌三类前缀（建造/训练/策略）与点击契约一致",
		src.contains("BuildCard_") and src.contains("TrainCard_") and src.contains("StrategyCard_"))
	_ok("HUD 有开战 / 倍速 / 据点 / 重开四个按钮",
		src.contains("StartButton") and src.contains("SpeedButton")
		and src.contains("OutpostButton") and src.contains("RestartButton"))
	_ok("HUD 卡牌可用性只读 Model 的 available/reason（不自己推规则）",
		src.contains("\"available\"") and src.contains("\"reason\""))
	_ok("HUD 有抽牌/弃牌飞行 + 出牌区判定（Tween，不是瞬移）",
		src.contains("_fly_from_draw") and src.contains("_fly_to_discard") and src.contains("_is_over_play_zone"))
	_ok("HUD 打出失败会抖动回弹（不是点一下就生效）",
		src.contains("shake") and src.contains("_return_card"))
	_ok("HUD 零写死中文文案", _count_cjk_literals(src) == 0, "实测 %d 处" % _count_cjk_literals(src))
	var card_src := _read("res://Screens/hud/卡牌.gd")
	_ok("卡牌脚本零写死中文", _count_cjk_literals(card_src) == 0,
		"实测 %d 处" % _count_cjk_literals(card_src))


func _count_class(root: Node, cls: String) -> int:
	var n := 0
	for c in root.get_children():
		if c.is_class(cls):
			n += 1
		n += _count_class(c, cls)
	return n


func _count_anchored(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is Control:
			var ct := c as Control
			if absf(ct.anchor_left) + absf(ct.anchor_top) + absf(ct.anchor_right) + absf(ct.anchor_bottom) > 0.001:
				n += 1
		n += _count_anchored(c)
	return n


# ===========================================================================
# 7. 截图配方
# ===========================================================================
func _check_screens() -> void:
	var doc := JsonFile.read_dict(SCREENS, {})
	var recipes: Dictionary = doc.get("screens", {})
	var bad: Array[String] = []
	var clicks := 0
	for name in recipes.keys():
		var rec: Dictionary = recipes[name]
		var scene := String(rec.get("scene", ""))
		if scene.is_empty() or not ResourceLoader.exists(scene):
			bad.append("%s 场景缺失 %s" % [name, scene])
		if rec.has("click"):
			clicks += 1
			if not (rec.has("expect") or rec.has("expect_scene_state")):
				bad.append("%s 的 click 没配断言" % name)
		for job in rec.get("clicks", []):
			clicks += 1
			var j: Dictionary = job
			if String(j.get("click", "")).is_empty():
				bad.append("%s 的 clicks 缺 click" % name)
			elif not (j.has("expect") or j.has("expect_state")):
				bad.append("%s/%s 点了没断言" % [name, String(j.get("click", ""))])
	_ok("截图配方 %d 条、真实点击 %d 次、每次都有断言" % [recipes.size(), clicks],
		bad.is_empty() and recipes.size() >= 10, ", ".join(bad.slice(0, 6)))
	for need in ["battle_plan", "battle_build", "battle_train", "battle_attack",
			"battle_defend", "battle_info", "battle_models", "battle_airdrop", "battle_combat"]:
		_ok("验收配方存在：" + need, recipes.has(need))


# ===========================================================================
# 8. 文案 / 资产 / 清单 / 主题 / 文档
# ===========================================================================
func _check_i18n() -> void:
	var i18n := root.get_node_or_null("I18n")
	if i18n == null:
		_ok("I18n 自动加载就绪", false)
		return
	i18n.call("load_csv")
	var st: Dictionary = i18n.call("stats")
	_ok("ui.csv 可装载（%d 条 / %d 种语言）" % [int(st.get("keys", 0)), int(st.get("locales", 0))],
		int(st.get("keys", 0)) > 0 and String(st.get("error", "")).is_empty(), String(st.get("error", "")))
	for key in ["battle.phase.planning", "battle.phase.attack", "battle.phase.defend",
			"battle.start", "battle.intent.planning", "battle.outpost.button"]:
		_ok("战役文案已定义：" + key, bool(i18n.call("has", key)))

	var f := FileAccess.open("res://Content/i18n/ui.csv", FileAccess.READ)
	var rows_bad: Array[String] = []
	var dup: Array[String] = []
	var seen := {}
	if f != null:
		var header := f.get_csv_line()
		if header.size() < 3 or header[0] != "key" or header[1] != "zh" or header[2] != "en":
			rows_bad.append("表头必须是 key,zh,en")
		while not f.eof_reached():
			var row := f.get_csv_line()
			if row.size() == 1 and row[0].strip_edges().is_empty():
				continue
			if row.size() < 3:
				rows_bad.append(row[0] + " 列数不足")
				continue
			if row[1].strip_edges().is_empty() or row[2].strip_edges().is_empty():
				rows_bad.append(row[0] + " 的 zh/en 有空列")
			if seen.has(row[0]):
				dup.append(row[0])
			seen[row[0]] = true
		f.close()
	_ok("文案两列齐全（zh+en）、无重复 key", rows_bad.is_empty() and dup.is_empty(),
		"; ".join(rows_bad.slice(0, 4) + dup.slice(0, 4)))

	var missing: Array[String] = []
	var used := 0
	var re := RegEx.new()
	re.compile("I18n\\.t\\(\\s*\"([^\"]+)\"")
	for dir in ["res://Screens/world", "res://Screens/hud", "res://Screens/ui", "res://Engine"]:
		for f2 in _walk(dir):
			if not f2.ends_with(".gd"):
				continue
			for m in re.search_all(_read(f2)):
				var key: String = m.get_string(1)
				# 前缀 + 变量的动态 key（battle.reason.<code>）：只校验前缀本身有没有定义
				if key.ends_with("_") or key.ends_with("."):
					continue
				used += 1
				if not bool(i18n.call("has", key)):
					missing.append("%s → %s" % [f2.get_file(), key])
	_ok("代码引用的 I18n key 都有定义（%d 处）" % used, missing.is_empty(), ", ".join(missing.slice(0, 5)))

	# 写死中文预算：新文件必须是 0，旧文件不许超过冻结值
	var budget := JsonFile.read_dict("res://Content/i18n/legacy_budget.json", {})
	var by_dir: Dictionary = budget.get("by_dir", {})
	var over: Array[String] = []
	for dir_name in ["Game", "Screens", "addons"]:
		var base: Dictionary = by_dir.get(dir_name, {})
		for f4 in _walk("res://" + dir_name):
			if not f4.ends_with(".gd"):
				continue
			var rel: String = f4.replace("res://", "")
			var n := _count_cjk_literals(_read(f4))
			var base_n := int(base.get(rel, 0))
			if n > base_n:
				over.append("%s %d>%d" % [rel, n, base_n])
	_ok("写死文案不增长（新代码 0 处，旧代码不超预算）", over.is_empty(), "; ".join(over.slice(0, 5)))


func _check_assets() -> void:
	var keys := root.get_node_or_null("Keys")
	if keys == null:
		_ok("Keys 自动加载就绪", false)
		return
	var data := JsonFile.read_dict("res://Content/keys/assets.json", {})
	if data.is_empty():
		_ok("资源 key 表可读", false)
		return
	var bad: Array[String] = []
	for kind in data.keys():
		if kind in ["version", "note"] or not (data[kind] is Dictionary):
			continue
		for key in (data[kind] as Dictionary).keys():
			var p: String = String(data[kind][key])
			if not FileAccess.file_exists(p):
				bad.append("%s/%s → %s" % [kind, key, p])
	_ok("登记的 key 都指向真实文件", bad.is_empty(), "; ".join(bad.slice(0, 5)))

	var mapped := {}
	for kind in ["audio", "models", "icons", "shaders", "fx"]:
		for key in (data.get(kind, {}) as Dictionary).keys():
			mapped[String(data[kind][key])] = true
	var uncovered: Array[String] = []
	var scans := [
		["res://Content/audio", [".ogg", ".wav", ".mp3"]],
		["res://Content/art/模型", [".glb", ".gltf"]],
		["res://Content/art/图标", [".svg", ".png", ".jpg", ".webp"]],
		["res://Content/art/着色器", [".gdshader", ".shader"]],
		["res://Content/art/特效", [".tscn"]],
	]
	for pair in scans:
		for f in _walk(pair[0]):
			if f.get_extension() in pair[1] and not mapped.has(String(f)):
				uncovered.append(String(f).replace("res://", ""))
	_ok("内容资产全部已登记（%d 个 key）" % mapped.size(), uncovered.is_empty(),
		"未登记：" + ", ".join(uncovered.slice(0, 6)))


func _check_asset_manifest() -> void:
	var text := _read("res://Content/docs/asset_manifest.md")
	var re := RegEx.new()
	re.compile("(res://[^\\s`\\)\\]]+)")
	var bad: Array[String] = []
	var n := 0
	for m in re.search_all(text):
		var cand: String = m.get_string(1).trim_suffix("`")
		# 文档里的示意路径（…）与目录（以 / 结尾）不算断链
		if cand.contains("...") or cand.ends_with("/"):
			continue
		n += 1
		if not FileAccess.file_exists(cand):
			bad.append(cand)
	_ok("资产清单里的路径都真实存在（%d 条）" % n, bad.is_empty(), ", ".join(bad.slice(0, 5)))


func _check_manifest() -> void:
	var doc := JsonFile.read_dict("res://Content/manifest.json", {})
	var listed := {}
	for row in doc.get("files", []):
		listed[String((row as Dictionary).get("path", ""))] = true
	var on_disk := {}
	for d in ["Game", "Screens", "Model", "Engine", "Tests", "Tools", "Content/data",
			"Content/i18n", "Content/keys", "addons"]:
		for f in _walk("res://" + d):
			var ext: String = String(f.get_extension())
			if ext == "import" or ext == "tmp" or ext == "log":
				continue
			on_disk[String(f).replace("res://", "")] = true
	var lack: Array[String] = []
	for p in on_disk.keys():
		if not listed.has(p):
			lack.append(String(p))
	var ghosts: Array[String] = []
	for p in listed.keys():
		if not on_disk.has(p):
			ghosts.append(String(p))
	_ok("源文件清单与磁盘一致（%d 个，缺 %d / 多 %d）" % [listed.size(), lack.size(), ghosts.size()],
		lack.is_empty() and ghosts.is_empty(),
		("缺：" + ", ".join(lack.slice(0, 4)) + " 多：" + ", ".join(ghosts.slice(0, 4))).strip_edges())


func _check_engine_pin() -> void:
	var pin := JsonFile.read_dict("res://Engine/pin.json", {})
	_ok("Engine/pin.json 是哈希清单（version + files）",
		not pin.is_empty() and pin.has("version") and pin.has("files"),
		str(pin.keys()))
	var local := _read("res://Engine/VERSION").strip_edges()
	_ok("Engine/VERSION 与 pin.version 一致（%s）" % local,
		local == String(pin.get("version", "")), "pin=%s" % String(pin.get("version", "")))
	var files: Dictionary = pin.get("files", {})
	var stale: Array[String] = []
	for rel in files.keys():
		var full := "res://Engine/" + String(rel)
		var h: String = _sha256(full)
		var want := String((files[rel] as Dictionary).get("sha256", ""))
		if h.is_empty() or h != want:
			stale.append(String(rel))
	_ok("Engine 文件哈希与 pin 一致（改 Engine 必须重跑 gen_engine_pin.py，%d 个文件）" % files.size(),
		stale.is_empty(), ", ".join(stale.slice(0, 5)))


func _check_ui_theme() -> void:
	var theme: Theme = load(UI_THEME) as Theme
	_ok("UI 主题 main_theme.tres 可加载", theme != null, UI_THEME)
	if theme == null:
		return
	var want_base := {
		"HudPanel": "PanelContainer", "FloatPanel": "PanelContainer",
		"CardPanel": "PanelContainer", "InsetPanel": "PanelContainer",
		"AttackButton": "Button", "DefenseButton": "Button",
		"PrimaryButton": "Button", "GhostButton": "Button",
		"CountdownBar": "ProgressBar",
		"TitleLabel": "Label", "HeaderLabel": "Label", "ValueLabel": "Label",
		"CaptionLabel": "Label", "AttackLabel": "Label", "DefenseLabel": "Label",
	}
	var bad_base: Array[String] = []
	for t in want_base.keys():
		var got := String(theme.get_type_variation_base(String(t)))
		if got != String(want_base[t]):
			bad_base.append("%s→%s" % [t, got])
	_ok("主题变体挂在正确基类上（%d 个）" % want_base.size(), bad_base.is_empty(), ", ".join(bad_base))

	var bad_state: Array[String] = []
	for t in ["Button", "AttackButton", "DefenseButton"]:
		for s in ["normal", "hover", "pressed", "disabled"]:
			if not theme.has_stylebox(String(s), String(t)):
				bad_state.append("%s/%s" % [t, s])
	_ok("Button（含进攻/防守变体）四态样式齐全", bad_state.is_empty(), ", ".join(bad_state))

	var fs_body := theme.default_font_size
	var fs_title := theme.get_font_size("font_size", "TitleLabel")
	var fs_cap := theme.get_font_size("font_size", "CaptionLabel")
	_ok("三档字号唯一（正文 %d / 标题 %d / 角标 %d）" % [fs_body, fs_title, fs_cap],
		fs_body == 18 and fs_title == 28 and fs_cap == 14)

	var packed := load(UI_SHOWCASE) as PackedScene
	var inst: Node = packed.instantiate() if packed != null else null
	var lack: Array[String] = []
	if inst == null:
		lack.append("场景加载失败")
	else:
		for n in ["Backdrop", "HudCard", "FloatCard", "KitCard", "DockCard", "RatioCard",
				"FocusButton", "DefendButton", "ToggleButton", "HealthBar", "CountdownBar"]:
			if inst.find_child(String(n), true, false) == null:
				lack.append(String(n))
		var rootc := inst as Control
		if rootc == null or rootc.theme != theme:
			lack.append("根节点未挂 main_theme.tres")
	_ok("陈列室 ThemeShowcase.tscn 节点齐全 + 根节点挂主题", lack.is_empty(), ", ".join(lack))
	if inst != null:
		inst.free()

	var guide := _read(UI_STYLE_GUIDE)
	var lack_hex: Array[String] = []
	for h in ["#E9DFCB", "#38291C", "#A93B2E", "#2E5C93", "#C08A2E"]:
		if not guide.contains(String(h)):
			lack_hex.append(String(h))
	_ok("风格指南记录了色板 Hex 与 60 / 30 / 10 比例",
		lack_hex.is_empty() and guide.contains("60%")
		and guide.contains("30%") and guide.contains("10%"), ", ".join(lack_hex))


func _check_docs() -> void:
	_ok("待办池 Content/docs/backlog.md 存在", FileAccess.file_exists(BACKLOG))
	var bl := _read(BACKLOG)
	_ok("待办池分三栏（已完成 / 下轮优先 / 远期）",
		bl.contains("当前已完成") and bl.contains("下轮优先") and bl.contains("远期"))
	_ok("AGENTS.md 不超过 20KB", FileAccess.get_file_as_bytes("res://AGENTS.md").size() <= 20480,
		"%d 字节" % FileAccess.get_file_as_bytes("res://AGENTS.md").size())


# ===========================================================================
# 9. 旧系统已物理删除（反向断言）
# ===========================================================================
func _check_legacy_removed() -> void:
	var left: Array[String] = []
	for p in PURGED_PATHS:
		var full: String = "res://" + p
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(full)):
			left.append(p + "/")
		elif FileAccess.file_exists(full):
			left.append(p)
	_ok("旧单兵 / 旧寻路 / 旧测试图已物理删除（%d 条路径核对）" % PURGED_PATHS.size(),
		left.is_empty(), "残留：" + ", ".join(left))

	var run_game := _read("res://Tools/run-game.ps1")
	_ok("run-game 不再有 --lane 旧横道入口", not run_game.contains("--lane"))
	_ok("run-game 的 switch 开了 -Wildcard（带 = 的参数才传得到游戏侧）",
		run_game.contains("switch -Wildcard"))
	_ok("run-game 支持 --phase-seconds（截图/自检压缩单场时长）",
		run_game.contains("--phase-seconds="))

	var banned := ["SelectionSystem", "CommandSystem", "RtsLevel", "RtsStandGrid",
		"LaneBattle", "Skirmish", "LaneSquad", "LevelSimulator", "Res://Game/units"]
	var hits: Array[String] = []
	for d in ["Screens", "Game", "Model"]:
		for f in _walk("res://" + d):
			var ext2: String = String(f.get_extension())
			if ext2 != "gd" and ext2 != "cs":
				continue
			for line in _read(f).split("\n"):
				var t2 := line.strip_edges()
				if t2.begins_with("#") or t2.begins_with("//") or t2.begins_with("*"):
					continue
				for b in banned:
					if t2.contains(b):
						hits.append("%s:%s" % [f.replace("res://", ""), b])
	_ok("全仓不再有旧单兵/旧寻路的符号（%d 个关键词）" % banned.size(), hits.is_empty(),
		"; ".join(hits.slice(0, 6)))

	var bridge := _read("res://Screens/bridge/ModelBridge.cs")
	for gone in ["LevelSimulate", "DamageCompute", "AvailResult", "Skirmish"]:
		_ok("桥接层旧接口已删除：" + gone, not bridge.contains(gone))


# ===========================================================================
# 工具
# ===========================================================================
func _json_level() -> Dictionary:
	var doc := JsonFile.read_dict(LEVELS_JSON, {})
	for row in doc.get("levels", []):
		var lv: Dictionary = row
		if not (lv.get("assembly", {}) as Dictionary).is_empty():
			return lv
	return {}


func _json_shell() -> Dictionary:
	var lv := _json_level()
	var asm: Dictionary = lv.get("assembly", {})
	return _find_row(JsonFile.read_dict(SHELLS_JSON, {}), "shells", String(asm.get("shell", "")))


func _json_layout() -> Dictionary:
	var lv := _json_level()
	var asm: Dictionary = lv.get("assembly", {})
	return _find_row(JsonFile.read_dict(LAYOUTS_JSON, {}), "layouts", String(asm.get("player_layout", "")))


func _json_encounter() -> Dictionary:
	var lv := _json_level()
	var asm: Dictionary = lv.get("assembly", {})
	return _find_row(JsonFile.read_dict(ENCOUNTERS_JSON, {}), "encounters",
		String(asm.get("enemy_encounter", "")))


func _find_row(doc: Dictionary, key: String, id: String) -> Dictionary:
	for row in doc.get(key, []):
		var d: Dictionary = row
		if String(d.get("id", "")) == id:
			return d
	return {}


func _new_session(mdl: RefCounted) -> int:
	var res: Dictionary = mdl.call("SquadSessionNew",
		JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}), _json_level(), _json_shell(),
		_json_layout(), _json_encounter(), JsonFile.read_dict(SQUAD_JSON, {}), 20261122, true)
	if not bool(res.get("ok", false)):
		print("  · 建会话失败：" + _err_text(res.get("errors", [])))
		return 0
	var h := int(res.get("handle", 0))
	mdl.call("SquadSessionBeginPlanning", h)
	return h


func _arena_dict(mdl: RefCounted, h: int) -> Dictionary:
	return mdl.call("SquadArenaInfo", h)


func _first_train_card(state: Dictionary) -> String:
	for c in state.get("train_cards", []):
		var card: Dictionary = c
		if bool(card.get("in_hand", false)) and bool(card.get("available", false)):
			return String(card.get("card_id", ""))
	return ""


func _content() -> Dictionary:
	if not _content_cache.is_empty():
		return _content_cache
	var mdl := _mdl()
	if mdl == null:
		return {}
	_content_cache = mdl.call("DataValidate",
		JsonFile.read_dict(UNITS_JSON, {}),
		JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}),
		JsonFile.read_dict(LEVELS_JSON, {}))
	return _content_cache


func _mdl() -> RefCounted:
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		return null
	return bridge_sc.call("get_bridge") as RefCounted


func _err_text(v: Variant) -> String:
	var parts: Array[String] = []
	if v is Array:
		var arr: Array = v
		for i in mini(arr.size(), 5):
			parts.append(String(arr[i]))
	return " ; ".join(parts)


func _arr(v: Variant) -> Array:
	return v if v is Array else []


func _walk(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with(".") or name in ["bin", "obj", "__pycache__"]:
			name = dir.get_next()
			continue
		var child := dir_path + "/" + name
		if dir.current_is_dir():
			out.append_array(_walk(child))
		else:
			out.append(child)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


## 数一段代码里有几个"含中文的字符串字面量"（注释里的不算）
func _count_cjk_literals(text: String) -> int:
	var count := 0
	var i := 0
	var n := text.length()
	var in_str := false
	var in_comment := false
	var has_cjk := false
	var escaped := false
	while i < n:
		var ch := text[i]
		if in_comment:
			if ch == "\n":
				in_comment = false
			i += 1
			continue
		if in_str:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_str = false
				if has_cjk:
					count += 1
					has_cjk = false
			else:
				var cp := text.unicode_at(i)
				if cp >= 0x4E00 and cp <= 0x9FFF:
					has_cjk = true
			i += 1
			continue
		if ch == "\"":
			in_str = true
			has_cjk = false
			i += 1
			continue
		if ch == "#":
			in_comment = true
			i += 1
			continue
		i += 1
	return count


func _ok(name: String, cond: bool, detail: String = "") -> void:
	# 标记用 ASCII：控制台/日志重定向到 GBK 时 ✓ ✗ 会被吞成 '?'，断言就看不见了。
	if cond:
		_pass += 1
		print("  OK   " + name + (("  " + detail) if not detail.is_empty() else ""))
	else:
		_fail += 1
		_names.append(name)
		print("  FAIL " + name + (("  " + detail) if not detail.is_empty() else ""))


func _finish() -> void:
	print("---------------------------------------------------------------")
	if _fail == 0:
		print("CHECK PASS %d / FAIL 0" % _pass)
		quit(0)
	else:
		print("CHECK PASS %d / FAIL %d —— %s" % [_pass, _fail, ", ".join(_names)])
		quit(1)
