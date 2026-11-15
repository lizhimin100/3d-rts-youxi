# 战争原岛 — AGENTS.md

> 给 AI 与本项目所有协作者：**先读「硬约定」，再动手。** 改完必须自检并提交。
> 玩法细节不写在这里，写在 `Documents/<专题>.md`；本文件只放"怎么不把工程做坏"。

## 一句话

**融合肉鸽构筑与半回合制 RTS 战斗的 3D 策略游戏**（Godot 4.7 / GDScript）：玩家是**战场指挥官**而不是操作员——**规划阶段**（无限时、世界完全暂停）制定战略战术并批量下达命令，**执行阶段**实时运行、观察战果、必要时亲自接管；部队以 **Squad** 为基本战斗实体，短局运营只用 **CP + 人口 + 训练/建造时间**（长局金币与局内 CP/人口完全隔离），**副官**静默执行常规操作、不弹窗不建议、不得覆盖玩家命令，玩家始终拥有最高控制权；目标平台 **Steam + 低中端手机**，规则逐步迁到独立 **C# 内核**，引擎只做表现与适配。

> 设计原则 P1–P8：指挥官不做操作员 · 准备决策/执行观察 · 副官静默执行 · 玩家命令优先 · Squad 为核心战斗实体 · 短局 CP 化 · 长短局资源隔离 · AI 不破坏明确命令。

## 目录地图

```
Engine/     我们自己的引擎层：启动/存档/多语言/音频/对话/平台/调试接口。共享库，游戏只调用它。
Model/      纯逻辑：伤害、经济、生产、成长、存档 schema、确定性推演。零引擎 API，可命令行单独跑。
Views/      画面与输入：hud/（界面组件）input/（选择指令）camera/ world/（3D 表现）scenes/ screens/。
Game/       引擎耦合的玩法装配（core/systems/units/ai/pathing/map/config/audio）。**迁移期资产，新代码不进这里。**
Content/    内容与资产：data/（JSON 唯一数值源）i18n/ keys/ art/ audio/ maps/ legacy/（旧 .tres 留档）。
Tests/      无窗口自检：checks/（--check 入口）sim/（--simulate）model/（纯逻辑用例）suites/（历史自检脚本）。
Tools/      稳定流程脚本：run-game.ps1（唯一入口）gen/（生成器）build/（发行与 Demo）qa/ migrate/。
Documents/  设计真相与专题：concept.md（三栏）、architecture.md、data-pipeline.md、debug-bridge.md、专题与索引。
addons/     Godot 编辑器插件（地图编辑器）。不进发行版。
```

## 硬约定

1. **唯一数值来源 = `Content/data/*.json`**。改数值只改 JSON，不改代码。单位/建筑/技能/营地卡由 `Game/config/card_store.gd` 读写；`.tres` 卡只留在 `Content/legacy/cards/` 作迁移留档，**运行时不再读**。
2. **文案只走 `Content/i18n/ui.csv` + `I18n.t(key)`**。新界面（`Views/screens/`）零写死中文；旧界面按 `Content/i18n/legacy_budget.json` 冻结，只许降不许升。
3. **逻辑和画面分家**：`Model/` 不出现 Node/SceneTree/FileAccess/OS/Engine/Input/Time，也不出现 `res://Model/` 以外的路径；游戏侧只把数据喂给 Model、把结果画出来。伤害与经济已委托 Model，**不许再写第二份公式**。
4. **引擎层只进 `Engine/`**：游戏代码只调用，不复制；Steam/手机/主机差异只在 `Engine/platform/`，玩法里禁止平台判断。改 Engine 后必须重跑 `python Tools/gen/gen_engine_pin.py`（pin.json 是共享库的版本锁）。
5. **测试默认值写在程序里，不靠记参数**：`App.test_mode` 在无头、`--check/--simulate/--shot/--qa*` 时自动开启 → 静音、不抢焦点、存档隔离到 `res://.test_profile/`。**测试永远不读写玩家真实存档**。
6. **禁止用截屏、点窗口、发按键操作游戏**。调试只走 `Engine/debug` 的 `127.0.0.1` 接口：截图 / 读状态 / 执行动作 / 关闭。接口不够就**补接口**，不要退回去点窗口。重启游戏后先 `GET /health` 对比 `pid + boot_id`，确认连上的是新进程。
7. **截图只证明画出来了，不证明点得动**。交互画面必须用真实输入事件点一次，并验证状态变化（`Content/data/screens.json` 里 `click` 必须配 `expect`），点不动就输出 `SHOT FAIL`。
8. **检查调用真实代码，不在检查里把公式重推一遍**。每条检查都要**反着验**：故意改坏 → 看它报错 → 改回 → 通过。
9. **约定不能只写在注释里**：一条前提被破坏会静默出错时，就要有一条无窗口检查能抓到它。**修一个 bug = 修复 + 一条新检查**；新踩的坑先写进本文件规则，再补检查。
10. **登记自动化**：新增/删除资产跑 `python Tools/gen/gen_asset_keys.py`；新增/删除源文件跑 `python Tools/gen/gen_manifest.py`；不许手改清单。调试面板改数值必须写回 `Content/data/*.json`（`DebugTuner` 只允许写这个目录）。
11. **编辑器和调试工具不进发行版**：`Tools/build/release_exclude.txt` + `App.release`/`OS.is_debug_build()` 双门禁；Demo 裁剪只处理发布副本，不动源码。
12. **本文件 ≤ 20KB**；新增玩法/系统说明写 `Documents/<专题>.md` 并在这里只放链接。**中文优先**：新增文件/注释/UI 文案优先中文；
    只有跨语言或引擎 key 用 ASCII；七块砖的结构性目录名保持不变。

