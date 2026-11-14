# Game/配置

> 状态：现行

- **职责**：所有数值的唯一来源：单位卡 / 建筑卡 / 技能卡 / 研究 / 难度 / AI 系数。
- **不属于这里**：任何行为逻辑（配置只描述"是什么"）。
- **唯一入口**：autoload `Cfg`（`Cfg.unit(id)` / `Cfg.game` / `Cfg.difficulty(i)`）。
- **禁改**：卡片的**字段名**（JSON 字段 = 契约，拼错会被 `--check` 抓）；改完必须跑 `配置回归`。

## 文件分工

| 文件 | 干什么 |
|---|---|
| `配置入口.gd` | autoload `Cfg`：读 `Content/data/game.json` + 卡校验 |
| `card_store.gd` | 卡读写唯一出口：JSON ↔ Resource（编辑器也是它） |
| `可用性查询.gd` / `可用性文案.gd` | 训练/研究/建造判据的适配层 + reason→文案 |
| `Content/data/cards/{units,buildings,skills,camps}/*.json` | 单位/建筑/技能/营地卡（唯一真源） |
| `Content/data/ai_demand.json` | 部门线诉求分（25 个系数/刻度） |
| `单位定义.gd` / `建筑卡.gd` | 卡的数据结构（字段 = 契约） |
| `AI判定模式.gd` | `dept_on()` / `goal_on()` 等开关（`--dept=on/off`） |
| `射程基准.gd` | `R1 = 0.015 米/单位` |
| `体积派生.gd` | 体积 → 半径 / 碰撞 / 判定圈（`MODE` 常量切换） |

## 自检

```text
godot --headless --path . --script Tests/suites/配置回归.gd   # 282/0（dept=on 已转正）
```

## 已知坑

1. 新增 `class_name` 后必须 `--import`，否则别的脚本报 "Could not find type"。
2. 改数值只改 `Content/data/*.json`；改完跑 `./Tools/run-game.ps1 --check`。
3. 可用性判断只在 `Model/core/可用性.gd`；UI/指令/建筑都走 `可用性查询.gd`，不要再写第二套。
