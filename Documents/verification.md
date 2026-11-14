# 本次交付的验证记录（2026-11-14 · 第二轮）

> 环境：Godot 4.7.2.stable.mono（Windows）；无头/离屏；测试存档走项目内 `.test_profile/`。
> 日志里的 `Failed to read the root certificate store` 是沙箱读不到 Windows 证书库，与游戏无关。

## 1. `./Tools/run-game.ps1 --check`（94 项）

```text
[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
========== 地基体检（run-game --check） ==========
  ✓ 七块砖目录齐全（Engine, Model, Views, Game, Content, Tests, Tools, Documents）  缺：
  ✓ 旧目录已清空（代码/场景/美术/音频/地图/工具/文档）  残留：
  ✓ 引擎层自动加载已注册（9 个）  缺：
  ✓ Content/data 下 JSON 全部可解析（40 个）
  ✓ 内容卡结构（单位 10 / 建筑 14 / 技能 6 / 营地 4）
ERROR: [JsonCodec] res://Game/config/单位卡.gd：未知字段：metadata/source_path
   at: push_error (core/variant/variant_utility.cpp:1023)
   GDScript backtrace (most recent call first):
       [0] restore (res://Engine/util/json_codec.gd:135)
       [1] load_card (res://Game/config/card_store.gd:67)
       [2] _check_card_io (res://Tests/checks/check_all.gd:206)
       [3] _run (res://Tests/checks/check_all.gd:38)
  ✓ 卡读写往返（编辑器保存路径 → JSON → 读回）  err=0
  ✓ 主场景地图能被 MapStore 读回（编辑器同一入口）
  ✓ 地图数据有效（尺寸/对象数）  size=224 objects=525
WARNING: [野怪营地表] 锚点「creep_den」重复默认配置（camp_den.json 只作为 camp_id 可选）
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _reload (res://Game/config/野怪营地表.gd:77)
       [1] all (res://Game/config/野怪营地表.gd:29)
       [2] _check_refs (res://Tests/checks/check_all.gd:172)
       [3] _run (res://Tests/checks/check_all.gd:40)
  ✓ 数据引用闭环（训练/研究/技能/模型/营地/开局/推演）
  ✓ ui.csv 可装载（23 条 / 3 种语言）
  ✓ 文案两列齐全（zh+en）、无重复 key
  ✓ 代码引用的 I18n key 都有定义（8 处）
  ✓ 新界面（Views/screens）零写死中文  实测 0 处
  ✓ 旧界面写死文案不增长（预算冻结）
  ✓ 登记的 key 都指向真实文件
  ✓ 内容资产全部已登记（250 个 key）  未登记：
  ✓ Model 零引擎 API、只引用 Model 内部脚本
  ✓ 共享引擎层与 pin.json 一致（40 个文件）
  ✓ 源文件清单与磁盘一致（新增/删除要走 Tools/gen/gen_manifest.py）  新增 0（如 []）／缺失 0
  · Model 自测：通过 54 / 失败 0
  ✓ P0：一本不能出二本兵（tier_locked）  tier_locked
  ✓ P0：升级中不能训练（upgrading）  upgrading
  ✓ P0：队列满不能训练（queue_full）  queue_full
  ✓ P0：没钱不能训练（no_gold/no_wood）  no_gold
  ✓ P0：升级中不能研究（upgrading）  upgrading
  ✓ 建筑/命令卡/指令系统走同一套可用性判断
  ✓ 合成音效器有 12 个预设  presets=12
  ✓ 合成音效可被 AudioSvc 接受（未知 key 拒绝）
  ✓ 游戏音效走 AudioStreamGenerator 映射
  ✓ 游戏侧伤害 == Model 伤害（4×5×5 组合）  不一致：
  ✓ 游戏侧扣费 == Model 扣费  游戏 40/30 ｜ Model 40/30
  ✓ 测试模式默认开启（--check 自动）
  ✓ 存档根目录是隔离的测试目录  res://.test_profile/
  ✓ 测试档写入/读回（schema 校验后）
  ✓ 真实档案目录未被触碰（slot 路径在隔离目录下）
  ✓ 发行排除清单齐全（调试接口/测试/工具/编辑器/旧卡）  缺：
  ✓ 调试接口有发行构建门禁
  ✓ 截图画面表（2 个画面）
  ✓ AGENTS.md 存在且 <= 20KB  12318 字节
  ✓ CLAUDE.md 只有一行 @AGENTS.md  @AGENTS.md
  ✓ Documents/concept.md 三栏
---------------------------------------------------------------
CHECK 通过 94 项 / 失败 0  —— 地基体检全部通过 ✓
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=23564 | boot=23564-350
```

