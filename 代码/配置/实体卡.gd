class_name EntityCard
extends Resource
## **实体卡基类**（2C-4 · C1）—— 数值的**唯一真相源**。
##
## 铁律（任务书 §2.1）：卡是数值唯一真相源；**卡不存任何实例状态**
## （玩家、序号、当前生命、坐标、冷却、任务、控制权一律不进卡）。
## 破坏这条的方案一律不采纳。
##
## 实例 ID 在运行时拼：`{card_id}-P{玩家号}-{该玩家该兵种序号}`（P1 起），
## 卡只提供 `card_id` 段 —— 序号计数、玩家归属都是运行时的事。

## 唯一 id，如 `footman` / `LMBB001`，不含玩家/序号
@export var card_id: String = ""
## 显示名
@export var display_name: String = "单位"
## 图标路径。**2C-4 留空字符串**，路径后续再整理（任务书 §2.2）
@export var icon: String = ""
## 简介
@export var description: String = ""
## **阵营（种族）**：联盟 / 失落 / 中立。
## 只用于**分类展示**（地图编辑器按它分组、卡面板按它排版），
## **不影响玩法**：一局里谁能造谁，是运行时 RtsFaction 决定的，不是这张卡决定的。
@export var race: StringName = &"联盟"
## 金币成本
@export var cost_gold: int = 0
## 木材成本
@export var cost_wood: int = 0
