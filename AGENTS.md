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

## 二、几个会直接毁掉文件的坑

- **不要 read 整个大文件再 write 回去**：read 工具对 ~50KB 以上会**静默截断**，
  写回去就是砍掉半个文件（`代码/核心/地图生成.gd` 踩过）。分段读，每次 ≤400 行；
  小改用 `edit`，别用 `write` 覆盖。
- 真要整文件重写，先 `Get-Content | Measure-Object -Line` 核对行数，写完再核对一次。
- `--quit-after` / `--resolution` 是**引擎参数**，必须放在 `--` **之前**，否则游戏一直跑不退出。
- 新增 `class_name` 的脚本后先跑 `godot --headless --path . --import`，
  否则 `.godot/global_script_class_cache.cfg` 是旧的，别的脚本会报 "Could not find type"。

## 三、改完怎么验（都在工程根目录跑）

```powershell
$g = 'E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.cmd'
& $g --headless --path . --quit-after 200 -- --qa-terrain          # 地形/出生点体检
& $g --headless --path . --script 代码/测试/界面自检.gd             # UI 8 项
& $g --headless --path . --script 代码/测试/建造自检.gd             # 建造 23 项
& $g --headless --path . --quit-after 1200 -- --autotest           # 全流程自动试玩
& $g --path . --resolution 1600x900 -- --shot=<绝对路径.png> --shot-delay=5 --quit-after-shot
```

- 截图**不要只用 `--cam-dist`**：鼠标落进窗口边缘会触发边缘滚动，镜头会漂走。
  需要固定机位时用 `--cam=x,y,z --cam-dist=N`。
- 判据优先用**数字**（`--qa-terrain` 的占地高差、自检的 `结果：通过 N / 失败 M`），不要凭截图猜。

## 四、提交时不该进库的东西

`_qa/`（验收截图）、`.godot/`（引擎缓存）、`.workbuddy/`（会话记忆）、
`Godot/`、`NVIDIA Corporation/`（驱动日志）、`地图/_自动保存.tres` 等运行时地图产物 ——
这些都在 `.gitignore` 里，别手贱 `git add -f`。

## 五、项目知识去哪看

`.workbuddy/memory/MEMORY.md` —— 唯一的长期总结（材质口径 / 地形 / UI / 地图编辑器 / 踩过的坑）。
改完东西有新结论，**直接改那一个文件**，不要新建分轮总结。