## 2. `./Tools/run-game.ps1 --simulate --games=5`

```text
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
SIM {"avg_seconds":300.0,"games":5,"ok":true,"results":[{"ok":true,"seconds":300.0,"seed":1,"sides":[{"alive":10,"alive_by_type":{"archer":3,"footman":7},"built_by_type":{"archer":6,"footman":12},"damage_dealt":6939.0,"gold_left":507,"gold_mined":2142,"hp_left":3489.0,"kills":18,"losses":8,"name":"玩家","units_built":18},{"alive":0,"alive_by_type":{},"built_by_type":{"archer":5,"dwarf_musketeer":1,"footman":12},"damage_dealt":3052.0,"gold_left":472,"gold_mined":2142,"hp_left":0.0,"kills":8,"losses":18,"name":"AI","units_built":18}],"timeline":[{"gold":[515,515],"hp":[0.0,0.0],"t":0.1,"units":[0,0]},{"gold":[604,604],"hp":[166.0,136.0],"t":30.0,"units":[1,1]},{"gold":[588,588],"hp":[535.0,485.0],"t":60.0,"units":[3,3]},{"gold":[572,572],"hp":[656.0,604.0],"t":90.0,"units":[3,3]},{"gold":[537,537],"hp":[724.0,597.0],"t":120.0,"units":[3,2]},{"gold":[541,506],"hp":[949.0,615.0],"t":150.0,"units":[4,3]},{"gold":[630,595],"hp":[953.0,0.0],"t":180.0,"units":[5,0]},{"gold":[595,560],"hp":[1598.0,3.0],"t":210.0,"units":[6,1]},{"gold":[559,524],"hp":[2241.0,0.0],"t":240.0,"units":[8,0]},{"gold":[523,488],"hp":[2921.0,0.0],"t":270.0,"units":[8,0]},{"gold":[507,472],"hp":[3489.0,0.0],"t":300.0,"units":[10,0]}],"winner":"玩家"},{"ok":true,"seconds":300.0,"seed":2,"sides":[{"alive":0,"alive_by_type":{},"built_by_type":{"archer":8,"footman":6,"mage":2},"damage_dealt":1448.0,"gold_left":497,"gold_mined":2142,"hp_left":0.0,"kills":4,"losses":16,"name":"玩家","units_built":16},{"alive":11,"alive_by_type":{"archer":5,"dwarf_musketeer":2,"footman":4},"built_by_type":{"archer":7,"dwarf_musketeer":3,"footman":5},"damage_dealt":5462.0,"gold_left":982,"gold_mined":2142,"hp_left":3501.0,"kills":16,"losses":4,"name":"AI","units_built":15}],"timeline":[{"gold":[515,515],"hp":[0.0,0.0],"t":0.1,"units":[0,0]},{"gold":[604,604],"hp":[151.0,121.0],"t":30.0,"units":[1,1]},{"gold":[488,573],"hp":[387.0,444.0],"t":60.0,"units":[3,3]},{"gold":[577,522],"hp":[0.0,917.0],"t":90.0,"units":[0,4]},{"gold":[462,597],"hp":[0.0,1038.0],"t":120.0,"units":[0,4]},{"gold":[446,581],"hp":[255.0,1698.0],"t":150.0,"units":[1,5]},{"gold":[535,670],"hp":[0.0,1850.0],"t":180.0,"units":[0,6]},{"gold":[540,675],"hp":[0.0,2418.0],"t":210.0,"units":[0,8]},{"gold":[544,679],"hp":[0.0,2911.0],"t":240.0,"units":[0,9]},{"gold":[508,768],"hp":[254.0,3553.0],"t":270.0,"units":[1,11]},{"gold":[497,982],"hp":[0.0,3501.0],"t":300.0,"units":[0,11]}],"winner":"AI"},{"ok":true,"seconds":300.0,"seed":3,"sides":[{"alive":0,"alive_by_type":{},"built_by_type":{"archer":8,"footman":6,"mage":2},"damage_dealt":2003.0,"gold_left":617,"gold_mined":2142,"hp_left":0.0,"kills":5,"losses":16,"name":"玩家","units_built":16},{"alive":10,"alive_by_type":{"archer":3,"dwarf_musketeer":3,"footman":4},"built_by_type":{"archer":5,"dwarf_musketeer":4,"footman":6},"damage_dealt":5533.0,"gold_left":927,"gold_mined":2142,"hp_left":3145.0,"kills":16,"losses":5,"name":"AI","units_built":15}],"timeline":[{"gold":[515,515],"hp":[0.0,0.0],"t":0.1,"units":[0,0]},{"gold":[604,604],"hp":[166.0,151.0],"t":30.0,"units":[1,1]},{"gold":[588,588],"hp":[551.0,543.0],"t":60.0,"units":[3,3]},{"gold":[472,522],"hp":[514.0,577.0],"t":90.0,"units":[2,2]},{"gold":[582,632],"hp":[0.0,564.0],"t":120.0,"units":[0,3]},{"gold":[446,581],"hp":[80.0,1110.0],"t":150.0,"units":[1,5]},{"gold":[555,690],"hp":[0.0,1379.0],"t":180.0,"units":[0,6]},{"gold":[540,640],"hp":[0.0,1958.0],"t":210.0,"units":[0,6]},{"gold":[524,624],"hp":[0.0,2585.0],"t":240.0,"units":[0,8]},{"gold":[508,713],"hp":[0.0,3165.0],"t":270.0,"units":[0,10]},{"gold":[617,927],"hp":[0.0,3145.0],"t":300.0,"units":[0,10]}],"winner":"AI"},{"ok":true,"seconds":300.0,"seed":4,"sides":[{"alive":11,"alive_by_type":{"archer":4,"footman":5,"mage":2},"built_by_type":{"archer":6,"footman":6,"mage":2},"damage_dealt":6110.0,"gold_left":932,"gold_mined":2142,"hp_left":3309.0,"kills":17,"losses":3,"name":"玩家","units_built":14},{"alive":0,"alive_by_type":{},"built_by_type":{"archer":8,"dwarf_musketeer":2,"footman":7},"damage_dealt":1324.0,"gold_left":642,"gold_mined":2142,"hp_left":0.0,"kills":3,"losses":17,"name":"AI","units_built":17}],"timeline":[{"gold":[515,515],"hp":[0.0,0.0],"t":0.1,"units":[0,0]},{"gold":[604,624],"hp":[166.0,166.0],"t":30.0,"units":[1,1]},{"gold":[588,608],"hp":[553.0,221.0],"t":60.0,"units":[3,1]},{"gold":[572,592],"hp":[1151.0,281.0],"t":90.0,"units":[4,1]},{"gold":[557,702],"hp":[1498.0,0.0],"t":120.0,"units":[5,0]},{"gold":[666,686],"hp":[1760.0,0.0],"t":150.0,"units":[5,0]},{"gold":[550,655],"hp":[2239.0,0.0],"t":180.0,"units":[7,0]},{"gold":[540,730],"hp":[2458.0,0.0],"t":210.0,"units":[8,0]},{"gold":[504,694],"hp":[3034.0,0.0],"t":240.0,"units":[10,0]},{"gold":[718,658],"hp":[3365.0,0.0],"t":270.0,"units":[11,0]},{"gold":[932,642],"hp":[3309.0,0.0],"t":300.0,"units":[11,0]}],"winner":"玩家"},{"ok":true,"seconds":300.0,"seed":5,"sides":[{"alive":11,"alive_by_type":{"archer":5,"footman":5,"mage":1},"built_by_type":{"archer":6,"footman":8,"mage":1},"damage_dealt":5602.0,"gold_left":907,"gold_mined":2142,"hp_left":3435.0,"kills":16,"losses":4,"name":"玩家","units_built":15},{"alive":0,"alive_by_type":{},"built_by_type":{"archer":6,"dwarf_musketeer":4,"footman":6},"damage_dealt":1731.0,"gold_left":697,"gold_mined":2142,"hp_left":0.0,"kills":4,"losses":16,"name":"AI","units_built":16}],"timeline":[{"gold":[515,515],"hp":[0.0,0.0],"t":0.1,"units":[0,0]},{"gold":[604,624],"hp":[166.0,166.0],"t":30.0,"units":[1,1]},{"gold":[568,588],"hp":[649.0,337.0],"t":60.0,"units":[3,2]},{"gold":[572,592],"hp":[861.0,399.0],"t":90.0,"units":[4,3]},{"gold":[562,667],"hp":[927.0,0.0],"t":120.0,"units":[4,0]},{"gold":[546,616],"hp":[1418.0,59.0],"t":150.0,"units":[5,1]},{"gold":[510,600],"hp":[1995.0,244.0],"t":180.0,"units":[7,1]},{"gold":[515,710],"hp":[2595.0,0.0],"t":210.0,"units":[9,0]},{"gold":[479,659],"hp":[3160.0,0.0],"t":240.0,"units":[10,0]},{"gold":[693,608],"hp":[3468.0,0.0],"t":270.0,"units":[11,0]},{"gold":[907,697],"hp":[3435.0,0.0],"t":300.0,"units":[11,0]}],"winner":"玩家"}],"seed_base":1,"wins":{"AI":2,"玩家":3}}
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=23736 | boot=23736-301
```

