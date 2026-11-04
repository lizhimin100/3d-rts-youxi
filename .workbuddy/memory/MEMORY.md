# 简易 RTS · 项目长期总结（唯一维护版）

> 只精炼这一份，不新建分轮总结。定位：**手游 RTS**，稳定 > 好看，不做 3A 材质。
> 每轮踩坑细节写 `.workbuddy/memory/YYYY-MM-DD.md`；这里只留**长期有效的结论**。

## 0. 铁律（违反必回退）

- **每轮交付完立刻 `git add -A && git commit`**（中文 + feat/fix/art/chore），也见 `AGENTS.md`。
- 建筑材质只走 StandardMaterial3D；图集 **NEAREST + 无 mipmap**；地板 UV 已烘焙，运行时不改网格。
- 地表层 **UNSHADED + 偏移 0.22m + 5 档色带 + alpha 0.93**。
- **read 对 >50KB 静默截断**：分段读（≤400 行），绝不整文件 read→write。
- `--quit-after / --resolution` 是**引擎参数**，必须在 `--` 之前；`--quit-after` 是**帧数**。
- 新加 `class_name` 后先 `--headless --path . --import`。
- 小地图圆盘裁剪用 `VERTEX` 判圆，不能用 `UV`；迷雾关掉不画遮罩。
- 外部 wav 先验头：`xxd -l 64` 看 `RIFF`/`data`；`0xFFFFFFFF` 会让导入器死循环卡编辑器。
- `美术/模型/*.png` 不能乱删：glTF 抽出的 `<模型>_<材质>_albedo/normal.png` 被 `.scn` 依赖。
- **`Panel` 不按子节点算最小尺寸**：放进 HBox 宽度恒 0 → 用 `PanelContainer`。
- `Spec.icon()` 返回 `Control` 外壳，换图走 `Spec.set_icon()`；不能进 `Array[TextureRect]`。

## 1. 环境 / 自检

- Godot 4.7.2：`E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.cmd`
- Blender 只用 `E:\tmp\blender_ok\blender.exe`（D 盘 ACL 异常，exit=1 零输出）。
- 自检：`--script 代码/测试/界面自检.gd`（8）、`建造自检.gd`（23）、`科技与后勤自检.gd`（26）、
  `-- --autotest`（全流程）、`-- --qa-terrain`、`-- --map-editor-test`（159）、
  `--headless --editor -- --map-editor-selftest`（21）、`-- --qa-combat`。
- 截图：`-- --shot=<png> --shot-delay=N --quit-after-shot`；固定机位 `--cam=x,y,z --cam-dist=N`
  （别单用 `--cam-dist`，鼠标进窗口边缘会漂）。`--select-id=<id|中文>`、`--qa-single`、
  `--qa-train=footman,archer`、`--qa-hover=<节点名>`。
- 编辑器截图：`--editor -- --map-editor-shot=<绝对路径> --map-editor-shot-demo
  --map-editor-shot-tab=对象`（必须 Windows 绝对路径）。
- 主题重生成：`--headless --path . --script 工具/生成编辑器主题.gd`（改 `界面规格.gd` 必跑）。

## 2. 地形

- 每格双三次 Hermite 片（跨格 C¹），法线解析求，UV 世界参数化，曲率自适应细分；
  **`SURFACE_TOL` 0.10**（0.05 = 13 万面/2.5s），编辑器拖动传 0.55。误差 0.0376m。
- **魔兽 3 式地块**：8m 地块、二选一、硬边；`mat_map` = R8、(cells+1)²，1 texel = 1 格点，
  `texelFetch` 不插值；`atlas_草泥_rgba.png` = 左 4×4 过渡格（德布鲁因环）+ 右 4×4 变体。
  `.import` 必须 mipmaps=true + Lossless；材质要 `duplicate()`。
- 顶点色 rgb 只在 1.0 附近乘法染色（±3.5%、营地 -8%、陡面偏灰），a = 干度，逐顶点求。
- **出生平台严格水平**：`footprint_height_range(pos, 9×5) == 0.0000`；平台 25m + 过渡 48m；
  噪声只用四重旋转对称，别再叠台地/坡道/岩脊。
- 边缘 `_flatten_border(3)` + `_build_skirt()` 下拉 `max(18, size*0.12)`；远景山脊按 `size` 等比。

## 3. 多队 / 中立

