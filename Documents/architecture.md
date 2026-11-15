# 架构地图（2026-11-14 重排后）

> 先读 `AGENTS.md` 的硬约定；本文件讲"东西在哪、谁依赖谁、哪些是迁移期欠账"。

## 分层

```
            ┌─────────────────────────────┐
            │ Views/  画面与输入           │  Node/Control/3D，读 Model/Game 状态
            └──────────────┬──────────────┘
                           │ 只调用
            ┌──────────────▼──────────────┐
            │ Game/   引擎耦合玩法装配      │  迁移期：units/ai/systems/map…
            └───────┬──────────────┬───────┘
                    │              │
        ┌───────────▼───┐   ┌──────▼─────────┐
        │ Model/ 纯逻辑  │   │ Engine/ 引擎层  │
        │ 零引擎 API     │   │ 存档/文案/音频… │
        └───────────▲───┘   └──────┬─────────┘
                    │              │ 读
            ┌───────┴──────────────▼─────────┐
            │ Content/  JSON 数据 + 资产      │
            └───────────────────────────────┘
```

依赖方向：`Views → Game → (Model, Engine)`；`Model` 不依赖任何上层；`Engine` 不依赖玩法；
`Content` 是数据，由 `Game/config` 的装载器读进内存对象。

## 一次启动发生了什么

1. `Engine/boot/app.gd`（自动加载 `App`）判定模式：无头/ `--check` / `--simulate` / `--shot` / `--qa*` → `test_mode`。
   → 静音、窗口不抢焦点、存档根目录切到 `res://.test_profile/`。
2. `Engine/i18n` / `Engine/save` / `Engine/audio` / `Engine/platform` 自动加载；`Keys` 读资源 key 表。
3. `Game/config/配置入口.gd`（`Cfg`）读 `Content/data/game.json` → `GameConfig`；
   `UnitTable.build_units()` 读 `Content/data/cards/{units,buildings}` → 重建 `UnitDef`；
   可采集物/研究从 `harvestables.json` / `researches.json` 读。
4. `Game/core/游戏状态.gd`（`Game`）就绪；主场景 `Views/scenes/主场景.tscn` 装配关卡、镜头、HUD、AI。
5. 调试构建下 `DbgBridge` 在 127.0.0.1 起 HTTP 接口（无头默认不启动，显式 `--debug-bridge` 才开）。

## 数据流（内容 → 运行时）

```
Content/data/cards/units/*.json
        │  CardStore.list → JsonCodec.restore（$script + props）
        ▼
   UnitCard / BuildingCard / SkillCard / CampDef（Resource，内存对象）
        │  UnitTable._def_of_card / 技能表.to_def / 野怪营地表
        ▼
   UnitDef / 技能 Dictionary / 营地定义
        │
        ▼
   Game / Views / AI 只读这些对象
```

改数值只改 JSON；`JsonCodec` 遇到未知字段会报错（防拼写错误静默丢字段）。
编辑器插件（`addons/map_editor`）也走 `CardStore` 读写 JSON，不再用 ResourceSaver。

## 短局（半回合制，2026-11-14）

- **开关**：**正常启动默认短局**（`Game.short_match = true`）；`--long` 回旧长局；`--short` 显式短局；
  `--round-test` 短局自检。测试/QA（`App.test_mode`）默认长局，除非显式 `--short`。长局完全不挂回合控制器。
- **阶段**：`Game.set_phase(PLANNING/RUNNING/VICTORY/DEFEAT)` 是唯一入口；规划/结束阶段 `SceneTree.paused = true`。
  HUD/镜头/选择/指令/移动指示/战区输入/光标/规划面板设 `PROCESS_MODE_ALWAYS`；`Game`/单位/AI/据点/日夜保持默认（被冻结）。
- **命令**：`Views/input/指令系统.gd` 的 `planned` 存 `Game/commands/命令记录.gd`（kind / squad_id / unit_ids / slots / target_id）；
  规划阶段入队，`execute_planned()` 在执行阶段统一发 `order_issued`。
- **小队**：`Game/systems/小队.gd` + `小队注册表.gd`（RefCounted，`Game.squads`）。不进场景树、不做碰撞/迷雾，**不做士气**；
  命令记录以 `squad_id` 为一等公民，成员死亡由注册表自动剪枝。
- **短局资源**：`RtsFaction.cp/cp_cap/cp_regen`；成本唯一来源 `Content/data/game.json` 的 `short_cp_costs`；
  `Game.can_afford/pay/refund` 按 `short_match` 切换 CP / 金木。短局禁采集，农民保留为工程兵。
