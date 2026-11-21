# 内容数据管线（唯一数值源 = JSON）

> 状态：现行（2026-11-14）。改数值/加内容之前先读这一页。
> 规则：**改数值只改 `Content/data/*.json`**；代码里不再有可调默认值。
## 0. Content 是唯一真源，不是中转站

`Content/` **不是**“先放这里、之后再导出/再读别的文件”的暂存区。运行时直接读它，编辑器直接写它。

- `Cfg` 读 `Content/data/game.json`；`UnitTable` / `技能表` / `野怪营地表` 经 `CardStore` 读 `Content/data/cards/*.json`；
- 地图经 `MapStore` 读 `Content/maps/*.tres`；
- 编辑器弹窗也是 `CardStore` 读写同一批 JSON；
- **没有“导出/同步”步骤**，也没有构建输出目录里的副本；`DebugTuner` 写回源 JSON；
- 内存里的 `UnitCard` / `UnitDef` 只是**类型化视图**（方便 GDScript 用），不是第二份数值；保存时仍回写 JSON。

唯一“迁走”的是旧 `.tres` 卡：`Content/legacy/cards/` 只留档，运行时和编辑器都不读，发行构建排除
（`Tools/build/release_exclude.txt`）。**改那里不会影响游戏。**

### 各类数据在哪、谁在写

| 数据 | 位置 | 真人怎么改 | 运行时谁读 |
|---|---|---|---|
| 单位 / 建筑 / 技能 / 营地卡 | `Content/data/cards/{units,buildings,skills,camps}/*.json` | 编辑器弹窗（推荐）或文本编辑 | `CardStore` → `UnitTable` / `技能表` / `野怪营地表` |
| 全局数值（经济/战斗/镜头/难度/开局/界面） | `Content/data/game.json` | 文本编辑 | `Cfg`（`配置入口.gd`） |
| 可采集物 / 研究 | `Content/data/{harvestables,researches}.json` | 文本编辑 | `UnitTable` |
| AI 诉求系数 | `Content/data/ai_demand.json` | 文本编辑 | `AI诉求系数` / `战斗模型` |
| 界面文案 | `Content/i18n/ui.csv` | 文本编辑 | `I18n` |
| 资源 key | `Content/keys/assets.json` | **跑 `python Tools/gen/gen_asset_keys.py`**，不要手改 | `Keys` / `AudioSvc` |
| 地图布局 | `Content/maps/*.tres` | 地图编辑器（.tres 是编辑器资源） | `MapStore` / `MapLoader` |
| 截图画面 / 推演场景 | `Content/data/{screens,sim}.json` | 文本编辑 | `shot_runner` / `run_simulate` |
| 美术 / 音频 | `Content/art` / `Content/audio` | Blender 脚本 / 生成器 / 直接换文件 | 模型工厂 / `音效管理` / `AudioSvc` |
| 旧卡（只留档） | `Content/legacy/cards/*.tres` | **不要改** | 无人读，发行排除 |

### 为什么地图还是 `.tres`

`MapDef` 是地图编辑器的核心 Resource（高度场/地块/对象/区域/波次一大堆嵌套子资源）。
它不是“平衡数值”，而是编辑器布局数据；转 JSON 只会让地图编辑器失去 Inspector 与类型校验，收益为负。
所以：**平衡/文案/卡 → JSON；地图布局 → `.tres`**，两者都是“当前生效的真源”，不是新旧两套。

### 改完什么时候生效

- 游戏内卡片/数值：**重启游戏**（没有运行时热重载）；编辑器弹窗保存后刷新列表即可看到。
- 地图编辑器保存 `.tres`：保存即生效（编辑器自己 reload）。
- 新增 `.glb` / 场景 / `class_name`：跑 `./Tools/run-game.ps1 --import`。
- 手改任何 `Content/data` 后：跑 `./Tools/run-game.ps1 --check`，再开游戏。


## 1. 目录

```
Content/
├─ data/
│  ├─ cards/units/<id>.json        单位卡（UnitCard）
│  ├─ cards/buildings/<id>.json    建筑卡（BuildingCard）
│  ├─ cards/skills/<id>.json       技能卡（SkillCard，含 atoms 原子）
│  ├─ cards/camps/<id>.json        野怪营地（CampDef）
│  ├─ game.json                    全局配置（GameConfig + 难度三档）
│  ├─ harvestables.json            金矿/树/四季树（UnitDef）
│  ├─ researches.json              铁匠铺研究（ResearchDef）
│  ├─ ai_demand.json               AI 诉求分系数（25 项）
│  ├─ sim.json                     --simulate 的对局场景
│  └─ screens.json                 --shot 的画面表
├─ i18n/ui.csv                     界面文案（key,zh,en,note）
├─ keys/assets.json                资源 key 登记（自动生成）
├─ art/ audio/ maps/               美术 / 音频 / 地图（原 美术/音频/地图）
└─ legacy/cards/                   旧 .tres 卡（只留档，运行时不读）
```

## 2. 卡 JSON 的形状

每张卡是 `{$script, props}`：