## 3. 截图与交互

### 3.1 `--shot hud`（真点一次「建造」并验证建造页出现）

```text
[shot] 交互通过：点击 指令_建造 → 指令_农场 出现
SHOT PASS E:\自定义游戏\简易rts\_qa\final2_hud.png（hud，914215 字节）
[run-game] 截图：E:\自定义游戏\简易rts\_qa\final2_hud.png
```

### 3.2 `--shot main`

```text
SHOT PASS E:\自定义游戏\简易rts\_qa\final2_main.png（main，996694 字节）
[run-game] 截图：E:\自定义游戏\简易rts\_qa\final2_main.png
```

## 4. 程序化音效自检（AudioStreamGenerator）

```text
[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
[Platform] 平台 = headless（可用=true）
========== 程序化音效自检（synth_probe） ==========
-- 预设清单 --
  ui_click    0.070s  peak 0.650   3087 样本  1 层  head 0.00000 tail 0.00000
  ui_open     0.220s  peak 0.750   9702 样本  1 层  head 0.00000 tail 0.00000
  ui_error    0.300s  peak 0.700  13230 样本  2 层  head 0.00000 tail 0.00000
  notify      0.400s  peak 0.800  17640 样本  2 层  head 0.00000 tail 0.00000
  build_start 0.420s  peak 0.800  18522 样本  1 层  head 0.00000 tail 0.00000
  build_done  0.600s  peak 0.800  26460 样本  4 层  head 0.00000 tail 0.00000
  hit_flesh   0.180s  peak 0.800   7938 样本  1 层  head 0.00000 tail 0.00000
  hit_metal   0.260s  peak 0.750  11466 样本  1 层  head 0.00000 tail 0.00000
  arrow_shot  0.160s  peak 0.700   7056 样本  1 层  head 0.00000 tail 0.00000
  death       0.750s  peak 0.800  33075 样本  2 层  head 0.00000 tail 0.00000
  level_up    0.780s  peak 0.800  34398 样本  5 层  head 0.00000 tail 0.00000
  coin        0.340s  peak 0.750  14994 样本  2 层  head 0.00000 tail 0.00000
[synth] generator: mix_rate=44100 buffer=1.0s avail=65535 pushed=3087
WARNING: [Synth] 没有这个音效 key：no_such_synth_key
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] play (res://Engine/audio/synth_player.gd:45)
       [1] _check_player (res://Tests/checks/synth_probe.gd:206)
       [2] _run (res://Tests/checks/synth_probe.gd:45)
[Boot] 战争原岛 v0.1.0 | 模式=test | 存档=test | 音频=静音 | Godot=4.7.2-stable (official) | pid=3464 | boot=3464-168
SYNTH PASS 175/175
```

