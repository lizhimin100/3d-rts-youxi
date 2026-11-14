# QFramework 对本项目的适用性评估

> 状态：调研结论（2026-11-14）。结论先行：**部分借鉴，不整体采用。**
> 调研对象：https://gitee.com/liangxiegame/qframework （GitHub：https://github.com/liangxiegame/QFramework）
> 判据：Godot 4.7 + 纯 GDScript 现状、未来 C# 独立内核、AI agent 维护全部代码、Steam + 手机。

## 1. 它是什么（核实过源码，不只看 README）

- Unity 生态的 **MIT** 框架（Architecture/IOC 容器、MVC、ResKit、UIKit、AudioKit、事件系统），作者凉鞋。
- 仓库里确实有 **Godot 4.5+ 版**（`QFramework.Godot4.5+/addons/qframework/`），但是：
  - 只在一个提交里加入（2026-09-14），核心 13 个 GDScript 文件，`architecture.gd` 约 60 行；
  - 只有 2 个测试（easy_event / or_event），Architecture/Command/Query/FSM 无测试；
  - README 仍写 Unity 2018.4~Unity 6，版本号三处不一致（plugin.cfg 0.4.2 / FEATURES 0.3.107）；
  - 编辑器插件 `_enter_tree` 会请求 `api.liangxiegame.com` 自更新，下载 ZIP 整目录覆盖 —— **构建不可复现**。
- Unity 版核心 `QFramework.cs` 约 968 行，Unity 触达只有 25 行（MonoBehaviour 触发器、AutoRegister、EditorMenus）；
  ResKit（AssetBundle/协程）、UIKit（UGUI）、AudioKit（AudioSource）**离不开 Unity**。
- 许可证 MIT，商用/闭源可行；ToolkitsPro 是 AssetStore 付费版，不在仓库。
- 活跃度：最近提交 2026-10-23（v1.0.261），近三周 0；单人+爆发式提交；GitHub 5.6k★。

## 2. 为什么不能整体采用

1. **引擎不匹配**：我们的运行时是 Godot 4.7 + GDScript；它的 Godot 版是 2026-09 的实验分支，无测试、无 tag、无 CI、还带联网自更新。
2. **会被它的字符串注册表带坏**：Godot 版把 C# 的 `GetModel<T>()` 退化成 `get_model("GameModel")` 字符串表 + `get_model_name()` 双写；改名不报错、运行时 null —— 对 agent 是"静默失败"，与我们的硬约定直接冲突。
3. **全局类名互引**：GDScript 版大量 `class_name` 互引，正好踩过本项目"类缓存没刷新 → 主场景白屏"的坑。
4. **静态单例串状态**：`Architecture<T>.Interface` 是静态单例，测试之间会串状态；我们的 `--check` 要求每条检查独立可复现。
5. **异步命令全 `await`**：漏 await 不报错，agent 很难靠编译/检查发现。
6. **C# 内核不需要它**：我们要的是 **net8.0 纯类库**（规则/经济/AI 可 `dotnet test`），QFramework 的 C# 核心虽可剥离，但它的价值主要在 Unity 的 ResKit/UIKit，与"引擎无关内核"目标错位。

## 3. 值得借鉴的（已经吸收进本工程）

| 借什么 | 落到哪里 |
|---|---|
| **四层 + 允许调用矩阵**（表现/逻辑/数据/基础设施） | `AGENTS.md` 硬约定 3/4 + `Documents/architecture.md` 分层图 |
| **核心极小**（968 行就能撑起 IOC + 事件 + 命令） | `Engine/` 每个模块只做一件事，不引入大框架 |
| **显式注册 + 启动校验**（它用字符串表，我们改成类型/常量 + 启动断言） | `CardStore`/`Keys` 启动即校验，未知 key 直接 `push_error` |
| **变更契约目录**（`openspec/`：proposal/design/tasks/specs） | `Documents/concept.md` 三栏 + `AGENTS.md` 拍板记录；大改用"提案→拍板→检查"走 |
| **MIT 许可证的工程纪律**（保留声明、可再分发） | 若未来引入任何 MIT 代码，保留 LICENSE 与来源 |

## 4. 明确不学的

- ❌ 字符串键注册表（改名静默失效）——我们用 JSON 字段校验 + `--check` 引用闭环。
- ❌ 静态单例存状态——`App/SaveSvc/…` 是自动加载节点，测试可重置、路径可隔离。
- ❌ 全局 `class_name` 互引——项目已有"能不用类名当类型就不用"的规矩。
- ❌ 编辑器插件联网自更新——所有生成物走 `Tools/gen`，可复现、可 diff。
- ❌ 把 Unity 的 ResKit/UIKit 思路硬搬到 Godot——Godot 的资源/场景系统已经够用。

## 5. 对 C# 内核的建议

- 内核做成 **`net8.0` 纯类库 + xunit**：规则、经济、AI 决策都能 `dotnet test`，不引 UnityEngine/Godot。
- Godot 侧只留 **Adapter**（读写状态、发事件），Adapter 只做 smoke test。
- 工程分层参考 **YokiFrame**（MIT、活跃、有真 `.csproj`/`asmdef`/Adapters 隔离）而不是 QFramework：
  https://github.com/HinataYoki/YokiFrame
- 事件/回调加 generation 号，防"迟到的回调改到新一局的状态"。

## 6. 一句话回答"对 agent 写全部代码是不是更好维护"

**不是。** QFramework 的 Godot 版目前是"能跑的小实验"，把它引进来会增加一层不可复现的依赖与字符串契约；
真正对 agent 友好的东西是：**显式依赖、数据可 diff、检查可反验、错误不静默**——这些我们已经用自己的 `Engine + Model + Content + run-game` 做了。