```json
{
  "$script": "res://Game/config/单位卡.gd",
  "props": {
    "card_id": "footman",
    "display_name": "联盟步兵",
    "max_hp": 400,
    "attack": 14,
    "range": 90,
    "cost_gold": 125,
    "model_path": "res://Content/art/模型/方块人/方块人_联盟步兵.glb",
    "skills": ["shield_up"],
    "trains": []
  }
}
```

- `$script` 决定字段表（UnitCard/BuildingCard/SkillCard/野怪营地定义）。
- 字段名与 GDScript 的 `@export` 一一对应；**拼错会报「未知字段」，不会静默丢**。
- `StringName` 写成字符串；类型化数组写成普通数组；`Vector2/2i/3/Color` 写成 `{"$t":"Vector2","x":…}`；嵌套资源写成 `{"$script":…,"props":…}`。
- 文件名必须等于 `card_id`（`--check` 会验）；用 ASCII。

### 加一个单位（不改代码）

1. 复制 `Content/data/cards/units/footman.json`，改 `card_id` / 数值 / `model_path`。
2. 如果要让它能被某个建筑训练：在建筑卡 `trains` 里加这个 id（编辑器"单位卡"页勾选也行）。
3. 如果要给它技能：`skills` 里放技能卡 id。
4. `./Tools/run-game.ps1 --check` —— 引用、模型、词表、数值范围全查。
5. `./Tools/run-game.ps1 --import`（如果新加了模型/场景）→ 开游戏。

### 加一个技能

复制 `cards/skills/shield_up.json`。`atoms` 是三层积木的第 1 层（属性倍率/连发/格挡），
`anim_*` / `vfx_*` 可以留空（没有动作/特效就静默跳过）。新效果类型要加原子脚本时，
先加 `Game/config/原子/原子_*.gd`，再在卡里引用。

### 改数值

直接编辑 JSON；`--check` 会验结构，开游戏即生效。**不要**再改 `.tres`、也不要在 `.gd` 里加默认数值。

## 3. 全局配置 / 难度 / AI 系数

- `game.json`：镜头、经济、战斗（护甲/克制表/暴击）、地图、开局编成、对局槽位、界面。
  `difficulties` 是嵌套的 DifficultyDef 数组（三档）。
- `ai_demand.json`：25 个诉求分系数/刻度，平铺键值；`AI诉求系数.defaults()` 直接读它。
- `sim.json`：`--simulate` 的两方编制；单位数值仍从 `units.json` 取（不重复写）。

## 4. 文案（i18n）

- 文件：`Content/i18n/ui.csv`，表头固定 `key,zh,en,note`；每行 zh/en 都不能空。
- 代码：`I18n.t("key", {"name": "…"})`；**新界面（`Screens/screens/`）零写死中文**。
- 缺 key：`I18n.t` 会 `push_error` 并返回 key 本身；`--check` 会扫 `I18n.t("…")` 的 key 是否存在。
- 旧界面存量：`Content/i18n/legacy_budget.json` 按文件冻结（只许降）。
  迁移一个界面 = 把中文换成 key + 在 CSV 加行 + 重跑 `gen_i18n_budget.py` 降预算。

## 5. 资源 key

- `Content/keys/assets.json` 由 `python Tools/gen/gen_asset_keys.py` 生成（**不要手改**）。
- 分类：audio / models / icons / shaders / fx；key = 文件名（重名时加目录前缀）。
- 游戏侧取法：`Keys.path("audio", "bgm_舒缓")` / `Keys.path("models", "步兵")`。
- `--check` 验：登记的路径都存在 + `Content/art|audio` 下每个资源都已被登记。

## 6. 源文件清单 / 引擎 pin

| 什么时候跑 | 命令 | 作用 |
|---|---|---|
| 新增/删除源文件 | `python Tools/gen/gen_manifest.py` | 更新 `Content/manifest.json`；否则 `--check` 报"清单与磁盘不一致" |
| 改了 `Engine/` | `python Tools/gen/gen_engine_pin.py` | 更新 `Engine/pin.json`；否则 `--check` 报"被就地修改" |
| 新增/删除资源文件 | `python Tools/gen/gen_asset_keys.py` | 更新资源 key 表 |
| 文案迁移后 | `python Tools/gen/gen_i18n_budget.py` | 重算写死中文存量（只降不升） |

## 7. 旧 .tres → JSON 的导出器（留档）

`Tools/gen/export_content.gd` 是**一次性迁移工具**：读旧卡 → 写 JSON → 立刻读回逐字段比对。
只在需要追溯"当初 JSON 是怎么来的"时跑：

```powershell
godot --headless --path . --script Tools/gen/export_content.gd
```

它依赖 `Game/config/卡/`（已搬到 `Content/legacy/cards/`），**日常开发不要跑**。

## 8. 调试调参

调试接口的 `tune` 动作只能写 `res://Content/data/` 下的 JSON（`Engine/debug/debug_tuner.gd` 白名单），
写完立刻回读校验。**不写构建输出目录里的副本**。