- 判据只有 `RtsFaction.team`（1 起，**0 = 中立敌对**）；`is_ally_of/is_enemy_of` 唯一出口；
  遍历一律 `Game.enemies_of/living_enemies_of`；胜负 `Game.all_enemies_defeated()`。
- `MapGenerator.build_arena`：4 角出生（45° 起）、土路环 + 对角穿中心、金矿每基地 2 座。
- 默认 `match_team_of_slot=[1,1,2,3]`；显示色唯一出口 `Cfg.display_color_for_slot()`。
- 野怪（tribe 材质）：豺狼人战士/斥候 + 地牢；`代码/系统/野怪.gd` 管刷怪与夜晚总攻。
  `代码/美术/调色板.gd` 必须有 `tribe`（默认 `#8C3A2A`），否则 `M_tribe` 掉 fallback 变灰。

## 4. 建筑基础

- `美术/铁誓军团_资产包_v1` 近/中/远 GLB；LOD 46m/96m（7m 回差）；ORM：R=AO(0.42)/G=粗糙/B=金属；
  自发光 ×0.85，底色 0.02；只抬 `BUILDING_LIFT=0.06`。
- **网格唯一入口 `代码/单位/建筑网格.gd`**：1m 格，偶数吸格线、奇数吸格心；建筑禁止缩放。
- **朝向唯一出口 `建筑网格.DEFAULT_YAW = -PI`**；R 键旋转已停用。
- 受击：单位暖橙 ADD 0.18 + 0.12s 顿挫；建筑不整面泛白，只走尘土/裂缝/顿挫。
  视觉反馈走 `RtsUnit.hit_flash()`，必须**当帧**触发（延迟=事件队列攒帧）。
- 8 座自建：农场/兵营/箭塔/哨塔/铁匠铺/神秘圣地/蒸汽车坊/伐木场；开局每基地 +农场 +哨塔。
- 图标：`工具/渲染建筑图标.py` → `美术/图标/建筑/<id>.png`；`界面规格.building_icon(id)`
  唯一出口（建造栏 42px、面板 52px）；`命令卡._icon_tex` 先 png 后 svg。

## 5. 建筑功能口径

- **伐木场 = 木材交汇点**：`UnitDef.dropoff_kinds=[WOOD]`（空 = 金木全收）；
  `_nearest_dropoff(kind)` 里**专收该类资源的交汇点优先**。
- 伐木场研究：`wood_haul`（运回木材 +50%，`_deposit_carry` ×1.5）、`repair_tech`（修理耗木 ×0.5）。
- 铁匠铺研究：`attack_up / armor_up` = **平铺 +1/级、最高 5 级**，只作用于
  `UPGRADE_TARGETS=[footman, archer]`；伤害加在 base 上；`attack_mult/armor_mult` 只剩 AI 估算。
- 修理：`RtsBuilding.repair_step()` 每秒回 2.2% 最大血、每点血 0.02 木（浮点零头累加），
  多农民叠加；`Order.REPAIR=10`；右键己方掉血建筑**优先修理**；命令卡给农民「修理」格。
- 塔分工：**哨塔无攻击**（攻/射程/索敌全 0）、视野 20 / 预警 26；
  **箭塔有攻击**（22 伤 / 13m）但视野只有 12。

## 6. 美术 / 材质

- 文生 3D 自然物 albedo 纯灰度 → `代码/美术/自然材质.gd`，材质名带 `自然_`。
- 单位走 `MatKit` 卡通 shader + `M_<zone>`；`GAIN_PROP .94/AO .55/RIM .10`、
  `GAIN_CHAR 1.12/AO .30/RIM .20`，角色 `emission = base × 0.16`；`is_char` 要进缓存 key。
- **方块人（步兵/农民/弩兵）** 走 `WarbandStyle`（与建筑同一套染色），**不过 MatKit**；
  材质 主体/team/team_trim。★ `_make("main")` 的 `metallic=1.0` 只在有 ORM 图时成立；
  无 ORM 必须保留 glb 的 metallicFactor，否则整只兵纯金属发黑。
- 方块人带骨骼 + 动画（glb 内 Action）：走 `单位视觉` 的 `AnimationPlayer`，**别再用
  `_static_anim` 假弹跳**（那是无骨骼旧模型的兜底，会表现为"蠕动小碎步"）。
- 建筑**不并入 MatKit**（图集 NEAREST 硬约束）。"自然物" = `美术/模型/v7_自然/`。

## 7. 游戏内 UI

