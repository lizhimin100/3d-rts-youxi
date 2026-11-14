# Game/ai

> 状态：现行（2026-11-13）

- **职责**：决策（战略导演）→ 目标（诉求分）→ 执行（命令调度）→ 反馈（波次账本）。
- **不属于这里**：战斗结算（`系统/战斗.gd`）、单位状态机（`单位/单位.gd`）、界面文案（`界面/词条.gd`）。
- **唯一入口**：`SimpleAI._think_once()`；所有下令必须经 `CommandScheduler.flush()`。
- **对外白名单**：`SimpleAI.set_process` / `Adjutant.set_enabled` / `Adjutant.assembly_points()` / `战区指令.issue()`。
- **禁改**：
  * 不要在 `_dept_tick` 之外偷偷加"每帧跑一次"的决策 —— 默认 `dept=on`，`_manage_mil` 整段是死代码。
  * 不要绕过 `Game.control.filter()` 对玩家单位下令。
  * 不要在 AI 里读 UI 节点。

## 文件分工

| 文件 | 干什么 | 改动风险 |
|---|---|---|
| `简单AI.gd`（7.6k 行） | 编排 + 经济/军事/科技 + 战区指令执行 | **高**：先看 `_think_once` 的 8 段结构 |
| `战斗模型.gd` | 兵种克制、战力估值 | 中：数值口径只有这一处 |
| `战略导演.gd` | 选战略计划（8s 滞回） | 低 |
| `目标层.gd` | 三条部门线报"目标 + 诉求分" | 中：字段名是契约（`GOAL_FIELDS` 9 个） |
| `命令调度.gd` | 去重 / 节流 / 卡死退避 / 限流 64 | 中 |
| `控制权.gd` | 玩家命令组生命周期（5s 宽限 / STOP 30s / HOLD 永久） | **高**：动它等于动"AI 抢不抢玩家的兵" |
| `副官.gd` | 玩家阵营的 AI：多集结点、空闲派活、玩家意图解析 | 中 |
| `集结规划.gd` | 16 方向 × 4 环选集结点（连片空地 ≥75%） | 低 |
| `驻守调度.gd` | 据点 / 外围来路 / 前线塔的驻守点选择 | 低 |
| `战区指令.gd` | 玩家四类战役级意图（存在 `Game` meta 上） | 低 |

## 自检

```text
godot --headless --fixed-fps 60 --path . -- --adjutant-test   # 32 项，1 项常红（E 组）
godot --headless --fixed-fps 60 --path . -- --war-test        # 10 项，应全绿
godot --headless --path . --quit-after 6000 -- --ai-bench --seed=1 --minutes=10
```

## 已知坑

1. **默认 `dept=on`**：`_manage_waves` / `_manage_mil` 是死代码。新增决策要么进 `_dept_tick`，要么放 `_think_once` 顶层。
2. `战区指令` 曾用 `static var` 存，**跨脚本不共享**（自检写入、AI 读不到），现改为 `Game` meta。
3. 副官每 4 秒把闲兵往集结点拉 → 士兵常年 `order == MOVE` 不是 `NONE`。判断"能不能调"要按命令意图分，不能只看 `is_idle_like()`。
