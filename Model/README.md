# Model/ —— 纯逻辑层（规则、经济、成长、存档数据）

## 铁律

1. **零引擎 API**：不许出现 `Node` / `SceneTree` / `ResourceLoader` / `FileAccess` / `Input` / `OS` / `Engine` / `Time` / `push_error` / `print`。
   `--check` 会逐文件扫描这些词，出现即失败。
2. **零内容路径**：除了 `preload("res://Model/…")` 引用同层规则，不许出现任何 `res://`。
   （数据由调用方读 JSON 后以 Dictionary 传进来，Model 不知道文件长什么样。）
3. **确定性**：随机数只走 `Model/core/rng.gd`（xorshift），同种子同输入必然同结果。
4. **可命令行跑**：`run-game --simulate` 只用这一层推演；不加载场景、不渲染。
5. **改规则先改这里**：游戏侧（`Game/`）只做"把数据喂进来 + 把结果画出来"。

## 目录

| 目录 | 内容 |
|---|---|
| `core/damage.gd` | 伤害公式（护甲减免 / 克制表 / 暴击 / 升级乘数）—— 全游戏唯一实现 |
| `core/economy.gd` | 资源账本（能不能付 / 扣费 / 人口 / 采集速率） |
| `core/production.gd` | 生产队列（按 tick 推进） |
| `core/progression.gd` | 升级 / 主城等级门槛 |
| `core/rng.gd` | 确定性随机数 |
| `core/可用性.gd` | 训练/研究/建造的可用性判断（reason code + params），全游戏唯一实现 |
| `battle/skirmish.gd` | 确定性小规模推演（`--simulate` 的引擎） |
| `save/save_schema.gd` | 存档数据结构、校验、版本迁移 |
| `ai/目标层.gd` | 目标建议（9 字段）→ 主/次目标选择 → 空过；`demand_to_proposal` 是"执行诉求 → 目标建议"的唯一投影（2026-11-14 从 `Game/ai` 下沉） |

## 与游戏侧的关系

`Game/systems/战斗.gd` 的伤害计算、`Game/core/阵营.gd` 的付款判断都**委托**给这里；
`--check` 有一条"游戏侧 == Model"的对照断言，防止两边各写一份。

`Game/ai/简单AI.gd` 只负责"把局面读成诉求"（`_ops_demands` 等）和"执行"（`_exec_*`），
"哪条诉求先做、这笔钱该不该花"由 `ai/目标层.gd` 决定 —— 判据只有一份。