- 底栏三段：**左 = 大头像 + 两条 x/x → 中 = 铭牌 + 竖排三项数值 → 右 = 命令格**；
  三段坐在一整块奇幻石金底板上（`浮雕底板.gd`），左右内收 `BAND_EDGE=42`。
- **双形态，切换补间 0.22s**：
  - **紧凑**（单选、建筑没在干活）：`[信息面板][头像+血蓝][命令卡]` **全部贴右**，左边让给战场。
  - **展开**（多选 / 建筑在训练·研究）：`[头像][信息面板 → 贴到命令卡][命令卡]`，头像滑回最左。
  - 判据唯一出口 `HUD._compact_bottom()`；`建筑面板.is_expanded()`。
  - **紧凑形态下信息面板不能再有左侧空白**：左卡右缘必须紧贴信息面板左缘，
    信息面板宽度 = 内容需求宽（不许 EXPAND 撑满）。
- **摆放走绝对矩形 + Tween（`HUD._place_smooth`）**：锚点归零，直接给 `position/size`；
  目标没变但几何被最小尺寸撑大时**必须直接拉回**；只有 `_compact_mode` 翻转才 `animate=true`。
- 面板 `content_height()` **一律返回常数**（左卡 184 / 中段 224），否则自激循环。
- **底板 `RtsOrnatePlate`（`浮雕底板.gd`）**：全 `_draw()`，只在尺寸变化时重画。
  叠层＝外投影 → 石面渐变（28 条带）→ 石纹 → 石缝 → 纹章 → 内嵌双金线 → 顶檐+铆钉+壁柱+角饰。
  **别退回 StyleBoxFlat**；也**别画满网格砌缝**（像表格）。
- **左卡 `选中面板.gd`**：头像 `h-75`（104~186）+ 两行 `♥ 430/430`、`◆ 120/120`（24px 等宽 + 5px 黑边）。
  **不许有进度条、不许有可见底板**。`content_height()` 必须返回常数 184。
- **中段单位 `选择网格.gd`**：单选 = 34px 铭牌 + 金线 + `RtsStatColumn` 三行；
  多选 = 「名字 ×N」+ 每页 16 格（`MAX_COLS=8`，列数按实际数量收），每格 = 头像 + `430/430` + 血条 + 蓝条。
  格子尺寸不自己算：小 `custom_minimum_size` + 双向 `EXPAND_FILL` 由 GridContainer 拉满。
- **中段建筑 `建筑面板.gd`**：与单位同构（34px 铭牌 + `RtsStatColumn`）。
  有活干 = 上下两段：上 `[头像][训练·兵种+大进度条][剩余秒]`，下 **L 型队列**
  （上排 4 格、下排 3 格 = 一页 7），超过 7 个页码 `◀ 1/2 ▶` 与计数落下排右端。
  **队列格必须统一尺寸**（不能第一个小、后面大）；**左键点队列格 = 取消该条**，
  命令卡里点取消 = 取消当前（队首）训练/研究。
- **竖排数值 `RtsStatColumn`（`数值列.gd`）**：行底为空，只用一根 20% 金线分栏；
  数字 34px 等宽右对齐，超过 4 字降 0.72 倍字号；VBox `alignment=CENTER`。
- **说明气泡 `RtsTipLayer`（`说明气泡.gd`）**：挂 root、`z_index=200`、必须在建面板之前建好；
  `bind(host, 控件, func() -> Dictionary)` 回调在弹出那刻才执行；被绑控件 `mouse_filter` 不能 IGNORE；
  `_layer` 必须显式铺满 root；文案全在 `词条.gd`（RtsLexicon），别在面板里现编。
- 命令卡每格 `btn.name = "指令_<label>"`（验收按名字找）。
- `content_height()` 报面板自身总高，HUD 算底栏要 `+ BAND_PAD*2`（12px）。
- **建筑面板最小宽必须等于中段实际宽**（`_sel_w_bld` 不能写 `gw`）；
  中段宽度随内容变，`_process` 每 0.12s 比 `_mid_want()`，差 8px 就重摆。
