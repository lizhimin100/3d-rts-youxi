# 本次交付的验证记录（2026-11-14）

> 环境：Godot 4.7.2.stable.mono（Windows），无头/离屏；本机沙箱写不了 `user://`（AppData），
> 测试存档走项目内 `.test_profile/`。日志里的 "Failed to read the root certificate store" 是
> 环境问题（Windows 证书库在沙箱里读不到），与游戏逻辑无关。

## 1. `./Tools/run-game.ps1 --check`

```
[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
========== 地基体检（run-game --check） ==========
  ✓ 七块砖目录齐全（Engine, Model, Views, Game, Content, Tests, Tools, Documents）  缺：
  ✓ 旧目录已清空（代码/场景/美术/音频/地图/工具/文档）  残留：
  ✓ 引擎层自动加载已注册（9 个）  缺：
  ✓ Content/data 下 JSON 全部可解析（40 个）
  ✓ 内容卡结构（单位 10 / 建筑 14 / 技能 6 / 营地 4）
WARNING: [野怪营地表] 锚点「creep_den」重复默认配置（camp_den.json 只作为 camp_id 可选）
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _reload (res://Game/config/野怪营地表.gd:77)
       [1] all (res://Game/config/野怪营地表.gd:29)
       [2] _check_refs (res://Tests/checks/check_all.gd:168)
       [3] _run (res://Tests/checks/check_all.gd:38)
  ✓ 数据引用闭环（训练/研究/技能/模型/营地/开局/推演）
  ✓ ui.csv 可装载（8 条 / 3 种语言）
  ✓ 文案两列齐全（zh+en）、无重复 key
  ✓ 代码引用的 I18n key 都有定义（8 处）
  ✓ 新界面（Views/screens）零写死中文  实测 0 处
  ✓ 旧界面写死文案不增长（预算冻结）
  ✓ 登记的 key 都指向真实文件
  ✓ 内容资产全部已登记（250 个 key）  未登记：
  ✓ Model 零引擎 API、只引用 Model 内部脚本
  ✓ 共享引擎层与 pin.json 一致（38 个文件）
  ✓ 源文件清单与磁盘一致（新增/删除要走 Tools/gen/gen_manifest.py）  新增 0（如 []）／缺失 0
  · Model 自测：通过 34 / 失败 0
  ✓ 游戏侧伤害 == Model 伤害（4×5×5 组合）  不一致：
  ✓ 游戏侧扣费 == Model 扣费  游戏 40/30 ｜ Model 40/30
  ✓ 测试模式默认开启（--check 自动）
  ✓ 存档根目录是隔离的测试目录  res://.test_profile/
  ✓ 测试档写入/读回（schema 校验后）
  ✓ 真实档案目录未被触碰（slot 路径在隔离目录下）
  ✓ 发行排除清单齐全（调试接口/测试/工具/编辑器/旧卡）  缺：
  ✓ 调试接口有发行构建门禁
  ✓ 截图画面表（2 个画面）
  ✓ AGENTS.md 存在且 <= 20KB  10893 字节
  ✓ CLAUDE.md 只有一行 @AGENTS.md  @AGENTS.md
  ✓ Documents/concept.md 三栏
---------------------------------------------------------------
CHECK 通过 62 项 / 失败 0  —— 地基体检全部通过 ✓
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=16048 | boot=16048-332
```

## 2. `./Tools/run-game.ps1 --simulate --games=5`

```
[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
========== 数值报告（只用 Model 推演，无窗口/无渲染） ==========
注意：推演不含地形/建筑/技能，只做数值回归；胜负不能直接当平衡结论。
场景：玩家 vs AI ｜ 每局上限 300s ｜ 每 30s 采样 ｜ 共 5 局
---------------------------------------------------------------
局    种子     时长       胜方       玩家 击杀/损失/出兵/采金             AI 击杀/损失/出兵/采金            
1    1      300.0    玩家       18/8/18/2142               8/18/18/2142              
2    2      300.0    AI       4/16/16/2142               16/4/15/2142              
3    3      300.0    AI       5/16/16/2142               16/5/15/2142              
4    4      300.0    玩家       17/3/14/2142               3/17/17/2142              
5    5      300.0    玩家       16/4/15/2142               4/16/16/2142              
---------------------------------------------------------------
汇总：玩家 胜 3 ｜ AI 胜 2 ｜ 平局 0 ｜ 平均时长 300.0s
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=21224 | boot=21224-291
```