### 会直接毁文件的坑（历史教训，别重犯）

- 新增 `class_name` 后先 `--import`（`./Tools/run-game.ps1 --import`），否则别的脚本报 "Could not find type"。**能不用类名当类型就不用**：只通过 `.call()` 调的对象写 `Node`，脚本用 `preload` 常量拿。
- 编辑器插件脚本新增成员**先写 `var`**；漏一个未声明变量会让整个插件编译失败，报错行往往只是受害者，往上找第一条 Parse Error。
- `--quit-after` / `--resolution` 是**引擎参数**，必须放在 `--` 之前；用户参数在 `--` 之后。
- 读大文件分段读（`read` 有截断风险），小改用 `edit`，不要整文件 `read` 再 `write` 回去。
- 无头/沙箱环境可能写不了 `user://`（AppData）；测试存档因此放项目内 `.test_profile/`（已 gitignore）。
- `PackedByteArray` 是值类型：从 Dictionary 取出来 append 后**必须写回**，否则数据悄悄丢（调试接口踩过）。
- **每帧调 `_go_to(pos, force=true)` 是性能自杀（2026-11-14 踩过）**：`force` 会把 `_repath_cd`
  清零，等于每帧一次完整 A*（~104µs）。同一目标续行一律走 `_go_to(pos)`，
  由 `_request_path` 的 0.25s 节流 + 每帧配额兜住；只有"玩家刚下新指令/换工地站位"才允许 force。
  反查办法：`--perf-long=2` 看 `o.goto` 与 `path_n`，`path_n` 上千 = 出事了。
- **卡资源的 `resource_path` 不许 `take_over_path` 到 `.json`（2026-11-14 踩过）**：
  这样会把一个 Resource 登记在 `.json` 路径上，编辑器随后用
  `get_dependencies(path, "Resource")` 去扫它，报一串
  `No loader found for resource: …camp_den.json (expected type: Resource)`。
  卡的真实路径只走 `CardStore.path_of()`（读 meta `source_path`），
  卡 JSON 里也**不许**出现 `metadata/*` 字段（`JsonCodec` 两头都跳过）。
- 目录迁移/重导入后，编辑器可能缓存"脚本还没编译好"的资源，表现为"打开原地图提示不是 MapDef"。
  `MapStore.load_tres` 已加 `CACHE_MODE_IGNORE` 重读 + 逐字段兜底；还报就重启编辑器或 `--import`。
- **别对已释放的实例 id 直接 `instance_from_id(id) as X`（2026-11-14 踩过）**：
  `instance_from_id` 拿到的可能是 freed object，`as` 会刷
  `Trying to cast a freed object` —— 这是**引擎级错误输出**，不进脚本逻辑、
  也不影响正确性，但每帧几十条足以把帧率吃掉。正确顺序：先
  `var raw = instance_from_id(id)`，判 `is_instance_valid(raw)`，再 cast。