- `Label.clip_text=true` 会把最小宽压成 0 且让 HBox 只给最小宽 → 标题类一律 `EXPAND_FILL`。
- 顶部提示条：长句（>22 字）必须给 540 固定宽 + `AUTOWRAP_WORD_SMART`（`UI_AUDIT=1` 会报 OUT-OF-SCREEN）。
- `UnitDef` **没有 `build_time`**（只有 `train_time`）；写 `d.build_time` 是运行时错误。
- 头顶界面挂 CanvasLayer（不在 root），`move_child(...,0)`，全部 `_draw()`。
- 小地图：视角框 1px 细线 α0.42 + 2.6% 填充 + 3px 角标；边框画在子控件 `RingFrame`。
- `Spec.icon()` 必须 `SHRINK_CENTER`；字号阶 `FS_HERO_BIG=34`。
- **空选中 → 整条底栏消失**（玩家反复强调）：唯一出口 `HUD._hide_band_parts()`，
  在 `_apply_layout()` 开头硬短路；回归命令 `-- --qa-band-check` 必须 PASS。
  资源条/小地图/提示条**永远在**，只收底栏那一条带。
- **攻击范围圈**在 `选择系统._sync_range_rings()`：单选/同类多选画，**混合选中不画**；
  不能攻击的不画；`no_depth_test` 让它穿过建筑也看得见。
- 命令卡新增：哨塔「升级」（→箭塔，只补差价）、建造页第 9 格「营火」。
- 界面说明书 `文档/界面说明.md`（第一条就是"没点名的 UI 一律不要动"）。

## 8. 地图编辑器

`代码/地图核心/`（数据）+ `addons/map_editor/`（插件/编辑会话/主屏/视口/停靠面板）。
布局照魔兽：菜单栏 + 快捷条 + 左「层」竖栏 + 3D 视口 + 状态栏；Dock **七页**。启动先弹新建向导。

- `armed`：false = 手型，左键点选 / 空地拖框选（转视角走右键拖 / 中键 / Alt+左键）；
  true = 手持工具。H/Esc/右键空地 = 收工具。
- **摆放照魔兽**：先在对象页「摆放归属」选玩家（`session.place_owner`），再挑资产。
- 队伍在**「玩家」页**（`set_team_layout()` 预设各自为战/两队/全同盟）。
- 撤销 `EditorUndoRedoManager.get_history_undo_redo(...)`（无 has_undo）；after 传活引用。
- **`主屏.setup()` 必须 `viewport.setup(session)`**；相机高度 `-sin(_pitch)`。
- **拖动单位/建筑/树木必须跟手**：拖动期世界坐标 = 射线命中点 − 抓取偏移，
  **不要每帧重新算 `snap_to_grid(鼠标)`**（那会让物体在格点间跳）；松手才吸附落位。
- 地形笔刷半径按**米**（`brush_radius`），1 格 = 8m 地块；笔刷预览圈 = 实际作用圈。
- **编辑器 = 游戏 必须喂同一份数据**：`视口.rebuild_terrain()` 要给 `mat_cells/mat_nodes/biome/base_points`。
- 新建向导：尺寸 9 档（128~384）、地形 5 种、高度 平地/随机、玩家 2/3/4。
- 拾取 lift = `UnitDef.height*0.55`，PICK_PIXELS 30；装饰只从 v7_自然 白名单来。

## 9. 地图文件 / 迷雾

- `地图/主场景地图.tres`（734 对象；4 槽；地块 28²）。生成
  `-- --no-map --dump-mapdef=res://地图/主场景地图.tres`（必须 `--no-map`）。
- MapDef v3：`mat_cells/mat_nodes/mat_tile/far_ridges/base_pad/edge_keep_out/ground`；
  不存 mat_nodes = 高度对、路没了；`ground` 是纯视觉合批，岩石不进 objects。
- 可走性同口径：树 0.95m 圆、金矿 4×4、岩石 1.05×scale、边界内缩 14m。
- 迷雾：全屏四边形挂相机下，`DEPTH_TEXTURE → INV_PROJECTION → INV_VIEW` 重建世界坐标，
  采样 128² 贴图，天空 `depth<=0` discard。己方+盟友点亮；敌单位仅可见时显示；
  敌建筑/资源探索过保留；雾里的敌人不可点选/右键。小地图复用同一张。

## 10. AI / 副官 / 音频 / 日夜

- `简单AI`：分兵 82/18、打最近敌方建筑、残血 32% 撤退、1~3 兵巡逻、每 2 兵营 1 箭塔。
- 副官 `extends SimpleAI`：`command_faction=player` + `think_scale=0.8` + 农民上限 18 +
  `_pick_builder` 只挑闲置农民 + 出击留 30%。`peasant.food_cost = 0`。
