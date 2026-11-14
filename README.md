# 战争原岛

用 **Godot 4.7 + GDScript** 做的 **3D 即时战略**（PvE 为主，肉鸽方向）。
核心特色是 **副官**：它替你接管建造/训练/采集这些重复操作，你只需要决定"往哪打、先打谁、什么时候撤"。
目标平台 **Steam + 低中端手机**；规则逐步迁到独立的 C# 内核。

> 工程约定与 AI 协作规则见 **[AGENTS.md](AGENTS.md)**；设计真相见 **[Documents/concept.md](Documents/concept.md)**。
> 2026-11-14 按「七块砖」完成目录重排与地基搭建，旧路径（`代码/`、`场景/`、`美术/`…）已不存在。

---

## 一、怎么跑

先让 Godot 扫一遍资源（新克隆 / 新增模型后）：

```powershell
./Tools/run-game.ps1 --import
```

正常启动（有窗口，直接玩）：

```powershell
./Tools/run-game.ps1
# 或者：godot --path .
```

脚本找 Godot 的顺序：`$env:GODOT_BIN` → 本机已知安装路径 → PATH 里的 `godot`。
想固定版本：`$env:GODOT_BIN = 'D:\Godot\godot.exe'`。

---

## 二、操作（魔兽争霸 3 手感）

| 操作 | 键位 |
|---|---|
| 选择单个单位 | **左键单击** |
| 框选（只框自己的单位） | **左键拖拽** |
| 加选 / 减选 | **Shift + 左键** / **Ctrl + 左键** |
| 选中屏幕上所有同类单位 | **双击** |
| 移动 / 攻击 / 采集（上下文指令） | **右键** |
| 攻击移动 | **F** 然后左键点地 |
| 停止 / 原地警戒 | **X** / **H** |
| 释放技能 | **Q / 1** |
| 建造菜单 / 建筑转向 | **B** / 放置时 **R**（Shift+R 反向） |
| 研究升级（铁匠铺） | 选中铁匠铺 → 命令卡「武器锻造 / 护甲锻造」 |
| 镜头平移 | **方向键 / WASD / 鼠标怼到屏幕边缘** |
| 镜头旋转 | **Q / E** 或按住鼠标中键拖拽 |
| 镜头缩放 | **鼠标滚轮** |
| 镜头回中 | **空格** |
| 小地图跳转 | 小地图上左键点击/拖动 |

**胜负**：摧毁敌方「大本营」→ 胜利；自己的大本营被拆 → 失败。结束后点「重新开始」重开一局。

---

## 三、玩法系统（当前实现）

- **资源**：金币（金矿）+ 木材（树木）；农民往返采集，资源会真实消耗与枯竭。
- **人口**：大本营 +24，农场 +8；人口满不能造兵。
- **兵种**：农民 / 步兵 / 弓箭手 / 法师 / 矮人火枪手 / 破法者 / 魔金傀儡；野怪有豺狼人三系。
- **建筑**：大本营、兵营、铁匠铺、农场、箭塔、哨塔、神秘圣地、蒸汽车坊、伐木场、营火、联盟要塞。
- **护甲/伤害**：普通 / 穿刺 / 魔法 / 攻城 × 轻甲 / 重甲 / 中甲 / 城甲 / 无甲，克制表在 `Content/data/game.json`。
- **AI 与副官**：AI 会采集、造农场、按兵种配比出兵、集结成波；副官替玩家做同类决策，并在界面给建议。
- **地图**：4 队竞技场（224m），含野怪营地、日夜、据点；地图编辑器在 `addons/map_editor`。

> 数值与内容全在 **[Content/data](Content/data)**；改数值不用改代码，见 **[Documents/data-pipeline.md](Documents/data-pipeline.md)**。

---

## 四、工程结构

```
Engine/     我们自己的引擎层：启动/存档/多语言/音频/对话/平台/调试接口（共享库，pin.json 锁定）
Model/      纯逻辑：伤害、经济、生产、成长、存档 schema、确定性推演（零引擎 API）
Views/      画面与输入：hud/ input/ camera/ world/ scenes/ screens/
Game/       引擎耦合的玩法装配（迁移期：units/ai/systems/map/config/core/audio）
Content/    data/（JSON 唯一数值源）i18n/ keys/ art/ audio/ maps/ legacy/
Tests/      checks/（--check）sim/（--simulate）model/（纯逻辑用例）suites/（历史自检）
Tools/      run-game.ps1 / gen/（生成器）/ build/（发行与 Demo）/ qa/ migrate/
Documents/  concept.md（设计真相）/ architecture.md / data-pipeline.md / debug-bridge.md / 专题与索引
addons/     地图编辑器（不进发行版）
```

依赖方向：`Views → Game → (Model, Engine)`；`Model` 不依赖上层；`Engine` 不依赖玩法。
详见 **[Documents/architecture.md](Documents/architecture.md)**。

---

## 五、验证（全部无窗口，静音）

```powershell
./Tools/run-game.ps1 --check                  # 体检：数据/文案/资源/分层/存档隔离/发行门禁/文档
./Tools/run-game.ps1 --simulate --games=5     # 只用 Model 跑推演，输出数值报告
./Tools/run-game.ps1 --shot hud _qa/hud.png   # 离屏开画面 + 真点一次「建造」+ 存图
./Tools/run-game.ps1 --shot main _qa/main.png # 只截图
```

通过判据：`--check` 退出码 0 且 `CHECK 通过 N 项 / 失败 0`；`--shot` 退出码 0 且 `SHOT PASS`；
`--simulate` 退出码 0 且有 `SIM {json}`。

历史自检（`Tests/suites/`）仍可单独跑，例如：

```powershell
godot --headless --path . --script Tests/suites/配置回归.gd
godot --headless --path . --script Tests/suites/战斗自检.gd
```

入口与常红项见 **[Documents/索引/测试索引.md](Documents/索引/测试索引.md)**。
**已知常红**：`配置回归` 的 2 条 "dept 默认 off" 断言（DEFAULT_DEPT_MODE 临时为 on，commit 607b798，不是新问题）。

---

## 六、文档

- **[AGENTS.md](AGENTS.md)** —— 硬约定、验证命令、拍板记录、Git 节奏（**先读这个**）。
- **[Documents/concept.md](Documents/concept.md)** —— 设计真相（已确认 / 建议 / 待决定）。
- **[Documents/architecture.md](Documents/architecture.md)** —— 分层、数据流、迁移欠账、检查覆盖。
- **[Documents/data-pipeline.md](Documents/data-pipeline.md)** —— JSON 数据、文案、资源 key、生成器。
- **[Documents/debug-bridge.md](Documents/debug-bridge.md)** —— 127.0.0.1 调试接口与"新进程校验"。
- **[Documents/README.md](Documents/README.md)** —— 文档总入口（按任务路由）。
- **[Documents/topics/qframework-assessment.md](Documents/topics/qframework-assessment.md)** —— QFramework 评估（结论：部分借鉴，不采用）。

---

## 七、美术复现

单位/自然物由 `Tools/建模/*.py` 在 Blender 里程序化生成；建筑来自项目内资产包。
Blender 5.x 示例：

```powershell
& 'E:\tmp\blender_ok\blender.exe' -b --factory-startup --python Tools\建模\build_农民.py
```

生成脚本输出 GLB 到可写目录，再拷进 `Content/art/模型/`，跑 `./Tools/run-game.ps1 --import`。
（本机 Blender 必须用 `E:\tmp\blender_ok\blender.exe` 这份全量副本；D 盘原目录带低完整性标签，启动即零输出 exit=1。这是环境约束，不是设计选择。）
