# -*- coding: utf-8 -*-
"""2C-13 长局分析（2C-15 起「达成率」主口径改为 **AI-only**）。

用法（在工程根目录或任意目录均可，路径都写死为绝对路径）：
  python 工具/analyze_2c13.py              # 2C-13 四局主分析（判硬 + 观察）
  python 工具/analyze_2c13.py --history    # 重算 2C-11~2C-14 历史基线，双口径并列

判硬（任务书 §8）：
  1) 农场座数、cap 末 不低于 2C-11 off（2.0 / 108）的 90%  → ≥1.8 / ≥97.2
  2) 局末预留总额 = 0（清理后；清理前的剩余单列）
  3) 空过期间花钱动作 0 执行（用 L3 日志逐周期数，不靠结构推断）
  4) SCRIPT ERROR = 0
观察：空过占比 / 主目标分布 / 次目标晋升 / 释放原因 / G(t) / 1.5×G 退出 / 切换序列。

★ 2C-15 口径修正（**纯观测，不改游戏运行代码**）：
  - 旧 `waves_of()` 遍历 `wave_records` 全部 key，**含「玩家」阵营**（副官），
    而同文件 `ai_only()` 在曲线里已经过滤了玩家 → 历史「达成率」是 AI+玩家混合口径。
  - 现在 `waves_of(doc, only_ai=True)` 默认只取 AI 阵营；主列「达成率」= AI-only，
    混合口径改名「达成率_混合」保留为附列；「波次」同步为 AI-only，「波次_混合」单列。
  - `history_baseline()` 与 2C-13 主分析共用同一个 `waves_of()` / `wave_rates()`，
    重算 2C-11~2C-14 全部正式长局，两种口径并列输出。
"""
import glob
import json
import os
import re
import statistics
import sys

QA = r"E:/简易rts/_qa"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = r"E:/算法/_2c13_backup"
LOGDIR = os.path.join(OUT, "logs")
HIST_OUT = os.path.join(REPO, "工具", "历史基线_达成率_双口径.md")

TAGS = ["_2c13_v2_on_s1", "_2c13_v2_on_s2", "_2c13_v2_off_s1", "_2c13_v2_off_s2"]

# 2C-11 off 基线（任务书 §8 给的判硬锚点）
BASE_2C11_OFF = {"农场座数": 2.0, "cap末": 108.0}
BASE_2C12_OFF = {"农场座数": 2.5, "cap末": 112.0}
BASE_2C12_ON = {"农场座数": 1.333, "cap末": 98.667}


def find_json(tag):
    hits = [p for p in glob.glob(os.path.join(QA, "bench_*.json"))
            if os.path.basename(p).endswith(tag + ".json")]
    return hits[0] if hits else None


def ai_only(curves):
    """阵营曲线只取 AI（"玩家" 不进任何分母）。达成率过滤与这里保持同一口径。"""
    return {k: v for k, v in (curves or {}).items() if "玩家" not in k}


def last_curve(curves, key, default=0):
    tot = 0
    for _f, pts in ai_only(curves).items():
        if isinstance(pts, list) and pts:
            tot += float(pts[-1].get(key, default) or 0)
    return tot


def max_curve(curves, key, default=0):
    best = 0.0
    for _f, pts in ai_only(curves).items():
        if isinstance(pts, list) and pts:
            best = max(best, max(float(p.get(key, default) or 0) for p in pts))
    return round(best, 3)


def dept_sum(doc, key):
    tot = 0
    for _f, d in (doc.get("dept") or {}).items():
        if isinstance(d, dict):
            v = d.get(key, 0)
            if isinstance(v, (int, float)):
                tot += v
    return tot


def waves_of(doc, only_ai=True):
    """★ 2C-15：默认只取 AI 阵营；only_ai=False 时保留历史的 AI+玩家混合口径。"""
    out = []
    for f, wr in (doc.get("wave_records") or {}).items():
        if only_ai and "玩家" in str(f):
            continue
        out.extend((wr or {}).get("waves") or [])
    return out


def wave_rates(doc):
    """双口径达成率，主分析与历史基线重算共用这一处定义。"""
    ai = waves_of(doc, True)
    mix = waves_of(doc, False)
    a_ai = sum(1 for r in ai if bool(r.get("goal_achieved", False)))
    a_mix = sum(1 for r in mix if bool(r.get("goal_achieved", False)))
    return {
        "波次": len(ai), "达成": a_ai,
        "达成率": round(a_ai / max(len(ai), 1), 4),
        "波次_混合": len(mix), "达成_混合": a_mix,
        "达成率_混合": round(a_mix / max(len(mix), 1), 4),
    }


