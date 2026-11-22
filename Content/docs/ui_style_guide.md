# UI 风格指南 · 温润木石风（方案 B）

> 唯一主题资源：`Content/ui/main_theme.tres`
> 陈列室：`Screens/ui/ThemeShowcase.tscn`（`run-game --shot theme 输出.png`）
> 本文只回答三件事：**颜色从哪来、为什么是这几个、要改该改哪一行**。

---

## 1. 色系从哪里吸出来的（不是拍脑袋）

扫描了工程里真正决定 3D 观感的四类源文件：

| 来源 | 文件 | 提取到的代表色 |
| --- | --- | --- |
| 建筑调色板（程序化建模的唯一色表） | `Content/art/调色板/联盟调色板.tres` | 灰泥 `#E3D8BC`、浅石 `#C4B796`、石 `#ADA180`、木 `#7A5230`、深木 `#553720`、金 `#E2B34C`、红瓦 `#7C3A32`、蓝布 `#2B5FB0` |
| 地形着色器 | `Content/art/材质/地形材质.tres` | 草 tint `#7A9E66`、泥 tint `#AD9478`、岩 tint `#565350` |
| 战斗环境（光照 / 雾 / 调色） | `Content/art/环境/战斗环境.tres` | 主光暖白 `#FFF0D4`、天际暖橙 `#DBB380`、雾 `#8C7D6B`、环境冷蓝 `#788FCC`、对比 1.36 / 饱和 1.34 |
| 既有 HUD 设计令牌 | `Screens/hud/界面规格.gd` | 金 `#D9B55C`、玩家蓝 `#4C9EFF`、敌方红 `#FF5242`、字 `#F2EFE3` |

结论：工程的 3D 底色是**暖石材 + 木构 + 午后暖光**，只有阵营标识是高饱和红/蓝。
所以 UI 底板不能再用纯灰，也不能把 3D 的红蓝直接搬上来——**底板抽石材，强调色抽阵营**。

字体与图标（复用，不新增二进制）：
- 字体：`SystemFont` 系统字体栈（Noto Sans SC → Source Han Sans SC → 微软雅黑 → 苹方 → 文泉驿），
  中英混排走同一族，**不打包字体文件**（系统字体本身可免费使用，发行包也不增加体积）。
- 图标：`Content/art/图标/*.svg`（64×64 单色白描边），在主题里只做配色容器，靠 `modulate` 上色。

---

## 2. 克制的 60 / 30 / 10 色板

### 60% —— 低饱和底板（石材）

| 名称 | Hex | 用途 |
| --- | --- | --- |
| `sand_0` 浮窗纸 | `#F3ECDD` | 唤出浮窗、卡面内页（最亮，离眼睛最近） |
| `sand_1` 常驻板 | `#E9DFCB` | 常驻 HUD 底板（85% 哑光） |
| `sand_2` 凹槽 | `#DCCFB4` | 进度槽、输入框、未激活页签 |
| `sand_3` 压深 | `#CBB998` | 按下态、分隔条、滑轨 |

### 30% —— 高对比文字 / 细边框（深棕墨）

| 名称 | Hex | 对比度（对 `sand_1`） | 用途 |
| --- | --- | --- | --- |
| `ink` 正文墨 | `#38291C` | **10.6 : 1** | 标题、正文、按钮字 |
| `ink_soft` 次级墨 | `#5E4A34` | **6.3 : 1** | 说明、单位名 |
| `ink_muted` 角标墨 | `#6F5B43` | **4.9 : 1** | 角标/提示（12px 仍可读） |
| `line` 描边 | `#6B4E30` | 5.8 : 1 | 1~2px 主描边 |
| `line_soft` 细线 | `#A98D66` | 2.4 : 1（仅装饰） | 内分隔、卡面细边 |

### 10% —— 功能强调（只给语义，不给装饰）

| 名称 | Hex | 语义 | 用法 |
| --- | --- | --- | --- |
| `attack` 进攻红 | `#A93B2E` | 进攻 / 敌方 / 危险 | `AttackButton`、`AttackLabel`、倒计时告急 |
| `defense` 防守蓝 | `#2E5C93` | 防守 / 我方 / 冷静 | `DefenseButton`、`DefenseLabel` |
| `cp_gold` 资源金 | `#C08A2E` | CP / 金币 / 关键数值 | 边线、图标、进度填充 |
| `gold_deep` 数值金 | `#7C5411` | 金色**文字**（5.1 : 1） | `ValueLabel` 的 CP/人口/小队数 |
| `good` 生命绿 | `#4E7A3A` | 血条 / 正向 | `ProgressBar` 填充（只做填充，不做字） |

> **金色文字必须用 `gold_deep`，不能用 `cp_gold`**：`#C08A2E` 在米色底上只有 2.3 : 1，
> 12~16px 会糊；`#C08A2E` 只配做边线、图标、填充块。

### 禁用 / 悬停的推导规则

- 悬停：底色向 `sand_0` 提亮 **+6%**，描边换 `cp_gold` 或对应强调色。
- 按下：底色压到 `sand_3`，描边加到 2px。
- 禁用：底色 `sand_2` × 0.62 alpha，字 `#7E6A52`（3.3 : 1，明确“不可用”但不刺眼）。
- **禁止**：荧光青/品红、纯 `#808080` 灰、饱和度过 60% 的大面积色块。

---

## 3. 字体与栅格

| 档位 | 字号 | 主题类型 | 场景 |
| --- | --- | --- | --- |
| 标题大号 | **28** | `TitleLabel` / `HeaderLabel` | 面板标题、浮窗队名、陈列室大标题 |
| 正文/卡牌中号 | **18** | `Label` / `Button` / `RichTextLabel` | 按钮、正文、卡牌名 |
| 角标/提示小号 | **14** | `CaptionLabel` / `TooltipLabel` / `ProgressBar` | CP 角标、兵种数、进度条内百分比 |

