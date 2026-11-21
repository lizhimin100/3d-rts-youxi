# 战争原岛 — AGENTS.md

> 给 AI 与本项目所有协作者：**先读「硬约定」，再动手。** 改完必须自检并提交。
> 玩法细节不写在这里，写在 `Documents/<专题>.md`；本文件只放"怎么不把工程做坏"。

## 一句话

**单通道 3D 长横道 + 规划阶段打牌/建造/升星三合一 + 90 秒攻防双场小队自动推进与局部微操**（Godot 4.7 宿主 + 纯 C# 规则内核）。玩家是**战场指挥官**而不是操作员：**规划阶段**（无限时、世界完全暂停）用手牌部署、建造与升星，按【规划结束】后进入 **90 秒执行阶段**——攻防两场同时推进，小队自动接战，玩家只做局部微操。目标平台 **Steam + 低中端手机**。

> 设计原则：**指挥官不做操作员 · 规划决策 / 执行观察 · 单通道战场 · 小队是战斗实体 · 打牌=建造=升星 · 短局只认 CP+人口 · 规则只写一份（C#）· 引擎只做表现与适配。**

## 目录地图（七块砖）

```
Engine/     自研引擎层：启动/存档/多语言/音频/对话/平台/调试接口。共享库，游戏只调用。
Model/      **纯 C# 规则内核**（net8.0 类库，零 Godot）：R1 换算、伤害、经济、成长、可用性、确定性推演。
Screens/    3D 表现与输入：bridge/（C# 桥）hud/ input/ camera/ world/（美术/人群/沙盘）scenes/。
Game/       引擎耦合的玩法装配（core/systems/units/map/config/adapters）。**迁移期资产，新代码不进这里。**
Content/    内容与资产：data/（JSON 唯一数值源）i18n/ keys/ art/ audio/ maps/ legacy/（旧 .tres 留档）。
Tests/      无窗口自检：checks/（--check 入口）sim/（--simulate）model/（规则用例）suites/（历史自检）。
Tools/      稳定流程脚本：run-game.ps1（唯一入口）gen/ build/ qa/ migrate/。
Documents/  设计真相与专题：concept.md / combat_formula.md / 战斗与规划.md / architecture.md / 专题与索引。
addons/     Godot 编辑器插件：war_island_editor=开发者编辑器（默认）；map_editor=旧地图编辑器（默认禁用）。不进发行版。
```

## 硬约定

1. **距离铁律 `R1 = 0.015`**：唯一真值在 `Model/Core/RtsUnits.cs`。`Model/` 全层用**游戏数值**（射程 125 / 650 / 870）计算；**只有 `Screens/` 在落到世界坐标时乘 R1 换成米**。GDScript 侧只许走 `Game/config/射程基准.gd` 的 `r1()/米()/值()`（它转发内核，自己不再写字面量）。想让某个单位更远，改卡面数值，不动 R1。
2. **规则只写一份，写在 `Model/`（C#）**：伤害、护甲/克制、扣费/人口/CP、主城门槛、升星、可用性、推演都在 C#。GDScript 只经 `Game/adapters/*.gd` 转发；**不许在 GDScript 里再写第二份公式**。
3. **`Model/` 零 Godot**：没有 `Godot.NET.Sdk`、没有 `using Godot`、没有 `res://`。宿主用 `ProjectReference` 引用，`Model/**/*.cs` 必须从宿主 csproj 排除（否则编两遍）。
4. **唯一数值来源 = `Content/data/*.json`**。改数值只改 JSON。单位/建筑/技能/营地卡由 `Game/config/card_store.gd` 读写；`.tres` 卡只在 `Content/legacy/cards/` 留档，运行时不再读。
5. **文案只走 `Content/i18n/ui.csv` + `I18n.t(key)`**。`Screens/` 新界面零写死中文；旧界面按 `Content/i18n/legacy_budget.json` 冻结，只许降不许升。
6. **引擎层只进 `Engine/`**：游戏代码只调用，不复制；平台差异只在 `Engine/platform/`，玩法里禁止平台判断。改 Engine 后重跑 `python Tools/gen/gen_engine_pin.py`。
7. **测试默认值写在程序里**：`App.test_mode` 在无头、`--check/--simulate/--shot/--qa*` 时自动开启 → 静音、不抢焦点、存档隔离到 `res://.test_profile/`。**测试永远不读写玩家真实存档**。
8. **禁止用截屏、点窗口、发按键操作游戏**。调试只走 `Engine/debug` 的 `127.0.0.1` 接口：截图 / 读状态 / 执行动作 / 关闭。接口不够就补接口。重启后先 `GET /health` 对比 `pid + boot_id`。
9. **截图只证明画出来了，不证明点得动**。交互画面必须用真实输入点一次并验证状态变化（`Content/data/screens.json` 的 `click` 必须配 `expect`）。
10. **检查调用真实代码，不在检查里重推公式**；每条检查都要**反着验**（故意改坏 → 看它报错 → 改回）。**修一个 bug = 修复 + 一条新检查**。
11. **登记自动化**：新增/删除资产跑 `python Tools/gen/gen_asset_keys.py`；新增/删除源文件跑 `python Tools/gen/gen_manifest.py`；不许手改清单。
12. **编辑器和调试工具不进发行版**：`Tools/build/release_exclude.txt` + `App.release`/`OS.is_debug_build()` 双门禁。
13. **本文件 ≤ 20KB**；新增玩法说明写 `Documents/<专题>.md`，这里只放链接。**中文优先**：新增文件/注释/UI 文案优先中文；跨语言或引擎 key 用 ASCII；七块砖的结构性目录名保持不变。