- **长局"七八分钟后卡"不是 AI 判定**（2026-11-14 实测，10 分钟 headless 采样）：
  `ai` 各分段合计只有 40~180 ms/s，而 `unit` 从 150 涨到 1000 ms/s、A* 单次
  从 0.7 涨到 6.5 ms。**先看 `--perf-long` 的 `sys` 再动手**，别去猜某个函数
  在做树搜索。判定层已经下沉到 `Model/ai/目标层.gd` 且全是 O(候选数) 的纯函数。
- **搬目录最容易漏的是 `addons/`（2026-11-14 踩过）**：地图编辑器是 EditorPlugin，一条
  `preload("res://旧路径/…")` 会让**整个插件** Parse Error —— 先报"文件不存在"，再连带十几行
  "Cannot infer the type of …"（`const Spec` 一变 Any，用它的变量全推断不出来），最后只给你一句
  `Invalid call. Nonexistent function 'new' in base 'GDScript'`，看报错根本看不出是路径问题。
  搬完先跑 `--check`：`硬路径都指向真实文件` 那条会把**全部** preload / `.tres`+`.tscn` 的
  ext_resource / `project.godot` 的自动加载与插件清单逐条对一遍（当前 334 条）。

## 验证命令

```powershell
./Tools/run-game.ps1 --check                  # 无窗口体检：数据/文案/资源/分层/存档隔离/发行门禁/文档
./Tools/run-game.ps1 --long                   # 旧即时战略（默认启动是短局：规划/执行 + CP）
./Tools/run-game.ps1 --round-test             # 半回合制自检：规划/执行/CP/小队/部署（短局，无窗口）
./Tools/run-game.ps1 --simulate --games=5     # 只用 Model 跑推演，输出数值报告（末行 SIM {json}）
./Tools/run-game.ps1 --shot hud _qa/hud.png   # 离屏开画面 + 真点一次「建造」+ 存图
./Tools/run-game.ps1 --shot main _qa/main.png # 非交互画面只截图
./Tools/run-game.ps1 --import                 # 新增 class_name / 场景 / 资源后跑一次
```

- **通过判据**：`--check` 退出码 0 且输出 `CHECK 通过 N 项 / 失败 0`；`--shot` 退出码 0 且输出 `SHOT PASS`；`--simulate` 退出码 0 且有 `SIM {...}`。**不接受"0 条断言算通过"**。
- 截图不是证据链：判断"点得动"看 `SHOT PASS` 前的交互行（`点击 指令_建造 → 指令_农场 出现`）。
- 历史自检（`Tests/suites/`）仍可用：`godot --headless --path . --script Tests/suites/配置回归.gd` 等；入口与常红项见 `Documents/索引/测试索引.md`。
- 常红状态：2026-11-14 起 `配置回归` 为 **282/0**（部门制 `dept=on` 已转正，测试同步更新）；历史常红记录见 `Documents/verification.md`。

### 长局 / 对照局的硬规定（沿用）

- 下结论的长局**最短 10 分钟**（`--minutes=10`）；5 分钟局样本不足，别用来调系数。
- 本机 `--speed=8` 不会更快（CPU bound），按"游戏时长 ≈ 墙钟"排期。
- 改前/改后对照必须**同构建、同 seed、同难度**，用开关（`--dept=on/off` 等）切参数，不要回滚代码再编译两次。

## 拍板记录

> 只记"已经定了的"和"还没定的"。被推翻的规则用删除线保留，写明作废日期，不直接删。
> 新增记录写日期；提案先放"建议"，试玩过再升"已确认"。

### 已确认

- **2026-11-14 按「七块砖」重排**：`Engine/Model/Views/Game/Content/Tests/Tools/Documents` 八目录（七块砖 + 迁移期 Game/）。
- **2026-11-14 数值真源改为 JSON**：`Content/data/*.json`；旧 `.tres` 卡退役到 `Content/legacy/cards/`，只留档不参与运行。
- **2026-11-14 共享引擎层 = `Engine/`**，用 `Engine/pin.json` 的 sha256 固定；游戏仓库不顺手改共享库。
- **2026-11-14 规则下沉 Model**：伤害公式、扣费/人口判断的唯一实现已迁到 `Model/core/`，游戏侧只做适配。
- **2026-11-14 测试模式默认隔离**：静音、无焦点、存档 `res://.test_profile/`；测试不碰玩家真实存档。
- **2026-11-14 调试接口只监听 127.0.0.1**，发行构建不启动，`Engine/debug` 整目录排除。
- **2026-11-14 `run-game` 是唯一入口**：`--check/--simulate/--shot`；脚本在 `Tools/run-game.ps1`。
- **2026-11-14 文档分级**：AGENTS.md 只放流程与约定；设计真相在 `Documents/concept.md`；专题各一篇。
- **2026-11-14 项目定名《战争原岛》**（不再叫"铁血战歌"）；代码/文档/窗口标题统一。
- **2026-11-14 `--dept=on` 转正**：部门制是默认主线；`--dept=off` 只保留作 2C-8 对照。
- **2026-11-14 保留 4 队混战为主场景**（默认 `match_slots = 4`）。
- **2026-11-14 音效只留一声"叮"**：删掉全部合成音效与 51 个 wav（`Content/audio/` 只剩 BGM），
  全局唯一音效 = `synth_bank.PRESETS["ui_ding"]`（运行时合成，UI 更新时响）；
  音效生成脚本一并删除，改音色只改那一条预设 + 跑 `Tests/checks/synth_probe.gd`。
