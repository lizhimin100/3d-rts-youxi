extends Resource
## **野怪营地定义**（一张 .tres 一份配置）。
##
## 为什么做成 Resource 而不是常量表：
##   营地是"地图内容"，不是平衡数值 —— 同一套刷怪规则，不同地图想摆不同组合。
##   放进 `代码/配置/卡/野怪营地/*.tres` 之后，加一座营地只需要加一个文件，
##   不用改任何代码（和建筑卡同一个思路）。
##
## ⚠ 故意**不写 class_name**：
##   本工程吃过"全局类名缓存没刷新 → 别的脚本 Could not find type → 主场景白屏"的亏
##   （见 AGENTS.md §二）。这个类型只在 `野怪营地表.gd` / `野怪营地.gd` 里用，
##   一律 `load()` + 动态取字段就够了，不需要全局类名。
##
## 与建筑的关系：
##   `den_building` 是**锚点建筑**的 id（见 代码/配置/卡/建筑/creep_den.tres 等）。
##   营地不自己长房子：房子由玩家在地图编辑器里摆（owner = -1 → 中立阵营），
##   系统扫到"中立阵营里 id 命中的建筑"才把它当成一座营地。
##   这样"营地摆在哪"完全由地图作者决定，代码不猜。

## 营地 id（唯一，用于日志/调试；当前不参与判据）
@export var id: StringName = &"camp_gnoll"
## 显示名（小地图 tooltip / 报告用）
@export var display_name: String = "豺狼人营地"
## 锚点建筑 id（必须能在 单位表 里查到，否则这座营地不会被识别）
@export var den_building: StringName = &"creep_den"
## 刷哪些野怪（和 counts 一一对应）
@export var creeps: Array[StringName] = [&"gnoll_warrior", &"gnoll_scout"]
## 各刷几只
@export var counts: Array[int] = [2, 1]
## 刷怪半径（米，从锚点建筑中心算）
@export var radius: float = 6.0
## 全灭后多久补满（秒；<= 0 表示永不补）
@export var respawn: float = 90.0
## 小地图图标 key（对应 美术/图标/小地图/<key>.png；缺图时画降级标记）
@export var minimap_icon: String = "camp"

# ---------------------------------------------------------------------------
# 2026-11-07 新增：时间点 + 归属（玩家反馈"由我自定义这是哪个玩家的、几分钟刷"）
# ---------------------------------------------------------------------------
## 归属槽位：-2 = 中立敌对（默认，野怪） / -1 = 中立（和平，不主动打人但会被打）
##            0..11 = 归某个玩家（替该玩家守营地，AI 会把它当自己人）。
## ★ 真正生效的归属是**锚点建筑的 owner**（编辑器「摆放归属」）：
##   这里只是"新摆一座锚点时建议的归属"，进图后以锚点为准。
@export var owner_slot: int = -2
## 第几分钟第一次刷（分钟；0 = 开局立刻刷）
@export var first_spawn_min: float = 0.0
## 之后每隔几分钟再刷一整波（分钟；0 = 只刷一次，之后只靠 respawn 补满）
@export var spawn_interval_min: float = 0.0