## 5. 历史自检 / 编辑器 / 接口

- `Tests/suites/配置回归.gd`：通过=282 失败=0 结果=通过（dept=on 已转正，原 2 条常红转绿）
- `Tests/suites/界面自检.gd`：通过 8 / 失败 0
- `Tests/suites/建造自检.gd`：通过 98 / 失败 0

编辑器打开原地图（插件自己的 QA 入口）：

```text
[地图编辑器] QA 打开 res://Content/maps/主场景地图.tres → 成功
```

编辑器链路自检：

```text
ERROR: Could not open 'user://' directory: 'user://'.
   at: _get_and_create_snapshot_storage_dir (modules/objectdb_profiler/editor/objectdb_profiler_panel.cpp:157)
[   0% ] [90m[1mfirst_scan_filesystem[22m | Started 项目初始化 (5 steps)[39m[0m
[   0% ] [90m[1mfirst_scan_filesystem[22m | 正在扫描文件结构……[39m[0m
WARNING: Detected another project.godot at res://dist/demo. The folder will be ignored.
   at: _should_skip_directory (editor/file_system/editor_file_system.cpp:3497)
[  16% ] [90m[1mfirst_scan_filesystem[22m | 正在加载全局类名……[39m[0m
[  33% ] [90m[1mfirst_scan_filesystem[22m | 正在校验 GDExtension……[39m[0m
[  50% ] [90m[1mfirst_scan_filesystem[22m | 正在创建自动加载脚本……[39m[0m
[  66% ] [90m[1mfirst_scan_filesystem[22m | 正在初始化插件……[39m[0m
[卡校验] 通过（卡 24 张，问题 0，词表错误 0）；系数卡 通过（1 张，问题 0）
WARNING: [野怪营地表] 锚点「creep_den」重复默认配置（camp_den.json 只作为 camp_id 可选）
   at: push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _reload (res://Game/config/野怪营地表.gd:77)
       [1] all (res://Game/config/野怪营地表.gd:29)
       [2] _refresh_camps (res://addons/map_editor/停靠面板.gd:989)
       [3] _sync_all (res://addons/map_editor/停靠面板.gd:1512)
       [4] setup (res://addons/map_editor/停靠面板.gd:133)
       [5] _enter_tree (res://addons/map_editor/插件.gd:32)
[  83% ] [90m[1mfirst_scan_filesystem[22m | 正在启动文件扫描……[39m[0m
[92m[ DONE ][39m [1mfirst_scan_filesystem[22m
[0m
========== 编辑器链路自检 ==========
[   0% ] [90m[1mloading_editor_layout[22m | Started 正在加载编辑器 (5 steps)[39m[0m
[   0% ] [90m[1mloading_editor_layout[22m | 正在加载编辑器布局……[39m[0m
[  16% ] [90m[1mloading_editor_layout[22m | 正在加载停靠面板……[39m[0m
[  33% ] [90m[1mloading_editor_layout[22m | 正在重新打开场景……[39m[0m
[  50% ] [90m[1mloading_editor_layout[22m | 正在加载中央编辑器布局……[39m[0m
[  66% ] [90m[1mloading_editor_layout[22m | 正在加载插件窗口布局……[39m[0m
[  83% ] [90m[1mloading_editor_layout[22m | 编辑器布局就绪。[39m[0m
[92m[ DONE ][39m [1mloading_editor_layout[22m
[0m
  · Dock 是否在前台：true（current_tab=3）
  · Dock：(330.0, 505.0) ｜ 7 页 ｜ 当前页尺寸 (310.0, 456.0)
  · 编辑器主题：res://addons/map_editor/编辑器主题.tres（Tree/ItemList/Button 已入主题）
  · 撤销历史面板：Tree（2 列）
  · 装饰目录：12 项，全部来自自然白名单/目录，无单位/建筑
  · 抬升笔刷：2.01 → 11.61 m
  · 撤销回到笔刷前：2.01 m
  · 重做回到笔刷后：11.61 m
  · 历史栈：1 步 · 当前 0 · 名称「地形：抬升（半径 12m）」
  · 历史跳转：跳初始 2.01 / 跳回 11.61
  · 建筑网格：任意点 → (3.0, -8.0) 整格锚点，幂等
  · 建筑朝向：0.77 rad → 0°（90° 档）
  · 放对象 + 撤销：71 → 72 → 71
  · 摆放归属：选中玩家 2 → 放下的兵 owner=1
  · 摆放归属：资源保持中立（owner=-1）
  · 摆放归属：野怪可中立 / 普通兵不可中立
  · 摆放归属：摆下来的野怪 owner=-1（进图归中立阵营）
  · 队伍预设（各自为战）：队伍 1：玩家1　｜　队伍 2：玩家2
  · 队伍预设（全同盟）：队伍 1：玩家1、玩家2
  · 存盘 → 读回：73 对象 / 16641 格高度
  · 点击弹窗：营地 / 单位卡 / 建筑卡 / 技能卡 / 帮助 五扇窗都能打开
  · 校验：0 错误
编辑器链路自检：全部通过（24 项）
ERROR: Cannot save file 'C:/Users/Administrator/AppData/Roaming/Godot/editor_settings-4.7.tres'.
   at: save (scene/resources/resource_format_text.cpp:1768)
ERROR: Error saving editor settings to C:/Users/Administrator/AppData/Roaming/Godot/editor_settings-4.7.tres
   at: save (editor/settings/editor_settings.cpp:1525)
```