- **2026-11-14 金矿单人制**：载位 1（`可采集物.max_slots`），其余农民在矿外排队等；
  木携带 **8/趟**、一棵树 **35 次**（`game.json` 的 `harvest_carry_wood` / `tree_charges`）。
  AI 采金人数按"载位总数"封顶（`简单AI._gold_mine_capacity`）。
- **2026-11-14 移动 A 段"卫生部分"转正**：分离/贴墙推出 20Hz、贴地目标 20Hz、空闲索敌 1s
  （`--legacy-move` 关掉做 A/B 对照）。600 兵同构建实测 unit -44%、fps +25~30%。
- **2026-11-14 攻击/攻击移动"继续走完目标"不再每帧 force 重算路径**：这是"越打越卡"的真凶
  （82 单位时 4208 次 A*/秒、fps 18 → 修后 119 次、fps 141）。见 `Documents/性能基线.md` §6。
- **2026-11-14 中文优先**：七块砖的**结构性目录名**（Engine/Model/Views/Game/Content/Tests/Tools/Documents）保持不变（它们是契约）；
  其余新增内容（界面文案、注释、文档、玩法脚本名）优先中文；只有跨语言/引擎 key 用 ASCII。
- **2026-11-14 平台/存档/对话只保留接口**，暂不接玩法、不接 SDK。
- **2026-11-14 音效改为 AudioStreamGenerator 运行时合成**（不再依赖音效 wav/ogg 文件；音乐仍可用文件）。
- **2026-11-14 地图编辑器继续由真人维护**：地图/单位卡/建筑卡/技能卡的可视编辑是给人用的，agent 不代点 UI；
  agent 改数据只改 JSON，改完用 `--check` 验。
- **2026-11-14 索敌口径 = 视野即警戒圈**：待机/警戒单位在 `max(sight_range, acquire_range)` 内
  主动锁定**并走过去打**；`_stance_pursues()` 是唯一「这条指令许不许主动出击」出口，
  **驻守/观察/采集/建造/修理/送资源/农民/建筑**一律不追（只还手）。
  旧行为「待机只打 1.35m 贴脸」就是玩家报的"没有索敌"；`战斗自检` C 组已改成反向断言
  （9m 外的固定敌塔：必须锁上、必须靠近 ≥1.5m、不许 IDLE）。
- **2026-11-14 采金一趟 = 1.25 秒**：起手 0.35（`cards/skills/mine_gold.json` 的 `cast`）
  + 循环 0.9（`game.json` 的 `harvest_time_gold`）。采金动画改 **2 挥**、定速上限 3.6。
  木头仍 4.0s。`采集自检` 末尾按这两个数做口径断言（防止被改回去）。
- **2026-11-14 豺狼人斥候改近战刺客**：`range=75`、`projectile=0`、`attack_cooldown=1.25`、
  `anim_set=1`、`def_role=frontline`（不再射箭）。萨满"走路打滑"的根因不是 clip 缺失，
  而是 walk 隐含地速 0.85m/s 与全局 `ANIM_WALK_MPS=1.9` 不匹配（2.23 倍滑步）：
  新增 `UnitCard.anim_walk_mps` 逐资产标定（0 = 旧口径），倍率上限 2.6/3.0 → 5.2。
- **2026-11-15 「准备阶段」正式更名「规划阶段」**：`RtsConst.Phase.PLANNING` / `Game.is_planning()`；
  界面文案、注释、文档同步替换。规划阶段 = 世界 `paused` + **显式 `PROCESS_MODE_ALWAYS` 白名单**
  （HUD/规划界面/地图层/镜头/光标/选择/指令/战区输入/部署输入/回合控制）；任何推进世界时间的东西不许进白名单。