（完整 `SIM {json}` 行含逐局 300 秒时间线，运行输出里可见；这里不贴，避免文档膨胀。）

## 3. 截图与交互

### 3.1 `./Tools/run-game.ps1 --shot hud _qa/final_hud.png`

```
Vulkan 1.4.303 - Forward+ - Using Device #0: NVIDIA - NVIDIA GeForce RTX 5060

[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=21460 | boot=21460-947
[Dbg] 调试接口：http://127.0.0.1:18777/ （pid=21460 boot=21460-947）
[关卡] 树：455 棵（程序化生成，网格池 10 份，关（单档，175m 外剔除））
[地图加载] 地表层：无（splatmap 全空或未铺）
[主场景] 已加载地图 res://Content/maps/主场景地图.tres（224×224，对象 525 个）
[主场景] 地图热重载已就绪：监视 res://Content/maps/主场景地图.tres
[迷雾] 已就绪：网格 128²（一格 1.75m），观察方 玩家
WARNING: [野怪营地表] 锚点「creep_den」重复默认配置（camp_den.json 只作为 camp_id 可选）
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _reload (res://Game/config/野怪营地表.gd:77)
       [1] for_den (res://Game/config/野怪营地表.gd:46)
       [2] _scan_camps (res://Game/systems/野怪营地.gd:108)
       [3] setup (res://Game/systems/野怪营地.gd:65)
       [4] _mount_camps (res://Game/systems/野怪.gd:108)
       [5] setup (res://Game/systems/野怪.gd:93)
       [6] _ready (res://Game/core/主场景.gd:208)
       [7] _run (res://Tests/checks/shot_runner.gd:55)
[野怪营地]「豺狼人巢穴（自定义）」锚点 creep_den @ (-2, -92)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_scout×1（补满 90s）
[野怪营地]「豺狼人营地」锚点 creep_den @ (-3, 89)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_scout×1（补满 90s）
[野怪营地]「失落入口营地」锚点 creep_gate @ (103, 0)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_shaman×1（补满 75s）
[野怪营地]「折壳营地」锚点 creep_shell @ (-94, -18)，阵营 豺狼人，配置 gnoll_scout×2, gnoll_warrior×2, gnoll_shaman×1（补满 75s）
[野怪营地] 识别到 4 座营地、共 14 只野怪（分帧刷，每拍最多 3 只）
[野怪] 中立阵营「豺狼人」就绪（地图上还没有野怪 —— 在编辑器里摆即可）
[副官] 保留资金 480 金 / 140 木（玩家随时能自己造一座兵营 + 农场）
[战区] 指令输入就绪：按钮 / F5 进攻 · F6 防守 · F7 占据 · F8 生产；点目标或点区域，右键取消
[主场景] 镜头=镜头 fov=52 类=res://Views/camera/魔兽镜头.gd
[主场景] 阵营：玩家(槽0/队1/4d9eff) AI·1队(槽1/队1/2ee6e6) AI·2队(槽2/队2/ff5242) AI·3队(槽3/队3/61d65c)
[主场景] 就绪：地形 32768 面，地图 224m，4 个阵营 / 3 个队，我方单位 8，敌方单位 14（节点总数 3803）
[音效] 总线：Master(0.0dB) Music(-19.0dB) SFX(-6.0dB) UI(-16.0dB) Voice(-8.0dB)
[音效] 已就绪（音频目录：res://Content/audio/）
[音效] BGM → bgm_舒缓（3.0s 等功率交叉淡化，入点 0.0s）
[AI] 接管 AI·1队（节奏 1.40s）
[AI] 扩建兵营（部门仲裁）
[AI] 接管 AI·2队（节奏 1.40s）
[AI] 补箭塔（部门仲裁，内圈 1/2）
[AI] 接管 AI·3队（节奏 1.40s）
[AI] 补箭塔（部门仲裁，内圈 2/2）
[副官] 接管 玩家（节奏 1.12s）
[副官] 扩建兵营（部门仲裁）
[野怪营地] 「豺狼人巢穴（自定义）」全灭，90 秒后补满
[野怪营地] 「豺狼人营地」全灭，90 秒后补满
[野怪营地] 「失落入口营地」全灭，75 秒后补满
[野怪营地] 「折壳营地」全灭，75 秒后补满
[副官] 目标结束 Yy001 建造·barracks（达成，释放 0 金）
[副官] 排农民（部门仲裁，现有 3）
[AI] 目标结束 Yy001 建造·barracks（达成，释放 0 金）
[AI] 排农民（部门仲裁，现有 5）
[副官] 排农民（部门仲裁，现有 3）
[AI] 排农民（部门仲裁，现有 5）
[shot] 交互通过：点击 指令_建造 → 指令_农场 出现
SHOT PASS E:\自定义游戏\简易rts\_qa\final_hud.png（hud，912875 字节）
[run-game] 截图：E:\自定义游戏\简易rts\_qa\final_hud.png
```

