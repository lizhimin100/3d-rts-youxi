# Map Shell Editor（3D 地图底壳编辑器）

> 三分离架构的第一层：**只做地形/地表、纯视觉装饰、弯曲行军脊线、三块势力区域多边形、战术地形格子**。
> 摆兵种、写触发器、涂 A* 寻路、配经济 —— 全部不在这里（旧 `addons/map_editor` 已下线）。

## 打开

1. Godot 打开本项目；默认已启用（`project.godot → [editor_plugins]`）。
2. 顶部主屏出现 **Map Shell Editor**；右侧 Dock 出现 **地图底壳**（4 个工具 + 保存）。
3. 编辑器主屏实例化 `Screens/editor/map_shell/map_shell_editor.tscn`。

## 四个工具

| 工具 | 能做什么 | 写回 |
|---|---|---|
| 地形/地表 | 抬升 / 降低 / 平滑 / 压平；地表 4 槽位涂抹；水面高度 / 环境光 / 雾密度 | `terrain.heights`, `surface.index`, `terrain.water_level`, `terrain.ambient` |
| 装饰品 | 15 种：树 / 岩石 / 草丛 / 碎石 / 金矿 / 水面 / 栅栏 / 旗帜 / 木桩 / 木箱 / 木桶 / 帐篷 / 断墙 / 路标 / 尸骨；放置、拖动、转 45°、缩放、删除。**只实例化 `Content/docs/asset_manifest.md` 里登记的现有资产** | `decorations[]` |
| 脊线 | 拖动控制点改曲线；通道宽度（三位数逻辑长度） | `spine.points`, `spine.width_logic` |
| 战术格子 | 新增/拖动/框选/删除（Delete）/撤销（Ctrl+Z）；主堡位与建造位切换；宽/深/朝向；按 x 重编号 | `tiles[]` |

顶栏另有 **`[定义玩家区] [定义中立区] [定义敌方区]`** 三个区域绘制按钮与 **撤销**：
左键放顶点，点第一个顶点或回车闭合，右键 / Esc 取消；不足 3 个顶点会被 Model 拒绝。

## 保存

- 自动保存 1.2 秒后写回 **`Content/data/map_shells.json`**（只写这一张表）。
- 底栏「保存底壳」立即写；「重载」重新读盘。

## 区域与格子的口径

- **区域**：`regions = {player:[[x,z],…], neutral:[…], enemy:[…]}`，XZ 多边形；点在多边形内与顶点校验的唯一实现在
  `Model/Map/RegionPolygon.cs`（编辑器经 `ModelBridge.RegionContains / RegionValidate` 调用）。
- **战术格子**：`tiles[] = {index, side, role, x, z, w, d, yaw, terrain_y}`；
  `BuildingAnchor = 左上角 (-w/2,-d/2)`、`SquadSpawnAnchor = 正中心 (0,0)`，唯一实现在 `Model/Map/TacticalTile.cs`。
  格子之间必须留 ≥ 1.0 m 边到边间隙（Model 校验，底栏红/青胶囊实时显示最小间隙）。
- 未激活格子局内状态 = `ruin`（碎石遗迹），规则在 `Game/map/关卡装配.gd → tile_state()`。

## 命令

```bash
# 启用后的主屏自检（控件齐全）
godot --headless --editor -- --map-shell-selftest
# 截编辑器主屏
godot --path . --editor -- --map-shell-shot=E:/tmp/shell.png
# 运行时截底壳编辑器（不依赖编辑器）
./Tools/run-game.ps1 --shot shell _qa/shell.png
```

## 配色

深岩灰 `#12161F` 作底，沿用旧地图编辑器的石色 / 金色（`Screens/editor/map_shell/shell_theme.gd` 的
`STONE` / `LEGACY_GOLD`），保证嵌回编辑器时不突兀。