def read_log(tag):
    p = os.path.join(QA, "dept_%s.jsonl" % tag)
    if not os.path.exists(p):
        return []
    rows = []
    with open(p, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                rows.append(json.loads(ln))
            except json.JSONDecodeError:
                pass
    return rows


SPEND_KINDS = ["训练", "建造", "修理", "建塔", "建分基地"]


def noop_audit(tag):
    """用 L3 日志逐周期核对：空过周期里有没有花钱动作被执行。"""
    rows = read_log(tag)
    if not rows:
        return {"有日志": False}
    noop = [r for r in rows if bool(r.get("空过"))]
    spend = []
    kinds = {}
    for r in noop:
        for e in (r.get("执行") or []):
            act = str(e).split("·")[-1]
            kinds[act] = kinds.get(act, 0) + 1
            if any(k in act for k in SPEND_KINDS):
                spend.append({"t": r.get("t"), "执行": e})
    return {
        "有日志": True, "周期": len(rows), "空过周期": len(noop),
        "空过占比_日志": round(len(noop) / max(len(rows), 1), 4),
        "空过花钱执行数": len(spend), "空过执行种类": kinds,
        "违规样例": spend[:5],
        "空过主目标紧迫度": sorted({round(float(r.get("主目标紧迫度") or 0), 2)
                              for r in noop})[-5:],
        "非空过主目标": sorted({str(r.get("主目标动作") or "-") for r in rows
                          if not r.get("空过")}),
    }


def avg(sel, k):
    vals = [float(r[k]) for r in sel if isinstance(r.get(k), (int, float))]
    return round(sum(vals) / len(vals), 4) if vals else None


def main_2c13():
    rows = []
    for tag in TAGS:
        p = find_json(tag)
        if not p:
            rows.append({"tag": tag, "status": "缺失"})
            continue
        with open(p, encoding="utf-8") as fh:
            d = json.load(fh)
        rates = wave_rates(d)
        mon13 = d.get("monitor_2c13") or {}
        mon12 = d.get("monitor_2c12") or {}
        mon11 = d.get("monitor_2c11") or {}
        rej = {}
        for _f, dd in (d.get("dept") or {}).items():
            for k, v in (dd.get("reject_by_reason") or {}).items():
                rej[k] = rej.get(k, 0) + int(v)
        dist = {}
        for _f, dd in (d.get("dept") or {}).items():
            for k, v in (dd.get("exec_per_cycle") or {}).items():
                dist[k] = dist.get(k, 0) + int(v)
        n_cyc = sum(dist.values())
        zero_ratio = (dist.get("0", 0) / n_cyc) if n_cyc else None

        logp = os.path.join(LOGDIR, tag + ".log")
        serr = 0
        if os.path.exists(logp):
            with open(logp, "r", encoding="utf-8", errors="ignore") as fh:
                serr = sum(1 for ln in fh if "SCRIPT ERROR" in ln)

        gt = [float(r.get("储备") or 0) for r in read_log(tag)]
        unitc = [float(r.get("单件成本") or 0) for r in read_log(tag)]

        sw = mon13.get("主目标切换序列") or []
        row = {
            "tag": tag, "status": "ok", "seed": d.get("seed"),
            "dept": d.get("dept_mode"), "goal": d.get("goal_mode"),
            "wall_s": d.get("wall_clock_s"), "elapsed": d.get("elapsed_game_s"),
            "cap末": last_curve(d.get("army_curve"), "pop_cap"),
            "农场座数": max_curve(d.get("army_curve"), "farms"),
            "农场合计末": last_curve(d.get("army_curve"), "farms"),
            "兵末": last_curve(d.get("army_curve"), "army"),
            "诉求": dept_sum(d, "demands"), "执行": dept_sum(d, "executed"),
            "驳回": rej, "SCRIPT_ERROR": serr,
            "储备不足驳回率": mon11.get("储备不足驳回率", 0.0),
            # ★ 2C-15：只读新字段；旧 json 无此字段 / dept=off 落 "N/A" → None（不回退旧混合口径、不报 0）
            "金币≥G(t)周期占比": (mon11.get("金币≥G(t)周期占比")
                              if isinstance(mon11.get("金币≥G(t)周期占比"), (int, float))
                              else None),
            "金币≥G(t)周期数": mon11.get("金币≥G(t)周期数"),
            "总周期": mon11.get("总周期", 0),
            "零执行占比": zero_ratio,
            # --- 2C-13 目标层 ---
            "周期数": mon13.get("周期数", 0),
            "空过周期": mon13.get("空过周期", 0),
            "空过占比": mon13.get("空过周期占比", 0.0),
            "目标创建": mon13.get("目标创建数", 0),
            "次目标晋升": mon13.get("次目标晋升次数", 0),
            "释放_达成": mon13.get("释放_达成", 0),
            "释放_过期": mon13.get("释放_过期", 0),
            "释放_被抢占": mon13.get("释放_被抢占", 0),
            "释放原因分布": mon13.get("释放原因分布", {}),
            "主目标分布": mon13.get("主目标分布", {}),
            "空过挡下诉求": mon13.get("空过挡下诉求", {}),
            "1.5G退出": mon13.get("1.5×G退出次数", 0),
            "积极储蓄周期": mon13.get("空过积极储蓄周期", 0),
            "金≥1.5G周期": mon13.get("空过金币≥1.5G周期", 0),
            "预留末值": mon13.get("预留末值合计", 0),
            "预留清理前": mon13.get("局末剩余预留(清理前)", 0),
            "预留清理后": mon13.get("局末剩余预留(清理后)", 0),
            "WS写入": mon13.get("世界状态写入次数(最大)", 0),
            "WS字段": mon13.get("世界状态字段数(最小)", 0),
            "区域数": mon13.get("区域数末值合计", 0),
            "切换条数": len(sw),
            "切换序列": sw,
            "G_t_中位": round(statistics.median(gt), 1) if gt else None,
            "G_t_最小": round(min(gt), 1) if gt else None,
            "G_t_最大": round(max(gt), 1) if gt else None,
            "单件成本中位": round(statistics.median(unitc), 1) if unitc else None,
            "L3": noop_audit(tag),
            "承诺生成": mon12.get("承诺生成数", 0),
            "承诺执行": mon12.get("承诺执行数", 0),
            "可自由资源均值": mon12.get("可自由资源均值", 0),
            "monitor13": mon13,
        }
        row.update(rates)  # 波次/达成/达成率（AI-only）+ 波次_混合/达成_混合/达成率_混合
        rows.append(row)
        rows[-1]["执行率"] = round(rows[-1]["执行"] / max(rows[-1]["诉求"], 1), 4)

    ok = [r for r in rows if r["status"] == "ok"]
    on = [r for r in ok if r.get("dept") == "on"]
    off = [r for r in ok if r.get("dept") == "off"]

    hdr = ["tag", "dept", "goal", "wall_s", "波次", "达成率", "达成率_混合", "cap末", "农场座数",
           "空过占比", "次目标晋升", "预留清理前", "SCRIPT_ERROR"]
    print("%-14s %5s %5s %8s %5s %7s %11s %6s %8s %8s %10s %12s %12s" % tuple(hdr))
    for r in rows:
        if r["status"] != "ok":
            print("%-14s 缺失" % r["tag"])
            continue
        print("%-14s %5s %5s %8.0f %5d %7.3f %11.3f %6.0f %8.2f %8.3f %10d %12d %12d" % (
            r["tag"], r["dept"], r["goal"], r["wall_s"], r["波次"], r["达成率"], r["达成率_混合"],
            r["cap末"], r["农场座数"], r["空过占比"], r["次目标晋升"],
            r["预留清理前"], r["SCRIPT_ERROR"]))

    print("\n=== 分组均值（只统计 AI，不含玩家；两种口径并列）===")
    for label, sel in [("2C-13 on（2 局）", on), ("2C-13 off（2 局）", off)]:
        if not sel:
            continue
        print("%-18s n=%d 波次=%s 达成率(AI)=%s 达成率(混合)=%s cap末=%s 农场座数=%s 执行率=%s 空过占比=%s" % (
            label, len(sel), avg(sel, "波次"), avg(sel, "达成率"), avg(sel, "达成率_混合"),
            avg(sel, "cap末"), avg(sel, "农场座数"), avg(sel, "执行率"), avg(sel, "空过占比")))

    print("\n=== 判硬 ===")
    judge = {}
    if on:
        farm = avg(on, "农场座数")
        cap = avg(on, "cap末")
        judge["农场座数"] = {"实测": farm, "门槛": 1.8, "过": farm >= 1.8,
                         "对比2C11off": round(farm / BASE_2C11_OFF["农场座数"] - 1, 4)}
        judge["cap末"] = {"实测": cap, "门槛": 97.2, "过": cap >= 97.2,
                         "对比2C11off": round(cap / BASE_2C11_OFF["cap末"] - 1, 4)}
        leak = sum(int(r["预留清理后"]) for r in on)
        leak_before = sum(int(r["预留清理前"]) for r in on)
        judge["预留泄漏"] = {"清理后": leak, "清理前": leak_before, "过": leak == 0}
        viol = sum(int((r["L3"] or {}).get("空过花钱执行数", 0)) for r in on
                   if (r["L3"] or {}).get("有日志"))
        noop_cyc = sum(int((r["L3"] or {}).get("空过周期", 0)) for r in on
                       if (r["L3"] or {}).get("有日志"))
        judge["空过停花钱"] = {"空过周期": noop_cyc, "违规执行数": viol,
                           "过": viol == 0, "空过占比": avg(on, "空过占比")}
        judge["SCRIPT_ERROR"] = {"实测": sum(int(r["SCRIPT_ERROR"]) for r in ok),
                                 "过": sum(int(r["SCRIPT_ERROR"]) for r in ok) == 0}
    for k, v in judge.items():
        print("%-10s %s" % (k, json.dumps(v, ensure_ascii=False)))

    print("\n=== 观察项 ===")
    for r in on:
        print("\n[%s] 主目标切换序列（%d 条）:" % (r["tag"], len(r["切换序列"])))
        for s in r["切换序列"][:40]:
            print("   t=%-6s %-8s → %-8s %s" % (s.get("t"), s.get("from") or "-",
                                              s.get("to") or "空", s.get("原因")))
        if len(r["切换序列"]) > 40:
            print("   ... 其余 %d 条见 json" % (len(r["切换序列"]) - 40))
        print(" 主目标分布:", json.dumps(r["主目标分布"], ensure_ascii=False))
        print(" 释放原因:", json.dumps(r["释放原因分布"], ensure_ascii=False),
              " 空过挡下:", json.dumps(r["空过挡下诉求"], ensure_ascii=False))
        print(" G(t) 中位=%s 区间[%s,%s] 单件成本中位=%s 1.5G退出=%d" % (
            r["G_t_中位"], r["G_t_最小"], r["G_t_最大"], r["单件成本中位"], r["1.5G退出"]))
        print(" 金币≥G(t)周期占比=%s 周期数=%s / 总周期=%s" % (
            r["金币≥G(t)周期占比"], r["金币≥G(t)周期数"], r["总周期"]))
        print(" L3:", json.dumps({k: v for k, v in (r["L3"] or {}).items()
                                  if k not in ("违规样例",)}, ensure_ascii=False))

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "longrun_summary_2c13.json"), "w", encoding="utf-8") as fh:
        json.dump({"rows": rows, "judge": judge,
                   "avg": {"on": {k: avg(on, k) for k in
                                  ["波次", "达成率", "达成率_混合", "cap末", "农场座数", "执行率",
                                   "空过占比", "次目标晋升", "预留清理前"]},
                           "off": {k: avg(off, k) for k in
                                   ["波次", "达成率", "达成率_混合", "cap末", "农场座数", "执行率"]}}},
                  fh, ensure_ascii=False, indent=2, default=str)
    print("\nWROTE", os.path.join(OUT, "longrun_summary_2c13.json"))