- 栅格：**8px**（内边距 16/12/8，行距 4 的倍数），与 `界面规格.gd` 同源。
- 圆角：按钮 6、常驻板 10、浮窗 12、卡面 8、槽 5、进度条 3。
- 描边：常驻 1px、浮窗 2px、按钮 1px（按下 2px）、焦点 2px 金色 55%。
- 底板 alpha：常驻 **0.88**、浮窗 **0.94**、卡面 **0.96** —— 保留“能看见一点 3D”的通透感。
- 阴影：暖棕 `#2A1B0F`，常驻 10/3、浮窗 18/6，透明度 0.18~0.24，**不用纯黑硬阴影**。

低中端手机（1600×720）：设计画布是 1920×1080，`canvas_items` 拉伸系数 0.833，
因此三档字号落到屏幕上是 **23.3 / 15 / 11.7 px**；正文 15px 是 720p 的舒适下限，
角标 11.7px 只用于不承载操作的信息。最小点击高度 **44px**（缩放后 36.7px，仍是拇指可点）。
陈列室在 1600×720 下必须仍能一屏放下（`run-game --shot theme … --shot-res=1600x720`）。

---

## 4. 主题变体清单（`main_theme.tres`）

陈列室一眼要能看全这五块：

1. **常驻 HUD 样例**：CP / 人口 / 剩余小队 / 主基地血条 / 敌方意图（红蓝双卡）/ 60 秒倒计时；
2. **选中唤出浮窗**：小队名 + 人数 + 聚合生命 + 集火（红）/ 防守（蓝）/ 重置（幽灵）；
3. **底栏命令格**：进攻 / 防守 / 建造三格（证明语义色在真实 HUD 里不打架）；
4. **控件图鉴**：按钮四态（按下态用 toggle 常驻）、四种语义变体、两种进度条、三档字号；
5. **配色比例**：60/30/10 的实物条 + 五色 Hex 角标。

| 基类 | 变体 | 说明 |
| --- | --- | --- |
| `PanelContainer` | *（默认）* | 常驻极简 HUD 底板 |
| | `HudPanel` | 与默认同款，语义化别名（常驻） |
| | `FloatPanel` | 选中唤出浮窗：更亮、2px 深棕边、更大阴影 |
| | `CardPanel` | 卡牌内页（最亮、细边） |
| | `InsetPanel` | 凹槽（资源槽、列表底） |
| `Button` | *（默认）* | 普通四态：normal / hover / pressed / disabled + focus 金边 |
| | `AttackButton` | 进攻红点缀（米白字） |
| | `DefenseButton` | 防守蓝点缀（米白字） |
| | `PrimaryButton` | CP 金实心主行动（深墨字，6.9 : 1） |
| | `GhostButton` | 无底透明，悬停才浮出底板 |
| `ProgressBar` | *（默认）* | 小队聚合血条（生命绿填充） |
| | `CountdownBar` | 60 秒倒计时（资源金填充，槽更浅） |
| `Label` | *（默认）* | 正文 16 墨色 |
| | `TitleLabel` | 24 标题 |
| | `HeaderLabel` | 24 标题 + 米色描边（压在 3D 实景上也不糊） |
| | `ValueLabel` | 24 数值金（CP / 人口 / 剩余小队） |
| | `CaptionLabel` | 12 角标 |
| | `AttackLabel` / `DefenseLabel` | 16 红 / 蓝语义文字 |
| `Panel` / `RichTextLabel` / `TooltipPanel` / `TooltipLabel` | *（默认）* | 兜底，避免出现引擎默认灰 |

> 类型变体在 Godot 里的写法：`theme_type_variation = &"FloatPanel"`。
> 变体只覆盖“不同的地方”，没写的属性自动回落到基类。

---

## 5. 要微调，改这几个地方

1. **整体色温**：`main_theme.tres` 里所有 `bg_color` 的 `sand_*` 四处；
   改 `sand_1` 一处即可让整个 HUD 变冷/变暖（其余按 ±4% 明度跟）。
2. **强调色**：搜 `SB_atk_*` / `SB_def_*` / `SB_pri_*` 三组，各 3 个颜色（normal/hover/pressed）。
3. **字号**：`default_font_size` + `TitleLabel/font_sizes/font_size` + `CaptionLabel/…`，
   **只改这三个**，其余控件都从这三档继承。
4. **通透度**：`SB_hud/bg_color.a`、`SB_float/bg_color.a`（0.85~0.96 之间）。
5. **圆角/描边**：`corner_radius_*` 与 `border_width_*`；不要超过 2px，否则会从“木石”变成“卡通”。

改完直接开 `Screens/ui/ThemeShowcase.tscn`（F6）看效果，再跑：

```powershell
./Tools/run-game.ps1 --shot theme _qa/theme_1080.png --shot-res=1920x1080
./Tools/run-game.ps1 --shot theme _qa/theme_720.png  --shot-res=1600x720
```

---

## 6. 与现有 HUD 的关系（重要）

- `Content/art/主题/游戏主题.tres`（深色 + 暖金）**仍是游戏内 HUD 的现行主题**，本次不动它，
  避免在没有出浅色 HUD 版截图评审前推翻整套界面。
- `main_theme.tres` 是新 UI 的唯一入口；`ThemeShowcase.tscn` 用它做“UI 压 3D 实景”的违和感检验。
- 若要全局切换：`project.godot` → `gui/theme/custom="res://Content/ui/main_theme.tres"`，
  但必须先给 HUD 的 `浮雕底板.gd` / `界面规格.gd` 出一版浅色映射，否则会出现深色自绘底板 + 浅色控件的夹生效果。
