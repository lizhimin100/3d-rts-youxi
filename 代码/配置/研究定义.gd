@tool
class_name ResearchDef
extends Resource
## **铁匠铺研究项**的静态定义（阵营级升级）。
##
## 研究 id 与效果由 RtsCombat 实现（attack_up / armor_up），
## 花费、耗时、上限这些**可调数值**放在这里，由 单位表.gd 填充，
## 玩法脚本一律走 Cfg.research(id) 读取，不许硬编码。

@export_group("身份")
## 研究 id（与 RtsCombat.RESEARCH_* 一致）
@export var id: StringName = &""
## 中文显示名（"武器锻造"）
@export var display_name: String = "研究"
## 一句话说明（按钮 tooltip 用）
@export var description: String = ""

@export_group("花费与耗时")
## 单次研究的金币 / 木材花费
@export var gold_cost: int = 100
@export var wood_cost: int = 50
## 研究耗时（秒）
@export var research_time: float = 25.0
## 最高等级（满级后按钮禁用）
@export var max_level: int = 3