- BGM：开局舒缓 → 和平两首轮流(4.5s 等功率) → 战斗淡入战曲(3.2s) → 打完回原曲原位置；
  归一化 -23dBFS；换曲请求排队；循环接缝在播放端做（尾/头 0.35s 交叉淡化）。
  **性能坑**：`w.data` 是属性，循环里每次访问可能复制整个数组 → 先存局部变量。
- 日夜：`RtsDayNight`（`代码/系统/日夜.gd`）管时间/光照/天色；夜晚 = 野怪总攻窗口。
  **破晓 05:00-08:00 / 黄昏 17:00-20:00 各 3 小时**（`DAWN_*`/`DUSK_*` 是唯一口径）；
  夜光调亮到"能看清兵种和地形"（主光 1.18 / 补光 1.25 / 环境光 0.90），别调回全黑。
  `Game.is_night()` 是**唯一全局出口**（AI/副官/营火都读它）；`--qa-hour=18.5` 可拍黄昏。
- **AI 昼夜分流**（`_think_once`）：白天 巡逻+清野+成波推进；夜里 收队回防+营火+全员伐木。
  `_manage_creep_clear`：≥4 兵（副官 5）、开局 45s 后、家里没挨打才派 40% 去打最近营地。
- **战略层不许把野怪算成对手**：`_war_foes()` 剔 team 0；`_enemy_army()` 只比**最强的那一家**
  （四队图把三家求和 → 谁也超不过 1.0 → 三家 AI 整局不出门，实测兵比 0.23）。
  战术层（索敌/回防）仍把野怪当敌人。
- 伐木优先 `_nearest_wood()`：树→伐木场/基地距离 ×1.0 + 树→农民 ×0.35；`_wood_dropoff()`
  给伐木场 -8m 折扣（否则大本营常常更近，伐木场白造）。
- 哨塔：`_frontier_spot()` 朝敌方 24~34m 定点扩建（1→3 座，`WATCHTOWER_GROW_SEC=95`）；
  **多余哨塔升级箭塔**：至少留 1 座当眼睛，只补差价，箭塔总量封顶 4。

## 11. 性能

- 单位视觉每帧只做一次 `global_position` 查询；`_process` 里别 `get_node`/建数组。
- 受击/特效走对象池（`特效生成`），别每次 `instantiate`。
- 未被引用的旧系统（`代码/移动系统/` 等）在 `USE_SVC_PIPELINE` 下是死代码，可删。
- 大 glb（>1MB）必须确认无重复贴图/无冗余动画轨；模型只留必要 LOD。

## 12. 2026-11-01 夜新增系统（改之前先读）

- **组合件外观**：`UnitDef.model_path = "combo:<key>"` → `代码/美术/组合件.gd` 的 `ALIAS`
  → `代码/美术/<中文>外观.gd` 的 `static func build(def)`。游戏（`单位视觉.gd`）和
  地图编辑器（`预览工厂.gd`）共用这张表。现有 `dungeon` / `campfire`。
- **营火**：建筑 `campfire`（20 木 / 8s / 1×1 / 260 血 / 视野 8），`combo:campfire`；
  `代码/系统/营火光.gd` 按 `Game.is_night()` 的 `light_level` 调亮度（白天 10%，带抖动）。
  ★ 装饰里的「营火」是另一回事（纯视觉、不发光、不能拆）。
- **建筑改造**：`代码/系统/建筑改造.gd` 原地换型号（clear_footprint → unregister →
  spawn 新建筑 → mark_footprint → 血量按比例）。哨塔→箭塔只补差价（40 金/15 木）。
- **野怪：只由编辑器摆放（2026-11-01 最终口径）**。代码自动撒营地 / 定时补怪 /
  入夜扑家 / 地牢（`dungeon`）**全部删除**，别再加回来。`代码/系统/野怪.gd`
  现在只干两件事：建 `Game.neutral_faction`（team 0）+ 收编漏网的无阵营野怪。
  编辑器里摆 `gnoll_warrior` / `gnoll_scout` 并把「摆放归属」选**中立**即可
  （它们在 `MapAssets.NEUTRAL_OK` 白名单里）；地图加载器会把 `owner=-1` 的
  单位/建筑落到中立阵营。未来要做的「可配置营地 + 小地图图标」规格见
  `文档/野怪营地.md`（**本轮不实现**）。
