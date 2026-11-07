# 地图编辑器界面（按钮 / 图标 / 扩展接口）

> 2026-11-07 重排。玩家口径：
> 「地图编辑器的图标按钮，按照整理出来的逻辑和风格重新设计排版，
>  尤其按钮图标和排版逻辑、使用逻辑，既要美观直观，也要方便人类操作，
>  同时留下接口，方便后续 Agent 再次打磨。」

---

## 1. 一条铁律：按钮由**表**生成，不在代码里散着写

```
addons/map_editor/按钮表.gd     ← 唯一的按钮定义（数据）
        ↓
addons/map_editor/主屏.gd       ← 只负责摆（`_build_quick_bar` / `_build_rail`）
        ↓
代码/界面/界面规格.gd::icon_button()  ← 唯一的按钮皮肤与尺寸
        ↓
美术/图标/<name>.svg            ← 图标资源（64×64，白色单色路径）
```

**加一个按钮** = 在 `按钮表.gd` 里加一行 + 在 `主屏._on_menu` 加一个 case。
不用碰布局、不用调像素。

---

## 2. 按钮表结构

### 2.1 顶部快捷条 `GROUPS`

```gdscript
{"name": "文件", "items": [
    {"id": 1, "text": "新建", "icon": "file_new", "tip": "新建地图（先选尺寸/人数/种子）"},
    …
]}
```

| 字段 | 说明 |
|---|---|
| `id` | **必须**和 `主屏.gd::_on_menu(id)` 的 case 对上 |
| `text` | 最多 **2~3 个字**。长了挪进 `tip` |
| `icon` | `美术/图标/<icon>.svg`；找不到会静默退回纯文字 |
| `tip` | tooltip，写"做什么 + 快捷键" |
| `kind` | 可选：`normal` / `primary` / `danger`（删除这类不可逆操作用 danger） |

组与组之间自动加分隔线。当前分组：文件 / 编辑 / 检查 / 数值 / 视角。

### 2.2 左侧层栏 `LAYERS`

```gdscript
{"layer": "unit", "text": "单位", "icon": "sword", "tip": "切到「对象·单位」：摆兵、野怪"}
```

`layer` 是**逻辑键**（terrain / unit / building / doodad / resource / region），
主屏用 `match` 把它映射到 `MODE_*` + `MapObject.Category`。
改文案/换图标不影响行为；改行为只动主屏那一个 `match`。

---

## 3. 按钮规范（和 `文档/UI风格.md` 同一套）

| 项 | 值 |
|---|---|
| 工具栏按钮高度 | 30（`icon_button` 的 `h`） |
| 层栏按钮 | 84 × 46 |
| 图标尺寸 | 高度的 62%（30 → 18px，46 → 28px） |
| 图标与文字间距 | 5px |
| 对齐 | **图标 + 文字一起靠左**（拉伸按钮必须 `alignment = LEFT`） |
| 纯图标按钮 | 正方形 `h × h`，必须有 tooltip |
| 危险操作 | `kind = "danger"`（红底），且文案里不出现"确定吗"这类二次确认 —— 靠 Ctrl+Z |

> ⚠️ 踩过的坑：`icon_alignment` 和 `alignment` 只设一个，会出现
> 「图标钉在最左、文字单独居中」的分家效果；两个都设 CENTER 会**图标压在文字上**。
> 正确做法：`icon_alignment = LEFT` + 拉伸按钮再设 `alignment = LEFT`。

---

## 4. 图标资源

`美术/图标/*.svg`，64×64，白色单色路径，`界面规格.icon_tex(name)` 取。

编辑器常用（2026-11-07 新增）：

| 名字 | 用途 |
|---|---|
| `file_new` `file_open` `file_save` `file_save_as` | 新建 / 打开 / 保存 / 另存 |
| `undo` `redo` `history` | 撤销 / 重做 / 历史 |
| `check` `play` `card` `help` | 校验 / 试玩 / 数值卡 / 帮助 |
| `view_top` `view_iso` `view_reset` | 俯视 / 斜视 / 复位 |
| `copy` `paste` `delete` | 复制 / 粘贴 / 删除 |
| `rotate_l` `rotate_r` `rotate_rand` | 旋转 |
| `scale_up` `scale_down` `scale_reset` | 缩放 |
| `hand` `terrain` `region` `doodad` `mine` | 层栏 |
| `grid` | 显示网格 |
| `axe` `pick` | 伐木 / 采矿（技能卡也用它） |

新增图标：放同名 SVG → `--import` → 表里填名字即可，代码零改动。

---

## 5. 使用逻辑（人类视角）

1. **顶部** = 全局动作（文件 / 编辑 / 校验 / 数值 / 视角）；
2. **左侧** = 我现在在改什么（层），点一下右侧面板就跟着切；
3. **右侧** = 这一层的属性与动作（摆放归属 / 对象列表 / 选中对象的复制旋转缩放）；
4. **手型**在最上面：不拿工具时左键只转视角 + 点选，拿了工具才改地图。
   这条是编辑器最容易误操作的地方，所以手型按钮**永远在最上面**。

---

## 6. 验证

```powershell
$g = 'E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe'

# 链路自检（24 项，含四扇窗能打开）
& $g --headless --editor --path . -- --map-editor-selftest

# 人眼验收（固定机位、指定页签）
& $g --editor --path . --resolution 1600x900 -- `
   --map-editor-shot=<绝对路径>.png --map-editor-shot-demo --map-editor-shot-tab=对象
```

截图检查四件事：

1. 每个按钮的**图标都画出来了吗**（没有空白方块）；
2. 图标和文字是**紧挨着靠左**，还是一左一中；
3. 一排按钮的**高度是否一致**（30 / 46 两档）；
4. 顶部工具条有没有把右侧 Dock 挤窄（长句提示一律不进工具条）。

---

## 7. 待办（留给后续 Agent）

- 右侧 Dock 的「地形」页工具按钮还是纯文字，可以按同一套表改成图标；
- 对象列表的每行可以加一个小类型图标（单位/建筑/装饰/资源）；
- 波次页、玩家页的按钮目前靠 `_add_small_button` 直接造，可以考虑也搬进按钮表；
- 工具栏在 1280 宽以下会换行挤压，可考虑收成"图标模式"（只留图标）。