- **2026-11-15 规划阶段界面按新草图重排**：左上指挥官卡（头像+基地血量+"基地不可修理"）/ 左中 CP 菱形（点击展开建造·训练）/
  中上局外资源（短局灰显）/ 右上人口+日夜（规划期静止）/ 底部操作面板（部署三键·训练卡·建造卡）/ 右下【规划结束】【取消】。
  **执行阶段的魔兽底栏不动**；规划阶段隐藏副官开关与资源条。实现：`Views/hud/规划阶段界面.gd` + `规划地图层.gd`。
- **2026-11-15 取消"预留人口"**：`food_reserved → food_queued`，界面统一 `已用/上限`，
  已用 = `RtsFaction.food_committed()`（存活 + 在训）。下单即扣 CP、即占人口。
- **2026-11-15 部署是二段式纯地图操作**：底部【进攻】【防守】【占据】→ 指针换图标 + 地图预览
  （虚线箭头 / 10m 防区 / 据点金圈）→ 左键落点写 `命令记录`（新增 `Order.DEFEND / CAPTURE`）。
  实现：`Views/input/部署输入.gd`；HUD 按钮与地图层只读它的 `mode()/preview()`。
- **2026-11-15 "未完成训练将取消"的结算点 = 回合结束**（不是规划结束）：训练读条只在解冻时走，
  规划阶段清队列等于永远造不出兵；`回合控制._cancel_unfinished_training()` 只清玩家阵营、不退 CP。
- ~~目录冻结，只加导航层~~（2026-11-13 提出，**2026-11-14 作废**：用户要求按七块砖物理重排；旧方案见 `Documents/文件梳理与Agent协作方案.md`）。- ~~`.tres` 卡是数值唯一真源~~（2C-4 起，**2026-11-14 作废**：改为 JSON，原因：agent 可读可 diff、与 C# 内核解耦、不被 Resource 脚本绑定）。
- ~~用 `res://配置/游戏配置.tres` 覆盖全局配置~~（**2026-11-14 作废**：改 `Content/data/game.json`）。
- ~~AI 诉求系数以 `.tres` 为备份/展示真源~~（**2026-11-14 作废**：改 `Content/data/ai_demand.json`）。

### 建议（待试玩确认）

- **副官全接管**：建造/训练/采集/**战斗**都默认接管；玩家可一键"夺回控制"或关闭副官接管。覆盖比例待试玩。
- **一局时长与目标**：目标 10~15 分钟；每局目标不同——摧毁目标 / 防守 N 分钟 / 占据某据点一段时间。
- **肉鸽层数/词条数量**：待定。
- **手机操作**：默认自动施法 + 面板化指令，减少精确点选；低端机降级项（阴影/单位数）待实测。
- **C# 内核**：`net8.0` 纯类库 + xunit，Godot 只留 Adapter；参考 YokiFrame 的工程分层，不整体引入 QFramework（见 `Documents/topics/qframework-assessment.md`）。
- **数值基线**：镜像推演 5 局 2:3 只作地基 smoke，不能当平衡结论；调数值前先跑 10 分钟长局。

### 待决定

- 正式英文名 / 商店名。
- Steam / 手机平台 SDK 的接入顺序与账号方案。
- 云存档策略（本地槽位已就绪，云端适配器未接）。
- 旧 `Game/` 玩法层继续拆进 Model 的顺序：先命令卡/建筑可用性，再单位状态机，最后 AI 决策。

## Git 节奏

**每完成一个阶段提交一次**，不要攒、不要等提醒。

1. `git add -A`
2. `git commit -m "<中文前缀>: <一句话>"`（前缀：feat / fix / art / chore / docs / test）
3. `git log --oneline -1` 确认真的落库
4. `git status --short` 只应剩 `.gitignore` 里的运行时产物

- 大改之前先提交一次，留一个"可以退回来的点"。
- 不提交：`.godot/`、`_qa/`、`.test_profile/`、日志、`Content/maps/_自动保存.tres`、`NVIDIA Corporation/`。
- 提交前看一眼 `git status`，别把 `.godot` 或截图混进去。
- 被推翻的规则**不要从文档里删**：用 `~~删除线~~` + 作废日期，让后来者知道为什么改。