### 3.2 `./Tools/run-game.ps1 --shot main _qa/final_main.png`

```
Vulkan 1.4.303 - Forward+ - Using Device #0: NVIDIA - NVIDIA GeForce RTX 5060

[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=15292 | boot=15292-957
[Dbg] 调试接口：http://127.0.0.1:18777/ （pid=15292 boot=15292-957）
[关卡] 树：455 棵（程序化生成，网格池 10 份，关（单档，175m 外剔除））
[地图加载] 地表层：无（splatmap 全空或未铺）
[主场景] 已加载地图 res://Content/maps/主场景地图.tres（224×224，对象 525 个）
[主场景] 地图热重载已就绪：监视 res://Content/maps/主场景地图.tres
[迷雾] 已就绪：网格 128²（一格 1.75m），观察方 玩家
WARNING: [野怪营地表] 锚点「creep_den」重复默认配置（camp_den.json 只作为 camp_id 可选）
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _reload (res://Game/config/野怪营地表.gd:77)
       [1] for_den (res://Game/config/野怪营地表.gd:46)
       [2] _scan_camps (res://Game/systems/野怪营地.gd:108)
       [3] setup (res://Game/systems/野怪营地.gd:65)
       [4] _mount_camps (res://Game/systems/野怪.gd:108)
       [5] setup (res://Game/systems/野怪.gd:93)
       [6] _ready (res://Game/core/主场景.gd:208)
       [7] _run (res://Tests/checks/shot_runner.gd:55)
[野怪营地]「豺狼人巢穴（自定义）」锚点 creep_den @ (-2, -92)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_scout×1（补满 90s）
[野怪营地]「豺狼人营地」锚点 creep_den @ (-3, 89)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_scout×1（补满 90s）
[野怪营地]「失落入口营地」锚点 creep_gate @ (103, 0)，阵营 豺狼人，配置 gnoll_warrior×2, gnoll_shaman×1（补满 75s）
[野怪营地]「折壳营地」锚点 creep_shell @ (-94, -18)，阵营 豺狼人，配置 gnoll_scout×2, gnoll_warrior×2, gnoll_shaman×1（补满 75s）
[野怪营地] 识别到 4 座营地、共 14 只野怪（分帧刷，每拍最多 3 只）
[野怪] 中立阵营「豺狼人」就绪（地图上还没有野怪 —— 在编辑器里摆即可）
[副官] 保留资金 480 金 / 140 木（玩家随时能自己造一座兵营 + 农场）
[战区] 指令输入就绪：按钮 / F5 进攻 · F6 防守 · F7 占据 · F8 生产；点目标或点区域，右键取消
[主场景] 镜头=镜头 fov=52 类=res://Views/camera/魔兽镜头.gd
[主场景] 阵营：玩家(槽0/队1/4d9eff) AI·1队(槽1/队1/2ee6e6) AI·2队(槽2/队2/ff5242) AI·3队(槽3/队3/61d65c)
[主场景] 就绪：地形 32768 面，地图 224m，4 个阵营 / 3 个队，我方单位 8，敌方单位 14（节点总数 3803）
[音效] 总线：Master(0.0dB) Music(-19.0dB) SFX(-6.0dB) UI(-16.0dB) Voice(-8.0dB)
[音效] 已就绪（音频目录：res://Content/audio/）
[音效] BGM → bgm_舒缓（3.0s 等功率交叉淡化，入点 0.0s）
[AI] 接管 AI·1队（节奏 1.40s）
[AI] 扩建兵营（部门仲裁）
[AI] 接管 AI·2队（节奏 1.40s）
[AI] 补箭塔（部门仲裁，内圈 1/2）
[AI] 接管 AI·3队（节奏 1.40s）
[AI] 补箭塔（部门仲裁，内圈 2/2）
[副官] 接管 玩家（节奏 1.12s）
[副官] 扩建兵营（部门仲裁）
[野怪营地] 「豺狼人巢穴（自定义）」全灭，90 秒后补满
[野怪营地] 「豺狼人营地」全灭，90 秒后补满
[野怪营地] 「失落入口营地」全灭，75 秒后补满
[野怪营地] 「折壳营地」全灭，75 秒后补满
[副官] 目标结束 Yy001 建造·barracks（达成，释放 0 金）
[副官] 排农民（部门仲裁，现有 3）
[AI] 目标结束 Yy001 建造·barracks（达成，释放 0 金）
[AI] 排农民（部门仲裁，现有 5）
[副官] 排农民（部门仲裁，现有 3）
[AI] 排农民（部门仲裁，现有 5）
SHOT PASS E:\自定义游戏\简易rts\_qa\final_main.png（main，996772 字节）
[run-game] 截图：E:\自定义游戏\简易rts\_qa\final_main.png
```