- **单位同伴避让**：`RtsUnit._unit_ahead()`（`_steer` 调用）**只避让停着的同伴**；
  收尾 2.2m 关闭。两个都在走的人互相绕会左右横跳（寻路自检 ③ 抓到过）。
- **类缓存铁律**：能用 `preload` 常量 + `Node` 类型的地方**不要写 class_name 当类型**；
  编辑器插件里新增成员**必须先写 var**（漏了 → 整条脚本编译失败 → `autosave_tick` 刷屏）。
- 文档：`文档/界面说明.md` / `文档/编辑器资产同步.md` / `文档/开发交接.md`。

---

## 13. 2026-11-01 深夜：资产瘦身 + 性能实测（新增）

- **资产（美术 153MB → 100.7MB）**
  * 删 `美术/模型/v7_自然` `v7_单位` 的 19 个 GLB：逐字节等于根目录同名文件，
    且目录带 `.gdignore`（Godot 不导入）→ 纯冗余 35MB。`.md` 与 `.gdignore` 保留。
  * 删 `美术/贴图/地形/材质/草裂纹` `泥裂纹`：`地形.gd` 的 `ATLAS_PATH` 写死 `草泥`，
    另外两个从未加载 → 16.25MB。删 `美术/模型/地块/`（无引用，1.07MB）。
  * ⚠ **模型侧材质族贴图（`<模型>_<族>_albedo/normal.png`，28MB）不是冗余**。
    曾误删，运行时报 `Resource file not found` —— 铁誓建筑按
    `<模型名>_<族>.png` 拼路径取 ORM/自发光。**判断资产死活不能只靠 grep 代码**，
    必须删完立刻 `--headless --import` + 跑一帧验证。
  * 铁誓建筑真正要的是 `<模型>_主体.png` / `_ORM.png` / `_自发光.png`（每个 ~5KB）。

- **性能实测口径（`--perf-long`，PERF2 行）**
  * 80~90 单位时：`unit` ≈ 450~780 ms/s（相当于 60fps 下 7~13ms/帧），
    `u.order` 占 70%+，其次 `u.ground` ~90ms/s、`u.sep` ~40ms/s、`fog` ~19ms/s。
  * 把 `_update_order` 拆细后（探针会打 `o.acq/o.gather/o.amove/o.atk/o.goto/o.sgoal`）：
    **`_go_to` 是最大单点**（约 200~490 ms/s），其中 `standable_near` 几乎不花时间，
    A* 也只占 2~50 ms/s —— 说明贵在 `_go_to`/`_request_path` 的 GDScript 开销本身，
    **不是**寻路算法。下一个该动的是它（例如把"目标没变就早退"提到更前面、
    合并 `move_target`/`_goal` 的双写、给 `_request_path` 加更硬的节流）。
  * 已做的优化（都有实测依据，别回退）：
    - `Game.unit_hash()` 每帧只建一次，分离与索敌共用；
      `find_nearest_enemy` 改成**先哈希圈人再判敌我**（原先全量扫敌人）。
    - `_snap_ground` 站着不动时跳过 4 次坡度采样。
    - `_nearest_dropoff` 缓存 0.5s。
    - `RtsWorld.take_path_budget()` 每帧最多 6 条 A*，削平帧尖峰。
    - `Game.all_units()` / `all_harvestables()` 不再 `.duplicate()`（只读约定）。

- **提交与远端**：`origin = https://github.com/lizhimin100/3d-rts-youxi.git`，
  分支 `master`，`.workbuddy/` 已纳入版本库（不再 gitignore）。
## 14. 2026-11-03 2C-6：判定层口径与决策层（改之前先读）

- **输出分母 B（默认）**：`output_theory = Σ(dps × 最近 3 s 出过手的成员) × combat_time × coef`。
  "最近 3 s"的参照时刻是 **`max(recent_attack)`（本波最后一次开火）**，不是 `now`（收尾晚 15 s → 分母恒 0），
  也不是 `t_last_hit`（含"被打"，20 波 12 波分母 0）。`--output-theory-mode=all` 回旧口径对照。
- **系数 0.4**（`AI判定模式.DEFAULT_COEF` / `战斗模型.THEORY_OUTPUT_COEF`）；0.3/0.4/0.5 十分钟对照里
  0.4 的"输出在窗"最多（系数无关 raw 归一 18/49）。**不要再往下调**：中位已 ≈1，上沿 1.3 会成新瓶颈。
