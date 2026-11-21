# Map Shell Editor（3D 地图底壳编辑器）

> 三分离架构的第一层：**只做地形/地表、纯视觉装饰、弯曲行军脊线 + 分割环、候选石台锚点**。
> 摆兵种、写触发器、涂 A* 寻路、配经济 —— 全部不在这里（旧 `addons/map_editor` 已下线）。

## 打开

1. Godot 打开本项目；默认已启用（`project.godot → [editor_plugins]`）。
2. 顶部主屏出现 **Map Shell Editor**；右侧 Dock 出现 **地图底壳**（4 个工具 + 保存）。
3. 编辑器主屏实例化 `Screens/editor/map_shell/map_shell_editor.tscn`。

## 四个工具

| 工具 | 能做什么 | 写回 |
|---|---|---|
| 地形/地表 | 抬升 / 降低 / 平滑 / 压平；地表 4 槽位涂抹；水面高度 / 环境光 / 雾密度 | `terrain.heights`, `surface.index`, `terrain.water_level`, `terrain.ambient` |
| 装饰品 | 树 / 岩石 / 栅栏 / 旗帜 / 树桩 / 木箱；放置、拖动、转 45°、缩放、删除 | `decorations[]` |
| 脊线/分割 | 拖动控制点改曲线；拖动 4 个分割环；通道宽度（三位数） | `spine.points`, `spine.dividers{}`, `spine.width_logic` |
| 石台锚点 | 新增/拖动石台（射线吸附地形 + 石柱底座）、主堡/建造角色、半径/底座高、按 x 重编号 | `platforms[]` |

## 保存

- 自动保存 1.2 秒后写回 **`Content/data/map_shells.json`**（只写这一张表）。
- 底栏「保存底壳」立即写；「重载」重新读盘。

## 分割环的口径

`t`（000–999 三位数刻度）+ `length_logic = round(t/1000 × spine.length_logic)`，米 = `length_logic × 0.015`。
校验会逐环核对；不要手改到三位数以外。

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
