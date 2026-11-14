# 铁血战歌 · 简易rts — AGENTS.md

> 给 AI 与本项目所有协作者：**先读「硬约定」，再动手。** 改完必须自检并提交。
> 玩法细节不写在这里，写在 `Documents/<专题>.md`；本文件只放"怎么不把工程做坏"。

## 一句话

**肉鸽式 PvE 的 3D 即时战略**（Godot 4.7 / GDScript），核心特色是**副官**替玩家接管重复操作，让轻量玩家也能打得动；目标平台 **Steam + 低中端手机**，规则逐步迁到独立 **C# 内核**，引擎只做表现与适配。

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
12. **本文件 ≤ 20KB**；新增玩法/系统说明写 `Documents/<专题>.md` 并在这里只放链接。新增脚本文件名用 ASCII；已有的中文文件名保留。

### 会直接毁文件的坑（历史教训，别重犯）

- 新增 `class_name` 后先 `--import`（`./Tools/run-game.ps1 --import`），否则别的脚本报 "Could not find type"。**能不用类名当类型就不用**：只通过 `.call()` 调的对象写 `Node`，脚本用 `preload` 常量拿。
- 编辑器插件脚本新增成员**先写 `var`**；漏一个未声明变量会让整个插件编译失败，报错行往往只是受害者，往上找第一条 Parse Error。
- `--quit-after` / `--resolution` 是**引擎参数**，必须放在 `--` 之前；用户参数在 `--` 之后。
- 读大文件分段读（`read` 有截断风险），小改用 `edit`，不要整文件 `read` 再 `write` 回去。
- 无头/沙箱环境可能写不了 `user://`（AppData）；测试存档因此放项目内 `.test_profile/`（已 gitignore）。
- `PackedByteArray` 是值类型：从 Dictionary 取出来 append 后**必须写回**，否则数据悄悄丢（调试接口踩过）。

## 验证命令

```powershell
./Tools/run-game.ps1 --check                  # 无窗口体检：数据/文案/资源/分层/存档隔离/发行门禁/文档
./Tools/run-game.ps1 --simulate --games=5     # 只用 Model 跑推演，输出数值报告（末行 SIM {json}）
./Tools/run-game.ps1 --shot hud _qa/hud.png   # 离屏开画面 + 真点一次「建造」+ 存图
./Tools/run-game.ps1 --shot main _qa/main.png # 非交互画面只截图
./Tools/run-game.ps1 --import                 # 新增 class_name / 场景 / 资源后跑一次
```

- **通过判据**：`--check` 退出码 0 且输出 `CHECK 通过 N 项 / 失败 0`；`--shot` 退出码 0 且输出 `SHOT PASS`；`--simulate` 退出码 0 且有 `SIM {...}`。**不接受"0 条断言算通过"**。
- 截图不是证据链：判断"点得动"看 `SHOT PASS` 前的交互行（`点击 指令_建造 → 指令_农场 出现`）。
- 历史自检（`Tests/suites/`）仍可用：`godot --headless --path . --script Tests/suites/配置回归.gd` 等；入口与常红项见 `Documents/索引/测试索引.md`。
- 已知常红（2026-11-14）：`配置回归` 有 2 条 "dept 默认 off" 断言失败——代码里 DEFAULT_DEPT_MODE 临时为 on（commit 607b798，待回滚），**不是新问题**。

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
- ~~目录冻结，只加导航层~~（2026-11-13 提出，**2026-11-14 作废**：用户要求按七块砖物理重排；旧方案见 `Documents/文件梳理与Agent协作方案.md`）。
- ~~`.tres` 卡是数值唯一真源~~（2C-4 起，**2026-11-14 作废**：改为 JSON，原因：agent 可读可 diff、与 C# 内核解耦、不被 Resource 脚本绑定）。
- ~~用 `res://配置/游戏配置.tres` 覆盖全局配置~~（**2026-11-14 作废**：改 `Content/data/game.json`）。
- ~~AI 诉求系数以 `.tres` 为备份/展示真源~~（**2026-11-14 作废**：改 `Content/data/ai_demand.json`）。

### 建议（待试玩确认）

- **副官接管范围**：建造/训练/采集默认接管，战斗只给建议；玩家一键"夺回控制"。——方向已定，覆盖比例与默认开关待试玩。
- **一局时长**：目标 10~15 分钟；肉鸽层数/词条数量待定。
- **手机操作**：默认自动施法 + 面板化指令，减少精确点选；低端机降级项（阴影/单位数）待实测。
- **C# 内核**：`net8.0` 纯类库 + xunit，Godot 只留 Adapter；参考 YokiFrame 的工程分层，不整体引入 QFramework（见 `Documents/topics/qframework-assessment.md`）。
- **数值基线**：镜像推演 5 局 2:3 只作地基 smoke，不能当平衡结论；调数值前先跑 10 分钟长局。

### 待决定

- 正式英文名 / 商店名。
- `--dept` 默认值回滚时间（当前临时 on，见 607b798）。
- Steam / 手机平台 SDK 的接入顺序与账号方案。
- 云存档策略（本地槽位已就绪，云端适配器未接）。
- 旧 `Game/` 玩法层拆进 Model 的顺序（建议先下沉"命令卡/建筑可用性判断"，再拆 AI 纯函数）。
- 是否保留 4 队混战为默认对局。

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