# ---------------------------------------------------------------------------
# 2C-15：历史基线重算（与上面主分析共用 waves_of() / wave_rates()）
# ---------------------------------------------------------------------------
GROUP_ORDER = [
    "2C-11 off", "2C-11 on",
    "2C-12 off", "2C-12 on",
    "2C-13 off", "2C-13 on",
    "2C-14 A (dept=off)", "2C-14 B (on+goal=on)", "2C-14 C (on,goal=off)",
]

# 只纳入 10 分钟正式长局（墙钟 >= 400 s），smoke / thr095 / goff / deptoff 等短局一律排除。
MIN_WALL_S = 400.0


def group_of(tag):
    t = tag.lower()
    if "2c14" in t:
        if re.search(r"2c14_attr_a_s[123]", t):
            return "2C-14 A (dept=off)"
        if re.search(r"2c14_attr_b_s[123]", t):
            return "2C-14 B (on+goal=on)"
        if re.search(r"2c14_attr_c_s[123]", t):
            return "2C-14 C (on,goal=off)"
        return None
    if "2c13_v2_off" in t:
        return "2C-13 off"
    if "2c13_v2_on" in t:
        return "2C-13 on"
    if "2c11" in t:
        return "2C-11 off" if "off" in t else "2C-11 on"
    if "2c12" in t:
        return "2C-12 off" if "off" in t else "2C-12 on"
    return None


