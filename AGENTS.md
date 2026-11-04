# 本工程（简易rts）对 AI 助手的硬规则

> 这份文件会被后续会话自动读进来。**先看「一」，再做任何事。**

## 一、工作做完必须提交 git（最重要）

- **每一次交付完成后立刻 `git add -A && git commit`**，不要攒、不要等用户提醒。
  本工程曾因为"改了一整天却一次都没提交"而**全部丢失过**（靠回收站才救回来）。
- 提交信息用中文 + 前缀，格式：`feat: …` / `fix: …` / `art: …` / `chore: …`，
  一行说清"改了什么"，需要解释的写在下面空一行后。
- **提交前先看一眼 `git status`**：确认没有把 `_qa/`、`.godot/`、日志、临时备份混进去。
- 只删不提交 = 没发生；只在工作区改 = 等于没做。
- 大改之前先提交一次（哪怕内容是半成品），给它一个"可以退回来的点"。

### 收尾清单（每次交付的最后一件事，缺一不可）

1. `git add -A`
2. `git commit -m "<中文前缀>: <一句话>"`
3. `git log --oneline -1` —— **确认提交真的落库了**（被钩子拦下/写失败的情况出现过）
4. `git status --short` 只应剩下 `.gitignore` 里的运行时产物

用户明确要求：「做完任务要自动提交 git，不然有时候有些 agent 会忘记提交」。
所以**不要问『要不要提交』，直接提交**；一轮任务里分了几次大改就分几次提交。

## 二、几个会直接毁掉文件的坑

- **不要 read 整个大文件再 write 回去**：read 工具对 ~50KB 以上会**静默截断**，
  写回去就是砍掉半个文件（`代码/核心/地图生成.gd` 踩过）。分段读，每次 ≤400 行；
  小改用 `edit`，别用 `write` 覆盖。
- 真要整文件重写，先 `Get-Content | Measure-Object -Line` 核对行数，写完再核对一次。
- `--quit-after` / `--resolution` 是**引擎参数**，必须放在 `--` **之前**，否则游戏一直跑不退出。
- 新增 `class_name` 的脚本后先跑 `godot --headless --path . --import`，
  否则 `.godot/global_script_class_cache.cfg` 是旧的，别的脚本会报 "Could not find type"。
- **★ 更稳的做法：能不用类名当类型就不用**。本工程因为这个错白干过两次
  （`主场景.gd` 的 `RtsDayNight` / `RtsCreeps`）。规矩：
  * 只通过 `.call("…")` 调用的对象 → 类型写 `Node`，脚本用 `const XXX := preload(...)` 拿着；
  * 要调静态方法（`RtsDungeonVisual.build()`）→ 也改成 `preload` 常量再 `.call()`；
  * 真的必须写类名（`extends SimpleAI`、`as RtsBuilding`）→ 加完**立刻** `--import`。
  * 详见 `文档/开发交接.md` §1。
- **编辑器插件脚本（`addons/map_editor/*.gd`）里新增成员必须先写 `var`**。
  漏一个未声明变量 → 整个 `编辑会话.gd` 编译失败 → `主屏._process` 每帧刷
  `Nonexistent function 'autosave_tick'`，拖动/笔刷全废。**排查时往上找第一条 Parse Error，
  别从报错行开始读**（报错行只是受害者）。详见 `文档/开发交接.md` §2。

## 三、改完怎么验（都在工程根目录跑）

```powershell
$g = 'D:/youxi/anzhuang/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe'
& $g --headless --path . --quit-after 200 -- --qa-terrain          # 地形/出生点体检
& $g --headless --path . --script 代码/测试/界面自检.gd             # UI 8 项
& $g --headless --path . --script 代码/测试/建造自检.gd             # 建造 23 项
& $g --headless --path . --quit-after 1200 -- --autotest           # 全流程自动试玩
& $g --path . --resolution 1600x900 -- --shot=<绝对路径.png> --shot-delay=5 --quit-after-shot
```

- 截图**不要只用 `--cam-dist`**：鼠标落进窗口边缘会触发边缘滚动，镜头会漂走。
  需要固定机位时用 `--cam=x,y,z --cam-dist=N`。
- 判据优先用**数字**（`--qa-terrain` 的占地高差、自检的 `结果：通过 N / 失败 M`），不要凭截图猜。

### 长局 / 敏感性测试的时长下限（2C-7 起硬规定）

- **任何用来下结论的长局，最短 10 分钟**（`--minutes=10`）。
  5 分钟局只能出 2~3 波，多数还是 0 伤害的"差"波 —— 2C-6 拿 3 个 5 min 局做的系数敏感性
  **样本不足、已作废**，白烧了 15 分钟墙钟。要做敏感性就先确认"每档至少 10 波"。
- 本机 `--speed=8` 不会更快：CPU bound，10 min 局墙钟 ≈ 600~625 s（≈1× 实时）。
  排期按"游戏时长 ≈ 墙钟"算，多局并行才省时间。
- 对照局必须**同构建、同 seed、同难度**，只切参数开关（`--builder-slot` / `--army-pop-cap`
  这类，见 `代码/配置/AI判定模式.gd`），不要改代码再编译两次 —— 否则证据链断在版本上。

## 四、提交时不该进库的东西

`_qa/`（验收截图）、`.godot/`（引擎缓存）、`.workbuddy/`（会话记忆）、
`Godot/`、`NVIDIA Corporation/`（驱动日志）、`地图/_自动保存.tres` 等运行时地图产物 ——
这些都在 `.gitignore` 里，别手贱 `git add -f`。

## 五、项目知识去哪看

- `文档/界面说明.md` —— **界面唯一说明书**：怎么做、怎么操作、样式规范、
  以及"当前生效的全部 UI 要求"清单。
  ⚠️ 里面第一条就是玩家的硬要求：**没被点名的界面地方一律不要动**。
- `文档/编辑器资产同步.md` —— 新增单位/建筑怎么同步进地图编辑器（能摆、能设、长得对）。
- `文档/开发交接.md` —— 会让人白干一天的坑（类缓存 / 编辑器脚本编译失败 / 已知常红自检项）。
- `.workbuddy/memory/MEMORY.md` —— 长期总结（材质口径 / 地形 / UI / 地图编辑器 / 踩过的坑）。
  改完东西有新结论，**直接改那一个文件**，不要新建分轮总结。