- **修理判据**：`max_hp − hp ≥ 200`（不是比例）。长局能触发，但 `blocked_no_builder` 极高
  （农民全在采集）→ 真正的闸是工位，不是阈值。
- **农场预判**：占用 >70% 或 余量 < 60 s 预计训练量×2；不急的农场排在兵营**之前**、急建（余量<4）之后。
- **兵营**：固定 ≥2 座、军队 >16 加第 3 座（与 `target_army` 脱钩）。队列空转因此从 16~102 s 降到 0~0.5 s。
- **大本营**：卡有成本（320 金/125 木）、玩家可建（`命令卡.build_page_ids()` 第 10 项），
  AI 侧 `简单AI.can_build_townhall()` **固定 false**（扩张线下一轮）。
- **bench 坑**：GDScript 的 `or` 返回 bool，`(x or {}).get()` 必炸；一旦 `_finish` 中断，
  进程不会退出、也不打 `AI-BENCH`（只会挂满墙钟）。要写成 `x if x is Dictionary else {}`。
- **长局耗时**：本机 CPU bound，`--speed=8` 不缩短墙钟，10 min 局 ≈ 10 min 墙钟（并行 2 局也不会更快）。

## 15. 2026-11-04 2C-7：修理工位 / 军队目标人口约束（改之前先读）

- **修理工位**：农民从"采金 8 + 机动 4"改成"采金 8 + 采木 3 + 建造/修理 1"（总数仍 12）。
  工位用 `_builder_uid` **持久保存**，不是每 tick 现算 —— 靠 `order`/`gather_kind` 分不清
  "工位在待命砍树"（GATHER+WOOD）和"普通伐木工"（同样 GATHER+WOOD）。
- **偷工位的不是 `_assign_workers`，是 `_rebalance_gatherers`**：配比再平衡每 8 s 会把
  "采金人数不足"的锅甩给任意伐木工（包括工位）。**两个函数都必须排除工位**
  （`if builder != null and w == builder: continue`），否则"固定工位"只成立一个 CD 周期。
- **`_pick_builder()` 的"有人建造就返回 null"是 2C-6 修理 0 触发的真因**：
  改成"只有工位自己在建造才返回 null"后，`blocked_no_builder` 从 230 次降到 **0**；
  失败原因变成 `blocked_builder_busy`（工位在盖房）。修理工位**不能**共用这个判断：
  反愚蠢审计要收尾"工位自己盖的停滞工地"，必须用 `_pick_sanity_builder()`（允许在建造），
  否则副官自检 E 组连红 3 条（`construction_stalled` episodes=0）。
- **军队目标**：`target = min(10+4B+2P, floor(人口上限/2) − 1)`；420 s 后**不解除**，
  取人口允许值。人口 24→11、32→15、40→19、48→23。人口占用 >90% 走农场急建（排在兵营前）。
  **新瓶颈不是目标公式，是"农场能不能落地"** —— 农场工地建不成，cap 就停在 32，目标恒 15。
  修好审计收尾之后，同一 seed 的四队 cap 都从 32 抬到 40/48（农场地基被人接手完工）。
- **`damage_ratio` 归一化对照（只给数据，没改窗口）**：
  `raw_damage_all = 承伤 ÷ Σ(全员有效生命)`（无量纲，与窗口同量纲）；
  `raw_damage_ps = 承伤 ÷ (Σ有效生命 × 战斗时间)`（1/s，提示词的**字面**公式）。
  **两者不能混用**：拿 ps 去扫 [0.4,0.9] 所有格子都是 0%，那是量纲错误。
  87 波实测：`[0.4,0.9]` 在 targeted 下 67% 进窗、在 raw 下只有 25% ——
  **窗口和分母是一对参数，单改窗口会得到"67%→25%"的假摔**。
- **投资占比口径**：分子 = 本周期新增支出（农场/军队 金+木），分母 = `income_60s × 60`。
  开局 `army_ratio` 2.3~3.5 是**在花初始金币**，不是异常；只能看趋势与脉冲，
  不能当"投资回报率"。60 s 增量而不是累计 —— 累计占比第 5 分钟后就被前期锁死。
- **长局并行上限 2 局**：4 个 10 min 局并行会把每局拖过 900 s，`timeout 900` 直接 SIGTERM，
  **bench json 一个都不落**（损失 17 min）。`timeout` 给 1800 s（≈3× 预期），`--tag` 必须唯一。