调试接口（含“重启后确认是新进程”）：

```text
[bridge] 第一次启动...
[bridge] health pid=24372 boot=24372-148 test=True
[bridge] state phase=1 factions=4 units=34
[bridge] action select_all ok=True selected=8
[bridge] 第一次进程已退出
[bridge] 第二次启动（验证连到的是新进程）...
[bridge] 新进程确认：pid 24372->24080，boot 24372-148->24080-151
[bridge] BRIDGE PASS
```

## 6. 反向验证（故意改坏 → 必须报红 → 改回 → 通过）

```text
========== 反向验证（故意改坏 → 必须报错 → 改回 → 通过） ==========
  ✓ 卡数值非法（max_hp=-1）  → 检查失败（退出码 1）
  ✓ 数据引用断链（trains 指向不存在的兵）  → 检查失败（退出码 1）
  ✓ 文案缺 zh 列  → 检查失败（退出码 1）
  ✓ Model 出现 FileAccess  → 检查失败（退出码 1）
  ✓ Engine 被就地修改  → 检查失败（退出码 1）
  ✓ 新增源文件未登记  → 检查失败（退出码 1）
---------------------------------------------------------------
恢复后：退出码 0 ｜ CHECK 通过 94 项 / 失败 0  —— 地基体检全部通过 ✓
NEGATIVE 全部通过（6 个改坏场景都被抓到）✓
```

