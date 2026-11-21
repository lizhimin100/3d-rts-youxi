# 架构地图（2026-11-20 转型后）

> 先读 `AGENTS.md` 的硬约定；本文件讲"东西在哪、谁依赖谁、哪些是迁移期欠账"。

## 分层

```
        ┌──────────────────────────────────────┐
        │ Screens/  3D 表现与输入               │  Node/Control/3D；只读 Model/Game
        │  bridge/（C# 桥）hud/ input/ camera/  │
        └──────────────────┬───────────────────┘
                           │ 只调用
        ┌──────────────────▼───────────────────┐
        │ Game/  引擎耦合玩法装配（迁移期）      │  units/systems/map/config/adapters
        └───────┬──────────────────┬───────────┘
                │                  │
    ┌───────────▼──────────┐  ┌────▼──────────────┐
    │ Model/  纯 C# 规则内核 │  │ Engine/  自研引擎层 │
    │ net8.0，零 Godot      │  │ 存档/文案/音频/平台 │
    └───────────▲──────────┘  └────┬──────────────┘
                │ ProjectReference  │ 读
        ┌───────┴───────────────────▼──────────┐
        │ Content/  JSON 数据 + 资产             │
        └──────────────────────────────────────┘
```

依赖方向：`Screens → Game → (Model, Engine)`；`Model` 不依赖任何上层、不引用 Godot；
`Engine` 不依赖玩法；`Content` 是数据，由 `Game/config` 的装载器读进内存对象。

**GDScript 怎么调到 C#**：`Game/adapters/bridge.gd` 懒建一个 `ModelBridge`（RefCounted），
`Game/adapters/*.gd` 只做"转参数 → 调桥 → 拆字典"。不用自动加载，避免启动时序问题。

## 一次启动发生了什么

1. `Engine/boot/app.gd`（`App`）判定模式：无头 / `--check` / `--simulate` / `--shot` / `--qa*` → `test_mode`
   → 静音、不抢焦点、存档根目录切到 `res://.test_profile/`。
2. `Engine/` 的 i18n / save / audio / platform 自动加载；`Keys` 读资源 key 表。
3. `Game/config/配置入口.gd`（`Cfg`）读 `Content/data/game.json` → `GameConfig`；
   `UnitTable.build_units()` 读 `Content/data/cards/{units,buildings}` → 重建 `UnitDef`。
   射程换算走 `射程基准.米()` → `ModelBridge.ToMeters()` → `Model/Core/RtsUnits.cs`。
4. `Game/core/游戏状态.gd`（`Game`）就绪；`Screens/scenes/主场景.tscn` 装配关卡、镜头、HUD、回合控制。
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
   Game / Screens 只读这些对象
