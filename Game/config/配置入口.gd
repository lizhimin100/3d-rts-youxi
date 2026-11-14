extends Node
## **配置总线（自动加载单例 `Cfg`）**
## 职责：
##   1. 组装唯一一份 GameConfig：
##        - 全局数值来自 `Content/data/game.json`（JSON 是唯一真源）；
##        - 单位/建筑/技能卡来自 `Content/data/cards/*.json`（由 UnitTable 装载）；
##        - 代码里**没有可调数值默认值**（game.json 缺失只作为最后兜底并报错）。
##   2. 提供只读访问：Cfg.game / Cfg.unit(id) / Cfg.difficulty(idx)
##   3. 注册输入映射（不让 project.godot 里塞一堆序列化事件，改起来更直观）
##
## ★ 2026-11-14：旧的 `res://配置/游戏配置.tres` 覆盖机制已退役。
##   改数值 → 改 Content/data/game.json → 重跑游戏（--check 会校验字段）。
##   调试面板改数值也必须写回这个 JSON（Engine/debug/debug_tuner.gd 只允许写 Content/data/）。

const GAME_JSON := "res://Content/data/game.json"
const JsonFile := preload("res://Engine/util/json_file.gd")
const JsonCodec := preload("res://Engine/util/json_codec.gd")

## 全局配置（所有人只读）
var game: GameConfig = null


func _init() -> void:
	_rebuild()
	InputSetup.register_all()


## 组装配置
func _rebuild() -> void:
	var cfg: GameConfig = null
	if FileAccess.file_exists(GAME_JSON):
		cfg = JsonCodec.restore("res://Game/config/游戏配置.gd", JsonFile.read_dict(GAME_JSON, {})) as GameConfig
	if cfg == null:
		push_error("[Cfg] 读不出 %s，退回 schema 默认值（正常构建不该发生）" % GAME_JSON)
		cfg = GameConfig.new()
	cfg.units = UnitTable.build_units()
	cfg.researches = UnitTable.build_researches()
	_apply_resource_amounts(cfg)
	cfg.ensure_default_difficulties()
	game = cfg


## 把 GameConfig 里的"地图资源储量"写进可采集物的 def。
##
## 为什么要在 _rebuild 末尾补这一刀：`UnitTable.build_units()` 是纯静态函数，
## 跑的时候 `Cfg.game` 还没赋值，没法自己读配置。而储量是**玩家最常调的数值**
## （一座矿能挖多久直接决定会不会"5 分钟卡金币"），必须只改一处。
func _apply_resource_amounts(cfg: GameConfig) -> void:
	if cfg == null or cfg.units == null:
		return
	var mine := cfg.units.get(&"goldmine", null) as UnitDef
	if mine != null:
		mine.resource_amount = maxi(cfg.gold_mine_amount, 1)
	# ★ 树**不能**用 `tree_amount` 覆盖：树的 resource_amount 是"还能采几次"（20），
	#   而配置里那个 tree_amount=260 是给别的口径留下的死字段。写进去会让一棵树砍 260 趟。


## 取单位定义
func unit(id: StringName) -> UnitDef:
	return game.unit_def(id)


## 全部单位定义
func units() -> Dictionary:
	return game.units


## 取研究定义（铁匠铺升级）
func research(id: StringName) -> ResearchDef:
	return game.research_def(id)


## 取难度档（越界会夹紧到最后一档）
func difficulty(idx: int = -1) -> DifficultyDef:
	if idx < 0:
		idx = game.default_difficulty
	if game.difficulties.is_empty():
		game.difficulties = UnitTable.build_difficulties()
	idx = clampi(idx, 0, game.difficulties.size() - 1)
	return game.difficulties[idx]


## 把当前配置保存回 JSON（工具/调试用；正常改数值直接改 JSON，不必经过这里）
func save_game_json(path: String = GAME_JSON) -> Error:
	if game == null:
		return ERR_UNCONFIGURED
	var data := JsonCodec.encode_resource(game)
	return JsonFile.write_atomic(path, data)


## 兼容旧调用名（Tools/导出配置.gd）
func save_override(path: String = GAME_JSON) -> Error:
	return save_game_json(path)
