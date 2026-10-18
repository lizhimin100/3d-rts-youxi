@tool
class_name DifficultyDef
extends Resource
## 单个 AI 难度档的参数。由 游戏配置 里的 difficulties 数组持有。
## 设计意图：AI 的"强弱"只通过**经济倍率 / 出兵节奏 / 军队上限 / 兵种配比**调节，
## 不改单位基础数值（否则玩家看到的兵和 AI 的兵不一样，会很怪）。

@export var id: StringName = &"easy"
@export var display_name: String = "简单"

@export_group("节奏")
## AI 决策间隔（秒），越小反应越快
@export var think_interval: float = 1.2
## 第一波进攻延迟（秒）
@export var first_wave_delay: float = 90.0
## 基础波次间隔（秒）
@export var wave_interval: float = 45.0
## 每波间隔缩短量（秒）
@export var wave_interval_decay: float = 2.0
## 最小波次间隔
@export var wave_interval_min: float = 22.0

@export_group("规模")
## 军队数量上限（触发进攻的阈值）
@export var max_army: int = 12
## AI 农民目标数量
@export var target_peasants: int = 6
## 每波最少出兵数
@export var min_wave_size: int = 4

@export_group("经济")
## 采集效率倍率（AI 的资源产出）
@export var gather_multiplier: float = 1.0
## 训练耗时倍率（<1 更快）
@export var train_time_multiplier: float = 1.0
## 初始额外资源
@export var bonus_gold: int = 0

@export_group("行为")
## 主动进攻概率（0~1），其余时间防守/发育
@export var aggression: float = 0.5
## 基地被攻击时回防比例
@export var defend_ratio: float = 0.6
## 兵种配比权重（id → 权重）
@export var composition: Dictionary = {}