### 会直接毁文件的坑（历史教训，别重犯）

- **新增/改名 `class_name` 后先 `--import`**（`./Tools/run-game.ps1 --import`），否则别的脚本报 "Could not find type"。能不用类名当类型就不用：只通过 `.call()` 调的对象写 `Node`，脚本用 `preload` 常量拿。
- 编辑器插件脚本新增成员**先写 `var`**；漏一个未声明变量会让整个插件编译失败，报错行往往只是受害者，往上找第一条 Parse Error。
- `--quit-after` / `--resolution` 是**引擎参数**，必须放在 `--` 之前；用户参数在 `--` 之后。
- 读大文件分段读，小改用 `edit`，不要整文件 `read` 再 `write` 回去。
- 无头/沙箱环境可能写不了 `user://`；测试存档因此放项目内 `.test_profile/`（已 gitignore）。
- `PackedByteArray` 是值类型：从 Dictionary 取出来 append 后**必须写回**，否则数据悄悄丢。
- **卡资源的 `resource_path` 不许 `take_over_path` 到 `.json`**：编辑器会对 `.json` 做依赖扫描并报 `No loader found for resource`。卡的真实路径只走 `CardStore.path_of()`。
- **别对已释放的实例 id 直接 `instance_from_id(id) as X`**：先 `var raw = instance_from_id(id)`，判 `is_instance_valid(raw)`，再 cast（否则每帧刷 `Trying to cast a freed object`，帧率被吃掉）。
- **搬目录最容易漏的是 `addons/`**：地图编辑器是 EditorPlugin，一条 `preload("res://旧路径/…")` 会让**整个插件** Parse Error。搬完先跑 `--check`，`硬路径都指向真实文件` 会把 preload / ext_resource / 自动加载逐条对磁盘。
- **GDScript 静态函数里拿自动加载要按名找**：`--script` 模式下 `Cfg`/`Game` 不是编译期全局名；C# 桥也因此不用自动加载，统一走 `Game/adapters/bridge.gd`（懒建 RefCounted）。
- **XML 注释里不许出现连续 `--`**（`.csproj` 会直接 MSB4025 加载失败）。

## 验证命令

```powershell
./Tools/run-game.ps1 --check                  # 无窗口体检（会先 dotnet build 内核）
./Tools/run-game.ps1 --simulate --games=100   # 第 1 关 100 局（联盟 vs 豺狼人），末行 SIM {json}
./Tools/run-game.ps1 --round-test             # 半回合自检：规划/执行/CP/小队/部署
./Tools/run-game.ps1 --shot main _qa/main.png # 离屏截图（交互画面会真点一次并验状态）
./Tools/run-game.ps1 --import                 # 新增 class_name / 场景 / 资源后跑一次
dotnet build 战争原岛.csproj                   # 只编译内核 + 宿主
```