def history_baseline():
    per_game = []
    for p in sorted(glob.glob(os.path.join(QA, "bench_*.json"))):
        base = os.path.basename(p)
        tag = base[len("bench_"):-len(".json")]
        g = group_of(tag)
        if g is None:
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        wall = d.get("wall_clock_s")
        if not isinstance(wall, (int, float)) or wall < MIN_WALL_S:
            continue
        if not (d.get("wave_records") or {}):
            continue
        r = wave_rates(d)
        per_game.append({"tag": tag, "组": g, "dept": d.get("dept_mode"),
                         "wall_s": wall, **r})

    def mean(sel, k):
        vals = [float(x[k]) for x in sel]
        return round(sum(vals) / len(vals), 4) if vals else None

    lines = [
        "# 2C-11~2C-14 历史基线重算（达成率 AI-only vs 混合口径）",
        "",
        "> 生成：`python 工具/analyze_2c13.py --history`（与主分析共用 `waves_of()` / `wave_rates()`）。",
        "> 口径：AI-only 过滤 `wave_records` 里 key 含「玩家」的阵营；混合口径 = 全部 key（历史旧口径）。",
        "> 样本：只取墙钟 ≥ %.0f s 的 10 分钟正式长局，排除 smoke / thr095 / goff / deptoff 等短局。" % MIN_WALL_S,
        "> **只重算观测口径，游戏运行代码一行未改；历史报告里的混合口径数值不作废，保留为附列对照。**",
        "",
        "## 一、分组均值（主口径 = AI-only）",
        "",
        "| 组 | n | 波次(AI) | 达成(AI) | **达成率 AI-only** | 波次(混合) | 达成(混合) | 达成率 混合 | 差值 AI−混合 |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for g in GROUP_ORDER:
        sel = [x for x in per_game if x["组"] == g]
        if not sel:
            continue
        ai, mix = mean(sel, "达成率"), mean(sel, "达成率_混合")
        lines.append("| %s | %d | %s | %s | **%s** | %s | %s | %s | %s |" % (
            g, len(sel), mean(sel, "波次"), mean(sel, "达成"), ai,
            mean(sel, "波次_混合"), mean(sel, "达成_混合"), mix,
            round(ai - mix, 4) if ai is not None and mix is not None else "N/A"))

    lines += [
        "",
        "## 二、逐局明细（双口径并列）",
        "",
        "| tag | 组 | dept | 墙钟 s | 波次(AI) | 达成(AI) | 达成率 AI-only | 波次(混合) | 达成(混合) | 达成率 混合 |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for x in sorted(per_game, key=lambda v: (GROUP_ORDER.index(v["组"]), v["tag"])):
        lines.append("| %s | %s | %s | %.0f | %d | %d | %.4f | %d | %d | %.4f |" % (
            x["tag"], x["组"], x["dept"], x["wall_s"],
            x["波次"], x["达成"], x["达成率"],
            x["波次_混合"], x["达成_混合"], x["达成率_混合"]))

    lines += [
        "",
        "## 三、口径说明",
        "",
        "- 「达成率」历史值 = `Σ goal_achieved / Σ waves`，分子分母都含玩家阵营，是 **AI+玩家混合口径**；",
        "  2C-14 报告 §7.1 已发现此 bug 但未改，本表把它固定为附列 `达成率_混合`。",
        "- 2C-15 起主口径 = **AI-only**（`\"玩家\" not in key`），与 `ai_only()` 曲线口径一致。",
        "- 「波次」同步改为 AI-only；`波次_混合` 单列，避免分母口径混用。",
        "- 两组差值来自同一批 bench json 的同一函数，未重跑任何长局。",
        "",
    ]
    txt = "\n".join(lines)
    with open(HIST_OUT, "w", encoding="utf-8") as fh:
        fh.write(txt)
    print(txt)
    print("\nWROTE", HIST_OUT)


if __name__ == "__main__":
    if "--history" in sys.argv:
        history_baseline()
    else:
        main_2c13()
