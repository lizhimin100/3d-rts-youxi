# 资产清单（asset_manifest）

> 生成日期：2026-11-21 · 口径：**只登记磁盘上真实存在的文件**。
> 用途：地图底壳编辑器（MapShellEditor）的笔刷、装饰、水面、环境**只准**引用本表里的路径。
> 铁律：**不许**再为树 / 水 / 地面材质新建占位 Mesh 或临时调色材质。缺资产就报缺资产，
> 用纯逻辑数据或极简基础几何体（Box/Cylinder）做"逻辑标记"，不伪装成美术。

## 0. 唯一入口（代码里认常量，不认字面量）

| 域 | 唯一入口 | 说明 |
|---|---|---|
| 地形 / 水 / 地表贴图 | `Game/map/地形.gd`（`RtsTerrain`） | `MATERIAL_PATH` / `WATER_MATERIAL_PATH` / `ATLAS_PATH` / `TEX_*` / `TILE_M` |
| 模型 / 环境 / UI 主题 | `Screens/world/art/美术接口.gd`（`ArtKit`） | `PATH_ENV` / `PATH_THEME` / `PATH_MAT_BUILDING` / `build_model()` |
| 自然装饰场景 | `Screens/world/art/装饰库.gd`（`RtsDecorLib`） | `scene(kind)` / `instantiate(kind)` / `make_multimesh()` |
| 自然物材质 | `Screens/world/art/自然材质.gd` | 树 / 草 / 岩石 / 金矿 / 木桩 / 尸骨统一材质 |
| 参数化材质库 | `Screens/world/art/材质库.gd`（`MatKit`） | 角色 / 建筑 / 道具的队伍色与调色板 |

**禁止**：在 `Screens/editor/**` 里写 `res://Content/art/...` 字面量。编辑器一律转发上述常量。

## 1. 地形与地表

| 资源 | 路径 | 大小 | 说明 |
|---|---|---|---|
| 地形材质 | `res://Content/art/材质/地形材质.tres` | 1.2 KB | `地形.gdshader` 的实例；8 m 硬边地块 |
| 地形着色器 | `res://Content/art/着色器/地形.gdshader` | — | 双材质硬边地块 + 顶点 AO + 细节法线 |
| 草泥图集 RGBA | `res://Content/art/贴图/地形/材质/草泥/atlas_草泥_rgba.png` | 1.86 MB | `mat_map` 的 R8 分块索引 → 图集 |
| 草泥图集法线 | `res://Content/art/贴图/地形/材质/草泥/atlas_草泥_n.png` | 618 KB | `atlas_n` |
| 草地底材 | `res://Content/art/贴图/地形/草地.png` | 70.9 KB | `tex_grass` |
| 泥土底材 | `res://Content/art/贴图/地形/泥土.png` | 116 KB | `tex_dirt` |
| 裂纹泥地 | `res://Content/art/贴图/地形/裂纹泥地.png` | 136 KB | `tex_cracked` |
| 岩石细节 | `res://Content/art/贴图/rock_albedo.png` | — | `rock_detail`（陡面叠加） |

关键 uniform（改前先看 `地形.gdshader` 注释）：`tile_m=8` / `map_half` / `mat_cells` /
`mat_map`(R8) / `atlas_rgba` / `atlas_n` / `tex_grass` / `tex_dirt` / `tex_cracked` /
`rock_detail` / `biome_color` / `biome_mix`。

> 底壳编辑器**必须**用这份材质，并按底壳尺寸重算 `mat_map` / `map_half` / `mat_cells`。
> 岩石 / 沙地没有独立地块材质 → 走覆盖层贴花（`_build_surface_decals`），不许新建"灰色塑料布"材质。

## 2. 水