- **通过判据**：`--check` 退出码 0 且输出 `CHECK 通过 N 项 / 失败 0`；`--shot` 退出码 0 且输出 `SHOT PASS`；`--simulate` 退出码 0 且有 `SIM {...}`。**不接受"0 条断言算通过"**。
- 历史自检（`Tests/suites/`）：`godot --headless --path . --script Tests/suites/战斗自检.gd` 等；入口见 `Documents/索引/测试索引.md`。

## 拍板记录

> 只记"已经定了的"和"还没定的"。被推翻的规则用删除线保留 + 作废日期，不直接删。
> 新增记录写日期；提案先放"建议"，试玩过再升"已确认"。

### 已确认

- **2026-11-20 正式转型《战争原岛》**：单通道 3D 长横道；规划阶段打牌/建造/升星三合一；执行阶段 90 秒攻防双场、小队自动推进 + 局部微操。
- **2026-11-20 距离铁律 `R1 = 0.015`**：`Model/` 只认游戏数值，`Screens/` 才乘 R1 换米；真值只在 `Model/Core/RtsUnits.cs`。
- **2026-11-20 `Model/` 改为纯 C# 内核**（`net8.0` 类库、零 Godot）；GDScript 侧经 `Game/adapters/` 转发；宿主 `战争原岛.csproj` 只留 `Screens/` 的桥与编辑器脚本。
- **2026-11-20 `Views/` 物理更名为 `Screens/`**：3D 表现与输入统一入口；`res://Views` 全仓库清零。
- **2026-11-20 短局是唯一模式**：删除 `--long` 旧即时战略入口；金币/木材只作局外长线账本，不再有局内采集。
- **2026-11-20 调试接口只监听 127.0.0.1**；发行构建不启动，`Engine/debug` 整目录排除。
- **2026-11-20 `run-game` 是唯一入口**：先 `dotnet build`，再 `--check/--simulate/--shot`。
- **2026-11-21 新战斗内核**：6 步伤害唯一实现在 `Model/Combat/CombatCalculator.cs`（命中→暴击→穿透→承伤→6×6 克制→最终），表在 `Content/data/combat.json`；旧 `Model/Core/Damage.cs` 只服务旧 GDScript 战斗层，新代码不许调。
- **2026-11-21 12 兵种进 `Content/data/units.json`**：三大阵营各 4；距离全用游戏数值；近战无投射物、远程有；默认命中/闪避/暴击 100/0/0；弩兵 `35%+3` 破甲；`bandit_lord` 暂 `enabled=false`；鱼人走占位网格。
- **2026-11-21 规划与双 90 秒**：`planning.json` 管 CP/人口/卡牌/3 合 1；`levels.json` 管第 1 关两轮波次；建造牌 Exhaust、训练牌按 Tag 全场产兵、策略牌循环；轮末清场，定性复盘按 code 聚合。详见 `Documents/战斗与规划.md`。
- **2026-11-14 按「七块砖」重排**：`Engine/Model/Screens/Game/Content/Tests/Tools/Documents` 八目录（七块砖 + 迁移期 Game/）。
- **2026-11-14 数值真源 = JSON**：`Content/data/*.json`；旧 `.tres` 卡退役到 `Content/legacy/cards/`。
- **2026-11-14 测试模式默认隔离**：静音、无焦点、存档 `res://.test_profile/`；测试不碰玩家真实存档。
- **2026-11-14 中文优先**：结构性目录名保持英文契约；界面/注释/文档/新脚本优先中文，跨语言 key 用 ASCII。
- **2026-11-14 升星口径**：击杀 15 经验、击杀者独得；升一星 = 金×2 + 木×3（三星同价）；新兵/老兵/精英/王牌；+15/+30/+80% 攻击，+20/+40/+100% 耐久。
- ~~**2026-11-14 副官静默执行**（玩家侧脚本 AI：补农/派采集/盖房/带兵推进，玩家下令即接管）~~ —— **2026-11-20 作废**：副官与整套旧 AI 决策链（简单AI / 控制权 / 战区指令 / 目标层 / 战斗模型）已删除，玩家全部手动指挥。
- ~~**2026-11-14 农民经济采集**（采金 20/趟、木 8/趟、金矿 6000、树 35 次、载位排队）~~ —— **2026-11-20 作废**：短局禁采集，长局已退役，采集不再是玩法。
- ~~**2026-11-14 全图网格 A\* 寻路**（`GridPathfinder`，绕建筑/不切角/路径平滑）~~ —— **2026-11-20 作废**：重型自由全图寻路删除；单位改为直线转向 + 分离/贴墙滑动/推出，`NavGrid` 只保留占格与净空。
- ~~**2026-11-14 建筑建造进度条 + 训练读条队列**（工地/农民钻入/进度条/队列取消退款）~~ —— **2026-11-20 作废**：建筑落点即完工，训练不再排队；部署由规划阶段的手牌/CP 决定。
- ~~**2026-11-14 战争迷雾**（视野点亮/已探索记忆/雾中敌人隐藏/小地图遮罩）~~ —— **2026-11-20 作废**：单通道战场不需要迷雾，模块与开关全部删除。
- ~~**2026-11-14 `--dept=on` 部门制 AI 为默认主线**~~ —— **2026-11-20 作废**：旧 AI 整体删除，执行阶段敌方由脚本波次生成。
- ~~**2026-11-15 规划阶段明牌意图 / 战区指令（F5–F8）**~~ —— **2026-11-20 作废**：给 AI 发意图的通道随 AI 一起删除；只保留玩家自己的【进攻/防守/占据】部署（`Game/commands/部署类型.gd`）。
- ~~**2026-11-14 保留 4 队混战为主场景**~~ —— **2026-11-20 作废**：改为单通道攻防双场（2 队）。
- ~~**2026-11-14 音效只留一声"叮"**~~ —— **2026-11-20 仍有效**，但不再作为验收重点。