## 4. 反向验证（`python Tools/checks/negative_demo.py`）

```
========== 反向验证（故意改坏 → 必须报错 → 改回 → 通过） ==========
  ✓ 卡数值非法（max_hp=-1）  → 检查失败（退出码 1）
  ✓ 数据引用断链（trains 指向不存在的兵）  → 检查失败（退出码 1）
  ✓ 文案缺 zh 列  → 检查失败（退出码 1）
  ✓ Model 出现 FileAccess  → 检查失败（退出码 1）
  ✓ Engine 被就地修改  → 检查失败（退出码 1）
  ✓ 新增源文件未登记  → 检查失败（退出码 1）
---------------------------------------------------------------
恢复后：退出码 0 ｜ CHECK 通过 62 项 / 失败 0  —— 地基体检全部通过 ✓
NEGATIVE 全部通过（6 个改坏场景都被抓到）✓
```

## 5. 调试接口验收（`./Tools/qa/bridge_probe.ps1`）

```
[bridge] 第一次启动...
[bridge] health pid=20808 boot=20808-146 test=True
[bridge] state phase=1 factions=4 units=34
[bridge] action select_all ok=True selected=8
[bridge] 第一次进程已退出
[bridge] 第二次启动（验证连到的是新进程）...
[bridge] 新进程确认：pid 20808->21452，boot 20808-146->21452-155
[bridge] BRIDGE PASS
```

## 6. 历史自检（迁移后仍通过）

| 自检 | 结果 |
|---|---|
| `Tests/suites/界面自检.gd` | 通过 8 / 失败 0 |
| `Tests/suites/建造自检.gd` | 通过 98 / 失败 0 |
| `Tests/suites/寻路自检.gd` | 通过 15 / 失败 0 |
| `Tests/suites/战斗自检.gd` | 结果：通过 |
| `Tests/suites/配置回归.gd` | 通过 280 / 失败 2（已知常红：`--dept` 默认值临时 on，commit 607b798，不是本次引入） |

## 7. 这次**没有**证明的东西

- 没有证明玩法好玩、数值平衡；`--simulate` 是抽象镜像推演（无地形/建筑/技能）。
- 没有证明手机端能跑；没有接 Steam/手机 SDK，适配器是空实现（如实返回不可用）。
- 没有证明美术/音频全部正确；只证明资源 key 全部登记且路径存在。
- 没有证明旧文档全部更新；高风险文档加了迁移横幅，路径以 `Documents/architecture.md` 为准。
- 长局/平衡结论不在这里：按 AGENTS.md 的规定跑 ≥10 分钟对照局。