- **验证**：`./Tools/run-game.ps1 --round-test`（规划/执行/CP/小队/控制组/多回合/部署，66 项断言）。

## 目录对照（旧 → 新）

| 旧 | 新 |
|---|---|
| `代码/核心` | `Game/core` + `Game/map`（地形/地图生成） |
| `代码/系统` `代码/单位` `代码/ai` `代码/寻路` | `Game/systems` `Game/units` `Game/ai` `Game/pathing` |
| `代码/配置`（含卡） | `Game/config`；卡数据 → `Content/data/cards`；旧卡 → `Content/legacy/cards` |
| `代码/界面` | `Views/hud` |
| `代码/操作` `代码/镜头` | `Views/input` `Views/camera` |
| `代码/美术` `代码/人群` | `Views/world/art` `Views/world/crowd` |
| `代码/测试` | `Tests/suites` |
| `代码/音频` | `Game/audio`（通用音频能力在 `Engine/audio`） |
| `场景/` `美术/` `音频/` `地图/` `文档/` `工具/` | `Views/scenes` `Content/art` `Content/audio` `Content/maps` `Documents` `Tools` |

## 迁移期欠账（明确写出来，别装作没有）

- `Game/` 仍是引擎耦合的玩法层：单位/建筑/AI/寻路都直接操作 Node。**新规则先写 Model，再由 Game 调用**；`Game/` 只减不增。
- Model 目前覆盖：伤害、经济、生产、成长、**可用性（训练/研究/建造）**、存档 schema、确定性推演。
  训练/建造/研究的 UI 置灰、指令拦截、建筑自检已经统一到 `Model/core/可用性.gd`（2026-11-14）。
  **单位状态机、技能结算、AI 决策还未下沉**。
- 文案存量仍有约 7300 处写死中文（预算冻结在 `Content/i18n/legacy_budget.json`）；新界面禁止新增。
- 音频：**音效已改为 AudioStreamGenerator 运行时合成**（`Engine/audio/synth_*`，游戏 16 个音效 id 映射到 12 个预设）；
  音乐/语音/闪避/交叉淡化仍由 `Game/audio/音效管理.gd` 管，后续再并入 `Engine/audio`。
- 平台/存档/对话：模块已就绪并有自检，但玩法还没接入（当前没有需要它们的玩法：无联机、无对话剧情、无局外存档）。
  新代码要用这些能力时，只调 `Engine/`，不许在游戏侧复制。
- 地图仍是 `.tres`（`MapDef` 是编辑器资源，不走 JSON）；这是有意保留，不在地基任务范围内。
  目录迁移后编辑器可能缓存坏资源；`MapStore.load_tres` 已强制 `CACHE_MODE_IGNORE` 重读 + 逐字段兜底（2026-11-14）。
- Steam / 手机平台适配器是空实现（如实返回不可用），没有假装成功。

## 检查覆盖（`run-game --check`）

| 检查 | 抓什么 |
|---|---|
| 目录 / 自动加载 | 七块砖目录缺失、旧目录残留、autoload 未注册 |
| JSON 可解析 | 语法错、编码错 |
| 卡结构 | 文件名/id 不一致、hp/攻击为负、营地 counts 与 creeps 不齐 |
| 引用闭环 | 训练/研究/技能/模型/营地/开局编成/推演编制指向不存在的东西 |
| 多语言 | 两列缺失、重复 key、代码引用缺定义、新界面写死中文、旧界面超预算 |
| 资源 key | 登记路径不存在、内容资产未登记 |
| Model 纯度 | 引擎 API、Model 之外的 res:// 路径 |
| 引擎 pin | Engine/ 被就地修改、未登记文件 |
| 源文件清单 | 新增/删除文件未重跑 manifest |
| Model 自测 | 纯逻辑 54 条断言（含可用性 20 条） |
| 游戏侧集成 | 战斗伤害/扣费与 Model 逐值一致 |
| 可用性 P0 | 一本出二本兵 / 升级中训练 / 队列满 / 没钱训练 / 升级中研究 |
| 卡读写 | 编辑器保存路径（CardStore → JSON → 读回） |
| 地图读回 | 主场景地图经 MapStore 读回（编辑器同一入口） |
| 音频合成 | 12 个预设、AudioSvc 接受、游戏音效映射存在 |
| 存档隔离 | 测试模式、路径、写入/读回 |
| 发行门禁 | 排除清单、调试接口的 release 判断 |
| 截图画面表 | 场景不存在、click 没有 expect |
| 文档 | AGENTS.md ≤20KB、CLAUDE.md 一行、concept.md 三栏 |