### 实现进度（2026-11-20，别把"规则作废"当成"代码删完"）

| 旧系统 | 规则 | 代码 |
|---|---|---|
| 旧自由 AI（简单AI/副官/战区指令/控制权/目标层/战斗模型） | 作废 | **已删**（`Game/ai/` 不再存在） |
| 战争迷雾 | 作废 | **已删**（模块/挂载/可见性/小地图遮罩/设置开关） |
| 全图 A\* 寻路 | 作废 | **已删**（`GridPathfinder` → `NavGrid`，只留占格与净空） |
| 长局（`--long`） | 作废 | **已删**（用户入口；自检台仍不暂停世界） |
| 采集 | 作废 | **玩家侧入口已删**（点树=走位、命令卡/规划记录零 GATHER）；`单位.gd` 里的历史状态机待整块删除 |
| 建造进度条 / 训练读条队列 | 作废 | **待替换**：建筑面板仍是旧 L 型队列；新 UI（手牌/CP）落地时整块删除 |

> `--check` 的「旧系统已移除」只断言**已经删干净**的那几项；上表"待"的两行不许再加新入口，
> 删的时候同步把断言加进去（修一处 = 加一条检查）。

### 建议（待试玩确认）

- **手牌与 CP 的具体配比**：起手几张、每回合补几张、CP 上限（当前 24）待试玩。
- **执行阶段 90 秒**：当前实现仍是 3 回合 × 60 秒的过渡值，切 90 秒要同步改 `game.json` 与波次表。
- **升星在局内的作用**：三星封顶是否够、是否要"升星消耗手牌"待定。
- **手机操作**：默认自动施法 + 面板化指令；低端机降级项（阴影/单位数）待实测。
- **C# 内核继续下沉**：下一步把布局卡、存档 schema、波次编排搬进 `Model/`，GDScript 只留表现。

### 待决定

- 正式英文名 / 商店名。
- 肉鸽层数与词条数量。
- 云存档策略（本地槽位已就绪，云端适配器未接）。
- Steam / 手机平台 SDK 的接入顺序。

## Git 节奏

**每完成一个阶段提交一次**，不要攒、不要等提醒。

1. `git add -A`
2. `git commit -m "<中文前缀>: <一句话>"`（前缀：feat / fix / art / chore / docs / test / refactor）
3. `git log --oneline -1` 确认真的落库
4. `git status --short` 只应剩 `.gitignore` 里的运行时产物

- 大改之前先提交一次，留一个"可以退回来的点"。
- 不提交：`.godot/`、`_qa/`、`.test_profile/`、`dist/`、日志、`NVIDIA Corporation/`、`**/bin/`、`**/obj/`。
- 被推翻的规则**不要从文档里删**：用 `~~删除线~~` + 作废日期，让后来者知道为什么改。