## 7. 这轮修掉的已知问题

- 地图编辑器打不开原地图（`不是 MapDef`）：`MapStore.load_tres` 先 `CACHE_MODE_IGNORE` 重读，再逐字段兜底；编辑器 QA 现在输出“打开 → 成功”。
- 一本就能出矮人火枪手：命令卡 state 与指令系统都改走 `Model/core/可用性.gd`，`tier_locked` 生效。
- 升二本读条期间还能训练/研究：可用性判断统一包含 `upgrading`，UI 与指令同时拦住。
- `--dept=on` 转正：配置回归从 280/2 → 282/0。
- 音效不再依赖 wav/ogg：`AudioSvc` + `音效管理` 走 AudioStreamGenerator（音乐/语音仍文件）。

## 8. 仍然没有证明的东西

- 没有证明玩法好玩/数值平衡；`--simulate` 是抽象镜像推演（无地形/建筑/技能）。
- 没有证明手机端能跑；Steam/手机适配器是空实现。
- 没有证明所有旧 UI 都迁到 i18n；存量仍按预算冻结。
- 没有完成 `Game/` 全量迁移：本轮只下沉了“可用性”这一刀；单位状态机/技能结算/AI 仍在 `Game/`。
- 地图编辑器截图在无头模式下拿不到视口图像；但“打开地图”本身已验证成功。