| 资源 | 路径 | 大小 | 说明 |
|---|---|---|---|
| 水材质 | `res://Content/art/材质/水材质.tres` | 692 B | `水.gdshader` 实例，卡通阶梯菲涅尔 |
| 水着色器 | `res://Content/art/着色器/水.gdshader` | — | 顶点正弦波 + 3 步菲涅尔，不做真反射 |
| 波纹法线 | `res://Content/art/贴图/water_normal.png` | — | `ripple_normal`（编辑器 `RIPPLE_NORMAL`） |
| 水面装饰场景 | `res://Content/art/场景/水面_场景.tscn` | 533 B | 水池 / 水洼（CylinderMesh + 水材质） |

编辑器：水面高度滑杆只改 `terrain.water_level`，材质**永远**用 `水材质.tres`。

## 3. 树与自然装饰

| 种类 | 场景（唯一入口） | 源模型 | 材质 |
|---|---|---|---|
| 树 tree | `res://Content/art/场景/树_场景.tscn` | `Content/art/模型/树.glb`（1.75 MB） | 自然材质库（`bark` / `leaf`） |
| 岩石 rock | `res://Content/art/场景/岩石_场景.tscn` | `Content/art/模型/岩石.glb`（1.41 MB） | 自然材质库（`rock`） |
| 金矿 goldmine | `res://Content/art/场景/金矿_场景.tscn` | `Content/art/模型/金矿.glb`（3.28 MB） | `金矿材质.tres` |
| 草丛 grass | `res://Content/art/场景/草丛_场景.tscn` | `Content/art/模型/树.glb`（复用叶簇） | `树材质.tres` / 自然材质 |
| 碎石 rubble | `res://Content/art/场景/碎石_场景.tscn` | `Content/art/模型/岩石.glb` | 自然材质库 |

场景属性（阴影关闭 / 可见距离 60–160 m）写在 `.tscn` 里，**不要**在代码里重复设置。

编辑器的装饰注册表是 `res://Content/data/shell_decor.json`（15 种，`source=scene|glb` + 真实路径 + 拾取半径）。
新增/替换装饰必须同时改这里与本清单 —— `--check` 会逐条验路径存在。

## 4. 道具装饰（GLB，编辑器直接实例化）

| 种类 | 路径 | 大小 | 编辑器 id |
|---|---|---|---|
| 栅栏 | `res://Content/art/模型/栅栏.glb` | 265 KB | `fence` |
| 旗帜 | `res://Content/art/模型/旗帜.glb` | 2.08 MB | `flag` |
| 木桩 | `res://Content/art/模型/木桩.glb` | 1.40 MB | `stump` |
| 木箱 | `res://Content/art/模型/木箱.glb` | 790 KB | `crate` |
| 木桶 | `res://Content/art/模型/木桶.glb` | 791 KB | `barrel` |
| 帐篷 | `res://Content/art/模型/帐篷.glb` | 880 KB | `tent` |
| 断墙 | `res://Content/art/模型/断墙.glb` | 697 KB | `wall` |
| 路标 | `res://Content/art/模型/路标.glb` | 732 KB | `signpost` |
| 尸骨 | `res://Content/art/模型/尸骨.glb` | 742 KB | `bones` |

自然类（树/岩石/草/碎石/金矿/水面）走 §3 的场景；道具类走本节 GLB，两者都**不许**用
`CylinderMesh + SphereMesh` 现拼。

## 5. 建筑与单位模型（只做索引，改动走资产仓库）

- 建筑：`Content/art/模型/{大本营,兵营,农场,伐木场,哨塔,箭塔,铁匠铺,神秘圣地,蒸汽车坊}.glb`，
  各带 `_中` / `_远` 两档 LOD；建造阶段 `Content/art/模型/建造/*_build.glb`。
- 单位：`Content/art/模型/{农民,步兵,弓箭手,法师}.glb`、`精模/{骑士,破法者,魔金傀儡}.glb`、
  `野怪/{豺狼人战士,豺狼人斥候,豺狼人萨满}.glb`、`方块人/*.glb`（占位网格）。