```

改数值只改 JSON；`JsonCodec` 遇到未知字段会报错（防拼写错误静默丢字段）。
编辑器插件（`addons/map_editor`）也走 `CardStore` 读写 JSON，不再用 ResourceSaver。

## 短局（唯一模式，2026-11-20）

- **模式**：正常启动 = 短局；`--long` 已删除。测试/QA 也走短局。
- **阶段**：`Game.set_phase(PLANNING/RUNNING/VICTORY/DEFEAT)` 是唯一入口；规划阶段 `SceneTree.paused = true`。
  HUD/镜头/选择/指令/部署输入/回合控制设 `PROCESS_MODE_ALWAYS`；单位/据点/日夜保持默认（被冻结）。
- **命令**：`Screens/input/指令系统.gd` 的 `planned` 存 `Game/commands/命令记录.gd`
  （kind / squad_id / unit_ids / slots / target_id）；规划阶段入队，执行阶段统一发 `order_issued`。
- **小队**：`Game/systems/小队.gd` + `小队注册表.gd`（RefCounted，`Game.squads`）。
  不进场景树、不做碰撞，**不做士气**；命令记录以 `squad_id` 为一等公民。
- **资源**：`RtsFaction.cp/cp_cap`；成本来源 `Content/data/game.json` 与卡面 `cp_cost`。
  `Game.can_afford/pay/refund` 按短局口径走 CP + 人口。
- **敌方**：`Game/core/回合控制.gd` 按波次脚本生成并下令，不再有经济 AI。
- **验证**：`./Tools/run-game.ps1 --round-test`（规划/执行/CP/小队/控制组/多回合/部署）。

## 目录对照（旧 → 新）

| 旧 | 新 |
|---|---|
| `代码/核心` | `Game/core` + `Game/map`（地形/地图生成） |
| `代码/系统` `代码/单位` `代码/寻路` | `Game/systems` `Game/units` `Game/pathing` |
| `代码/配置`（含卡） | `Game/config`；卡数据 → `Content/data/cards`；旧卡 → `Content/legacy/cards` |
| `代码/界面` | `Screens/hud` |
| `代码/操作` `代码/镜头` | `Screens/input` `Screens/camera` |
| `代码/美术` `代码/人群` | `Screens/world/art` `Screens/world/crowd` |
| `代码/测试` | `Tests/suites` |
| `代码/音频` | `Game/audio`（通用音频能力在 `Engine/audio`） |
| `场景/` `美术/` `音频/` `地图/` `文档/` `工具/` | `Screens/scenes` `Content/art` `Content/audio` `Content/maps` `Documents` `Tools` |
| `Views/`（2026-11-20 更名） | `Screens/` |
| `Model/*.gd`（2026-11-20 移除） | `Model/*.cs`（纯 C#）+ `Game/adapters/*.gd`（转发） |

## 迁移期欠账（明确写出来，别装作没有）

- `Game/` 仍是引擎耦合的玩法层：单位/建筑直接操作 Node。**新规则先写 Model，再由 Game 调用**；`Game/` 只减不增。
- `Model/` 目前覆盖：**R1 换算、伤害、经济（金木/CP/人口）、成长（主城/升星）、可用性、确定性推演**。
  布局卡、存档 schema、波次编排还在 GDScript（`Game/adapters/`），下一步下沉。
- 单位状态机里仍有历史分支（采集/建造的枚举与函数），当前**没有入口**（长局退役、农民不再采集）；
  下一步整块删除，并由 `--check` 的"旧系统已移除"断言守住。
- 文案存量约 7600 处写死中文（预算冻结在 `Content/i18n/legacy_budget.json`）；新界面禁止新增。
- 音频：音效是 AudioStreamGenerator 运行时合成（`Engine/audio/synth_*`）；音乐仍由 `Game/audio/音效管理.gd` 管。
- 地图仍是 `.tres`（`MapDef` 是编辑器资源，不走 JSON）；`MapStore.load_tres` 强制 `CACHE_MODE_IGNORE` 重读。
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
| Model 纯度 | `Model/` 混入 GDScript、出现 Godot 符号、csproj 引 Godot |
| 距离铁律 | 内核 R1、650→9.75 换算、规则层零 0.015 |
| C# 内核 | `WarIsland.Model.dll` 存在、桥可实例化 |
| 引擎 pin | `Engine/` 被就地修改、未登记文件 |
| 源文件清单 | 新增/删除文件未重跑 manifest |
| Model 自测 | 纯逻辑断言（R1 / 伤害 / 可用性 / 经济 / 成长 / 布局 / 推演） |
| 游戏侧集成 | 战斗伤害/扣费与内核逐值一致 |
| 可用性 P0 | 一本出二本兵 / 升级中训练 / 队列满 / 没钱训练 / 升级中研究 |
| 卡读写 | 编辑器保存路径（CardStore → JSON → 读回） |
| 地图读回 | 主场景地图经 MapStore 读回（编辑器同一入口） |
| 音频合成 | 预设、AudioSvc 接受、游戏音效映射存在 |
| 存档隔离 | 测试模式、路径、写入/读回 |
