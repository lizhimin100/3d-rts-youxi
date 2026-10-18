extends Node
## **配置总线（自动加载单例 `Cfg`）**
## 职责：
##   1. 组装唯一一份 GameConfig（
##        - 若存在 res://配置/游戏配置.tres 就用它（编辑器里可以直接改数值）
##        - 否则用代码默认值（单位表.gd）
##      ）
##   2. 提供只读访问：Cfg.game / Cfg.unit(id) / Cfg.difficulty(idx)
##   3. 注册输入映射（不让 project.godot 里塞一堆序列化事件，改起来更直观）
##
## 注意：这里**不写任何数值**，数值一律来自 GameConfig / UnitTable。

## 可选的配置覆盖文件（存在即优先）
const OVERRIDE_PATH := "res://配置/游戏配置.tres"

## 全局配置（所有人只读）
var game: GameConfig = null


func _init() -> void:
	_rebuild()
	InputSetup.register_all()


## 组装配置
func _rebuild() -> void:
	var cfg: GameConfig = null
	if ResourceLoader.exists(OVERRIDE_PATH):
		cfg = load(OVERRIDE_PATH) as GameConfig
		if cfg == null:
			push_warning("[Cfg] %s 不是合法的 GameConfig，回退到代码默认值" % OVERRIDE_PATH)
	if cfg == null:
		cfg = GameConfig.new()
	# 单位表永远以代码为准（避免旧 .tres 里残留的 def 覆盖新数值）
	cfg.units = UnitTable.build_units()
	cfg.researches = UnitTable.build_researches()
	# 难度：.tres 里配了就用，没配就代码默认
	cfg.ensure_default_difficulties()
	game = cfg


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


## 把当前配置保存成 .tres（编辑器里想手改数值时用；只在工具脚本里调用）
func save_override(path: String = OVERRIDE_PATH) -> Error:
	if game == null:
		return ERR_UNCONFIGURED
	return ResourceSaver.save(game, path)
