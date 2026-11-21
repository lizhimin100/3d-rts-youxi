# 战争原岛

**单通道 3D 长横道 + 规划阶段打牌/建造/升星三合一 + 90 秒攻防双场小队自动推进与局部微操**。
Godot 4.7 宿主 + **纯 C# 规则内核**（`Model/`，net8.0，零 Godot）。目标平台 **Steam + 低中端手机**。

> 工程约定与 AI 协作规则见 **[AGENTS.md](AGENTS.md)**；设计真相见 **[Documents/concept.md](Documents/concept.md)**；
> 战斗与距离换算见 **[Documents/combat_formula.md](Documents/combat_formula.md)**。
> 2026-11-20 完成转型：`Views/` → `Screens/`，`Model/` 改为纯 C#，旧 RTS 的 AI / 迷雾 / 采集 / 全图寻路 / 读条队列全部剥离。

---

## 一、怎么跑

```powershell
./Tools/run-game.ps1 --import     # 新克隆/新增资源后扫一遍（会自动 dotnet build）
./Tools/run-game.ps1              # 正常启动（规划阶段 → 执行阶段）
```

`run-game` 会先 `dotnet build 战争原岛.csproj`（增量约 1~2 秒），再启动 Godot。

找 Godot 的顺序：`$env:GODOT_BIN` → 本机已知安装路径 → PATH。想固定版本：`$env:GODOT_BIN = 'D:\Godot\godot.exe'`。

---

## 二、操作

| 操作 | 键位 |
|---|---|
| 选择单个单位 / 框选 | **左键单击** / **左键拖拽** |
| 加选 / 减选 | **Shift + 左键** / **Ctrl + 左键** |
| 移动 / 攻击（上下文指令） | **右键** |
| 攻击移动 | **F** 然后左键点地 |
| 停止 / 原地警戒 | **X** / **H** |
| 释放技能 | **Q / 1** |
| 规划阶段部署（进攻/防守/占据） | 底部面板按钮 → 地图落点 |
| 规划结束 / 取消 | 右下【规划结束】/【取消】 |
| 镜头平移 / 旋转 / 缩放 / 回中 | 方向键·WASD·边缘 / Q·E / 滚轮 / 空格 |
| 小地图跳转 | 小地图上左键点击/拖动 |

**胜负**：执行阶段撑满回合 / 清掉波次；大本营被拆则失败。

---

## 三、当前实现

- **两阶段**：规划阶段世界完全暂停（布阵、建造、升星、排命令）；执行阶段实时推进。
- **资源**：局内只认 **CP + 人口**；金币/木材只作局外长线账本（升星/改造）。
- **兵种**：农民（工程兵）/ 步兵 / 弓箭手 / 法师 / 矮人火枪手 / 破法者 / 魔金傀儡；野怪有豺狼人三系。
- **建筑**：大本营、兵营、铁匠铺、农场、箭塔、哨塔、神秘圣地、蒸汽车坊、伐木场、营火、联盟要塞。
- **护甲/伤害**：普通 / 穿刺 / 魔法 / 攻城 × 轻甲 / 重甲 / 中甲 / 城甲 / 无甲，克制表在 `Content/data/game.json`，公式在 C# `Model/Core/Damage.cs`。
- **敌军**：`Game/core/回合控制.gd` 按波次脚本生成并下令（旧的经济 AI 已删除）。
- **地图**：单通道竞技场（224m），含野怪营地、日夜；地图编辑器在 `addons/map_editor`。

> 数值与内容全在 **[Content/data](Content/data)**；改数值不用改代码，见 **[Documents/data-pipeline.md](Documents/data-pipeline.md)**。

---

## 四、工程结构

```
Engine/     自研引擎层：启动/存档/多语言/音频/对话/平台/调试接口（pin.json 锁定）
Model/      纯 C# 规则内核：R1 换算、伤害、经济、成长、可用性、确定性推演（零 Godot）
Screens/    3D 表现与输入：bridge/ hud/ input/ camera/ world/ scenes/
Game/       引擎耦合的玩法装配（迁移期：units/systems/map/config/core/adapters）
Content/    data/（JSON 唯一数值源）i18n/ keys/ art/ audio/ maps/ legacy/
Tests/      checks/（--check）sim/（--simulate）model/（规则用例）suites/（历史自检）
Tools/      run-game.ps1 / gen/ / build/ / qa/ migrate/
Documents/  concept.md / combat_formula.md / architecture.md / data-pipeline.md / 专题与索引
addons/     地图编辑器（不进发行版）
```

依赖方向：`Screens → Game → (Model, Engine)`；`Model` 不依赖上层、不引用 Godot；`Engine` 不依赖玩法。
详见 **[Documents/architecture.md](Documents/architecture.md)**。

---

## 五、验证（全部无窗口，静音）

```powershell
./Tools/run-game.ps1 --check                  # 体检：数据/文案/资源/分层/距离铁律/存档隔离/发行门禁/文档
./Tools/run-game.ps1 --simulate --games=100   # 第 1 关 100 局（联盟 vs 豺狼人），输出数值报告
./Tools/run-game.ps1 --shot main _qa/main.png # 离屏截图（交互画面会真点一次并验状态）
./Tools/run-game.ps1 --round-test             # 半回合自检
```

通过判据：`--check` 退出码 0 且 `CHECK 通过 N 项 / 失败 0`；`--shot` 退出码 0 且 `SHOT PASS`；
`--simulate` 退出码 0 且有 `SIM {json}`。

历史自检（`Tests/suites/`）仍可单独跑，例如：

```powershell
godot --headless --path . --script Tests/suites/战斗自检.gd
godot --headless --path . --script Tests/suites/地图生成自检.gd
```

入口见 **[Documents/索引/测试索引.md](Documents/索引/测试索引.md)**。

---

## 六、文档

- **[AGENTS.md](AGENTS.md)** —— 硬约定、验证命令、拍板记录、Git 节奏（**先读这个**）。
- **[Documents/concept.md](Documents/concept.md)** —— 设计真相（已确认 / 建议 / 待决定）。
- **[Documents/combat_formula.md](Documents/combat_formula.md)** —— R1、伤害、护甲/克制、升星。
- **[Documents/architecture.md](Documents/architecture.md)** —— 分层、数据流、迁移欠账、检查覆盖。
- **[Documents/data-pipeline.md](Documents/data-pipeline.md)** —— JSON 数据、文案、资源 key、生成器。
- **[Documents/debug-bridge.md](Documents/debug-bridge.md)** —— 127.0.0.1 调试接口。
- **[Documents/README.md](Documents/README.md)** —— 文档总入口（按任务路由）。

---

## 七、美术复现

单位/自然物由 `Tools/建模/*.py` 在 Blender 里程序化生成；建筑来自项目内资产包。

```powershell
& 'E:\tmp\blender_ok\blender.exe' -b --factory-startup --python Tools\建模\build_农民.py
```

生成 GLB 后拷进 `Content/art/模型/`，跑 `./Tools/run-game.ps1 --import`。
（本机 Blender 必须用 `E:\tmp\blender_ok\blender.exe` 这份全量副本；这是环境约束，不是设计选择。）
