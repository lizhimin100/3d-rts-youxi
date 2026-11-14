"""生成 `Documents/索引/测试索引.md`：38+ 个自检脚本的入口 / 断言数 / 已知常红 / 用途。

用法：python Tools/生成测试索引.py
不要手改输出文件；要改口径就改这个脚本或各脚本头注释。

口径说明：
- **入口**：优先读脚本头里的 `启用：` 行（作者写的命令最准）；没有就按
  "注释里出现 --script" 判为脚本入口，否则标"主场景挂载（见文件头）"。
- **断言数**：数 `_ok(` / `_check(` / `check(` 三种常见命名，是**近似值**，
  动态循环里的断言会少算。它的用途是"知道这个自检有多大"，不是精确计数。
- **常红**：从 `Documents/开发交接.md` 的基线表人工同步，不是自动推断。
"""

from __future__ import annotations

import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT, "代码", "测试")
OUT = os.path.join(ROOT, "文档", "索引", "测试索引.md")

# 已知常红（2026-11-13 同步自 Documents/开发交接.md §5）
KNOWN_RED = {
    "配置回归.gd": "2 项：dept 默认值 / 默认 dept=off",
    "寻路抖动自检.gd": "3 项：8 兵到达 7/8、崖边扫描失败、12 人间距 0.66",
    "地图生成自检.gd": "3 项：装饰/营地杂物密度（与玩法无关）",
    "副官自检.gd": "1 项：E 组工地落成（2026-11-13 基线复现，非本轮引入）",
}

# 耗时档（实测或估算）：只给 agent 一个"要不要现在跑"的量级
COST = {
    "配置回归.gd": "~15s",
    "寻路抖动自检.gd": "~20s",
    "地图生成自检.gd": "~30s",
    "副官自检.gd": "~80s",
    "战区指令自检.gd": "~40s",
    "AI基准.gd": "10 分钟起",
    "自动试玩.gd": "~60s",
}


def read(path: str) -> str:
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def first_doc(text: str) -> str:
    """取第一条 `##` 注释的前 60 字作职责。"""
    for line in text.splitlines()[:40]:
        line = line.strip()
        if line.startswith("##"):
            s = line.lstrip("#").strip()
            if s:
                return s[:70]
    return ""


def entry_of(name: str, text: str) -> str:
    m = re.search(r"启用[:：]\s*(.+)", text)
    if m:
        cmd = m.group(1).strip().strip("`")
        # 只保留 `--` 之后的部分，太长的话截断
        if "--" in cmd:
            tail = cmd.split("--", 1)[1]
            return "--" + tail.strip()
        return cmd[:50]
    if "--script" in text:
        return f"--script Tests/suites/{name}"
    return "主场景挂载（见文件头）"


def asserts_of(text: str) -> int:
    n = 0
    for pat in (r"\b_ok\(", r"\b_check\(", r"\b_check_eq\("):
        n += len(re.findall(pat, text))
    return n


def main() -> None:
    rows = []
    for fn in sorted(os.listdir(TEST_DIR)):
        if not fn.endswith(".gd"):
            continue
        path = os.path.join(TEST_DIR, fn)
        text = read(path)
        lines = text.count("\n") + 1
        rows.append(
            {
                "name": fn,
                "lines": lines,
                "entry": entry_of(fn, text),
                "asserts": asserts_of(text),
                "doc": first_doc(text),
                "red": KNOWN_RED.get(fn, ""),
                "cost": COST.get(fn, ""),
            }
        )

    out = [
        "# 测试索引（自动生成）",
        "",
        "> 由 `Tools/生成测试索引.py` 生成，**不要手改**。",
        "> 用途：跑验收前先在这里查「能不能 `--script` 跑 / 会红哪几项 / 要多久」。",
        "> `断言数` 是脚本里 `_ok(`/`_check(` 的**静态计数**（近似值，动态循环会少算），",
        "> 只用来看规模，不当精确项数。",
        "",
        "## 两种入口（跑之前先分清）",
        "",
        "| 入口 | 形式 | 能不能读到 `Game`/`Cfg` 单例 |",
        "|---|---|---|",
        "| 脚本入口 | `--script Tests/suites/xxx.gd` | **不能**（`--script` 在 autoload 注册前编译） |",
        "| 主场景入口 | `--headless --path . -- --xxx-test` | 能（主场景 `_mount_tests` 挂载） |",
        "",
        "> 所以：**凡是文件头写着「主场景挂载」的，不要用 `--script` 跑**，会报",
        "> `Identifier not found: Game`。这是本工程最常见的验收翻车点。",
        "",
        "## 清单",
        "",
        "| 脚本 | 行数 | 断言(近似) | 入口 | 用途 | 已知常红 | 耗时 |",
        "|---|---:|---:|---|---|---|---|",
    ]
    for r in rows:
        out.append(
            "| `{name}` | {lines} | {asserts} | `{entry}` | {doc} | {red} | {cost} |".format(**r)
        )

    out += [
        "",
        "## 按目的挑自检",
        "",
        "| 你改了什么 | 先跑这个 |",
        "|---|---|",
        "| 单位移动 / 寻路 | `寻路抖动自检` + `寻路自检` |",
        "| 战斗 / 射程 | `战斗自检` + `射程标定` |",
        "| 界面 / HUD | `界面自检` |",
        "| 建造 / 生产 | `建造自检` + `配置回归` |",
        "| AI 决策 | `副官自检` + `战区指令自检` + `AI基准`（10 分钟） |",
        "| 人群层 | `人群演示 --crowd-bench=1000 --crowd-secs=8` |",
        "| 新增单位/建筑卡 | `配置回归`（卡校验在最前） |",
        "| 地图 / 地形 | `地图生成自检` + `--qa-terrain` |",
        "| 动画 / 美术 | `动画验收` + `动作截图` |",
        "",
    ]

    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print("写出：", OUT)
    print("脚本数：", len(rows))


if __name__ == "__main__":
    main()