- 失落帝国：`Content/art/模型/失落帝国/{creep_den,creep_gate,creep_shell}.glb`。

> 12 兵种里 `fishman_*` 目前**没有**模型。按铁律：**不新建占位丑模型**，
> `units.json` 里 `use_placeholder_mesh=true` 时只画极简基础几何体标记。

## 6. 着色器清单

| 着色器 | 用途 |
|---|---|
| `Content/art/着色器/地形.gdshader` | 双材质硬边地块（地形唯一） |
| `Content/art/着色器/水.gdshader` | 卡通水面（水唯一） |
| `Content/art/着色器/卡通主体.gdshader` | 角色 / 建筑 / 道具主材质 |
| `Content/art/着色器/描边.gdshader` | 反向外壳描边（挂在卡通主体 `next_pass`） |
| `Content/art/着色器/选中圈.gdshader` | 单位 / 建筑脚下选中光环 |
| `Content/art/着色器/移动指示.gdshader` | 走位虚线 + 目的地标记 |
| `Content/art/着色器/沙盘网格.gdshader` | 规划阶段作战台网格 + 势力场 |
| `Content/art/着色器/沙盘光环.gdshader` | 建筑锚点脉冲光圈 |
| `Content/art/着色器/贴花层.gdshader` | 铁誓建筑 team / team_trim 层 |
| `Content/art/着色器/铁誓自发光.gdshader` | 窗光 / 炉火 / 门缝 |
| `Content/art/着色器/建造显影.gdshader` | 建造模型"从地面长出来" |
| `Content/art/着色器/暗角.gdshader` | 全屏暗角 |
| `Content/art/着色器/特效加色.gdshader` | 粒子加色混合 |
| `Content/art/着色器/卡通.gdshader` | 旧版卡通（带贴图/法线/顶点 AO）——新材料不再派生 |
| `Content/art/着色器/战场迷雾.gdshader` | **已作废**（迷雾模块已删），仅留档 |

## 7. 选中圈（编辑器选中反馈的唯一资产）

| 资源 | 路径 | 说明 |
|---|---|---|
| 选中圈场景 | `res://Content/art/特效/选中圈.tscn` | QuadMesh + `选中圈.gdshader`，参数 `ring_radius` / `ring_width` / `team_color` / `opacity` |
| 着色器 | `res://Content/art/着色器/选中圈.gdshader` | 贴地细芯 + 内柔光 + 慢呼吸 |

编辑器选中任何对象都实例化这个场景，按对象包围半径改 `ring_radius`；**不要**自己画 Torus 圈。

## 8. 环境与 UI 主题

| 资源 | 路径 | 大小 | 说明 |
|---|---|---|---|
| 战斗环境 | `res://Content/art/环境/战斗环境.tres` | 1.6 KB | 天空 / 雾 / 泛光 / SSAO / 调色（主场景同款） |
| UI 主题 | `res://Content/art/主题/游戏主题.tres` | 5.2 KB | 面板 / 按钮 / 字体（`ArtKit.ui_theme()`） |
| 联盟调色板 | `res://Content/art/调色板/联盟调色板.tres` | — | 自然物 / 队伍色取色的唯一来源 |

编辑器环境：`战斗环境.tres` **复制一份**再改背景/雾（`duplicate(true)`），不许改共享资源。

## 9. 校验（`--check` 断言）

1. 本文件存在，且其中每一条 `res://` 路径都能在磁盘上打开（缺一个就红）。
2. `Screens/editor/map_shell/shell_view.gd` 只通过 `RtsTerrain` / `ArtKit` / `RtsDecorLib` 取资源，
   源码里没有 `res://Content/art/` 字面量。
3. 编辑器装饰节点里不出现 `CylinderMesh` / `SphereMesh` 现拼的树（用 `RtsDecorLib.instantiate`）。
4. `装饰库.SCENE_DIR` 指向 `res://Content/art/场景/`（这条曾经被目录改名带歪过一次）。
