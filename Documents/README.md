# 文档导航（先看这一页）

> 目的：让接手的 agent **30 秒内知道该读哪一篇**。
> 这页只做路由与状态标记，不写规则；规则在 AGENTS.md 与各篇里。
>
> **2026-11-14 迁移提示**：目录已按七块砖重排（旧 `代码/场景/美术/音频/地图/工具/文档` 不存在）。
> 旧文档里的路径表述可能过期；**路径以 `Documents/architecture.md` 的旧→新对照表为准**，
> 数值真源已从 `.tres` 卡改为 `Content/data/*.json`（见 `Documents/data-pipeline.md`）。

---

## 1. 三十秒路径

| 你要做的事 | 先读 | 再查 |
|---|---|---|
| 任何改动之前 | **`../AGENTS.md`**（硬约定 + 验证 + Git） | `concept.md`（设计真相） |
| 不知道东西在哪 | `architecture.md`（分层 / 数据流 / 旧→新对照） | `索引/文件索引.md`（自动生成） |
| 改数值 / 加单位建筑技能 | **`data-pipeline.md`** | `Content/data/`、`Game/config/card_store.gd` |
| 改文案 / 多语言 | `data-pipeline.md` §4 | `Content/i18n/ui.csv`、`I18n` |
| 用调试接口 / 写自动化 | **`debug-bridge.md`** | `Engine/debug/`、`Tools/qa/bridge_probe.ps1` |
| 加画面 / 截图验证 | `data-pipeline.md` §1（screens.json） | `Tests/checks/shot_runner.gd` |
| 动 UI | `界面说明.md`（第一条：没点名的别动） | `UI风格.md`、`动画规范.md` |
| 动战斗/射程 | `战斗射程口径.md` | `Model/core/damage.gd`（唯一公式） |
| 动 AI | `架构地图.md` §3.1 | `反馈驱动战略_设计.md`、`AI目标层观测.md` |
| 动寻路/移动 | `寻路评估_星际2对照.md` | `架构地图.md` §3.4、`性能基线.md` |
| 动大群/合批 | `人群层.md` | `Screens/world/crowd/README.md` |
| 跑验收 | `../AGENTS.md`「验证命令」 | `索引/测试索引.md` |
| 编辑器/地图 | `地图编辑器UI.md` | `编辑器资产同步.md` |
| 加资产/模型 | `美术规范.md` | `data-pipeline.md` §5（资源 key） |
| 改短局 CP/人口/小队/建造 | **`短局-运营规则.md`** | `Content/data/cards/*.json`、`Model/core/可用性.gd` |
| 改短局固定布局/血量继承 | **`短局-布局卡.md`** | `Content/data/layouts/*.json`、`Game/core/layout_runtime.gd` |

---

## 2. 文档状态（防止照旧文档改新代码）

| 状态 | 含义 | 文档 |
|---|---|---|
| **铁律** | 与玩家约定/契约，违反就是 bug | `界面说明.md`、`作战条令.md`、`动画规范.md`、`战斗射程口径.md`、`../AGENTS.md` |
| **现行** | 与当前代码一致 | `concept.md`、`architecture.md`、`data-pipeline.md`、`debug-bridge.md`、`开发交接.md`、`技能系统.md`、`编辑器资产同步.md`、`地图编辑器UI.md`、`UI风格.md`、`美术规范.md`、`野怪营地.md`、`寻路评估_星际2对照.md`、`人群层.md`、`短局-运营规则.md`、`短局-布局卡.md`、各模块 `Game/*/README.md` |
| **现行·待修** | 有用，但口径有已知缺陷 | `性能基线.md`（headless、单一规模） |
| **设计** | 讲"为什么这么设计" | `反馈驱动战略_设计.md`、`程序化树木评估.md` |
| **历史快照** | 某一天实测，数字会过期 | `AI经济与等级排查报告.md`、`AI目标层观测.md`、`文件梳理与Agent协作方案.md`（其"目录冻结"已被 2026-11-14 重排取代） |
| **外部评估** | 第三方框架调研 | `topics/qframework-assessment.md` |
| **音频** | 程序化音效（AudioStreamGenerator） | `audio-synth.md` |
| **索引** | 自动生成，不要手改 | `索引/文件索引.md`、`索引/测试索引.md` |

> 规则：新文档在标题下一行标 `> 状态：现行 / 设计 / 历史快照（日期）`。
> 历史快照只用来查"当时怎么想的"，不要用来推现在的数值/路径。

---

## 3. 代码索引（给 agent 的地图）

**先看模块 README**：`Game/<模块>/README.md`（core/config/systems/units/ai/pathing + Screens/hud,input,crowd + Tests/suites）。
它写清：职责 / 不属于这里 / 唯一入口 / 禁改项 / 自检命令 / 已知坑。

`索引/文件索引.md` 由 `python Tools/生成文件索引.py` 生成：

- 218 个脚本 / 9.6 万行的模块汇总；
- 每个文件的行数、`class_name`、`extends`、首条注释、preload 出入、自检入口；
- 健康指标：最大的 10 个文件、缺头注释数、私有字段读取/动态调用计数。

用法：**先 grep 索引，再决定打开哪个文件**。不要一上来读 `简单AI.gd`（7500+ 行）。

`索引/测试索引.md` 由 `python Tools/生成测试索引.py` 生成：39 个历史自检脚本的入口/断言数/常红/耗时。
（新体检入口是 `run-game --check`，见 AGENTS.md。）

重跑：

```powershell
python Tools/生成文件索引.py
python Tools/生成测试索引.py
```

---

## 4. 新 agent 的第一小时

1. 读 `../AGENTS.md`（10 分钟）：硬约定、验证命令、拍板记录。
2. 读 `concept.md` + `architecture.md`（15 分钟）：这是什么、东西在哪、哪些是欠账。
3. 按任务在 §1 找到对应文档，只读那一篇。
4. 用 `索引/文件索引.md` 定位 2–3 个文件，读函数头而不是全文。
5. 改完跑 `./Tools/run-game.ps1 --check`；提交前看 `git status`。

**不要做的事**：通读 `简单AI.gd`；从 `主场景.gd` 的 QA 段开始读；相信注释里的常数（已有两处过期：
`REPATH_INTERVAL` 注释写 0.8s 实际 0.25s；`建筑.gd` 头注释写研究 +15% 实际平铺 +1）。
