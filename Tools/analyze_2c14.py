# -*- coding: utf-8 -*-
"""2C-14 归因分析：9 局 = A(dept=off) / B(dept=on,goal=on) / C(dept=on,goal=off) × s1..s3。

判读规则（任务书）：3 局只作方向，不称显著。
  先比 B vs A（整体是否赢主线），再比 B vs C（目标层相对 2C-12 路径的增量）。
  不得用「过 2C-11 off 90%」代替「比主线好」。

★ 2C-15 口径同步（与 工具/analyze_2c13.py 一致；纯观测，不改游戏运行代码）：
  - C2：储备充足率改名「金币≥G(t)周期占比」并改 AI-only；旧 json 无新字段 / dept=off 落
    "N/A" → None（sval 输出 N/A、avg 自动跳过），不回退旧混合口径、也不拿 0 凑数。
  - C3：主「达成率」/「波次」改为 **AI-only**（过滤「玩家」阵营），混合口径改名
    「达成率_混合」/「波次_混合」保留为附列。waves_of() / wave_rates() 与
    analyze_2c13.py 同一处定义；历史数值不得跨口径直接比较。
"""
import glob
import json
import os
import re
import statistics

QA = r"E:/简易rts/_qa"
OUT = r"E:/算法/_2c14_backup"
LOGDIR = os.path.join(OUT, "logs")
GROUPS = ["A", "B", "C"]
SWITCH_DESC = {"A": "--dept=off（2C-8 主线）",
               "B": "--dept=on --goal=on（2C-13 新架构）",
               "C": "--dept=on --goal=off（2C-12 原路径，含承诺表）"}
TAGS = {g: ["_2c14_attr_%s_s%d" % (g, s) for s in (1, 2, 3)] for g in GROUPS}
ALL_TAGS = [t for g in GROUPS for t in TAGS[g]]
SPEND_KINDS = ["训练", "建造", "修理", "建塔", "建分基地"]


def find_json(tag):
    hits = [p for p in glob.glob(os.path.join(QA, "bench_*.json"))
            if os.path.basename(p).endswith(tag + ".json")]
    return hits[0] if hits else None


def ai_only(curves):
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


def dept_sum(doc, key, ai_only_flag=False):
    tot = 0
    for f, d in (doc.get("dept") or {}).items():
        if ai_only_flag and "玩家" in f:
            continue
        if isinstance(d, dict):
            v = d.get(key, 0)
            if isinstance(v, (int, float)):
                tot += v
    return tot


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


def noop_audit(tag):
    """L3 逐周期核对：空过周期里有没有花钱动作被执行。"""
    rows = read_log(tag)
    if not rows:
        return {"有日志": False, "行数": 0}
    noop = [r for r in rows if bool(r.get("空过"))]
    spend = []
    kinds = {}
    for r in noop:
        for e in (r.get("执行") or []):
            act = str(e).split("·")[-1]
            kinds[act] = kinds.get(act, 0) + 1
            if any(k in act for k in SPEND_KINDS):
                spend.append({"t": r.get("t"), "执行": e})
    return {"有日志": True, "行数": len(rows), "空过周期": len(noop),
            "空过占比_日志": round(len(noop) / max(len(rows), 1), 4),
            "空过花钱执行数": len(spend), "空过执行种类": kinds,
            "违规样例": spend[:5]}


def run_log_info(tag):
    p = os.path.join(LOGDIR, tag + ".log")
    if not os.path.exists(p):
        return {"log": False}
    with open(p, "r", encoding="utf-8", errors="ignore") as fh:
        txt = fh.read()
    return {"log": True, "SCRIPT_ERROR_日志": txt.count("SCRIPT ERROR"),
            "ParseError": txt.count("Parse Error"),
            "bytes": os.path.getsize(p)}


def done_line(tag):
    p = os.path.join(LOGDIR, "longrun_2c14.log")
    if not os.path.exists(p):
        return {}
    with open(p, "r", encoding="utf-8", errors="ignore") as fh:
        for ln in fh:
            if "DONE tag=%s " % tag in ln:
                m = re.search(r"exit=(\d+).*wall=(\d+)s SCRIPT_ERROR=(\d+)", ln)
                if m:
                    return {"exit": int(m.group(1)), "wall_s": int(m.group(2)),
                            "SCRIPT_ERROR_DONE": int(m.group(3)), "raw": ln.strip()}
    return {}


def waves_of(doc, only_ai=True):
    """★ 2C-15 / C3：默认只取 AI 阵营；only_ai=False 时保留历史的 AI+玩家混合口径。"""
    out = []
    for f, wr in (doc.get("wave_records") or {}).items():
        if only_ai and "玩家" in str(f):
            continue
        out.extend((wr or {}).get("waves") or [])
    return out


def wave_rates(doc):
    """双口径达成率：主列 AI-only，混合列为附列（与 analyze_2c13.py 共用同一处定义）。"""
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


rows = []
for g in GROUPS:
    for tag in TAGS[g]:
        p = find_json(tag)
        if not p:
            rows.append({"tag": tag, "组": g, "status": "缺失"})
            continue
        with open(p, encoding="utf-8") as fh:
            d = json.load(fh)
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
        ws = wave_rates(d)
        lr = read_log(tag)
        gt = [float(r.get("储备") or 0) for r in lr]
        unitc = [float(r.get("单件成本") or 0) for r in lr]
        sw = mon13.get("主目标切换序列") or []
        dem = dept_sum(d, "demands")
        exe = dept_sum(d, "executed")
        row = {
            "tag": tag, "组": g, "status": "ok", "seed": d.get("seed"),
            "dept": d.get("dept_mode"), "goal": d.get("goal_mode"),
            "promise_switch": mon12.get("promise_switch"),
            "wall_s": d.get("wall_clock_s"), "elapsed": d.get("elapsed_game_s"),
            "cap末": last_curve(d.get("army_curve"), "pop_cap"),
            "农场座数": max_curve(d.get("army_curve"), "farms"),
            "农场合计末": last_curve(d.get("army_curve"), "farms"),
            "兵末": last_curve(d.get("army_curve"), "army"),
            "诉求": dem, "执行": exe,
            "执行率": round(exe / max(dem, 1), 4),
            "驳回分布": rej, "零执行占比": zero_ratio,
            # ★ 2C-15：只读新字段；旧 bench json 无此字段、或 dept=off 落 "N/A" 时一律降到
            #   None（sval 输出 N/A、avg 自动跳过），绝不回退旧混合口径、也不拿 0 凑数。
            "金币≥G(t)周期占比": (mon11.get("金币≥G(t)周期占比")
                              if isinstance(mon11.get("金币≥G(t)周期占比"), (int, float))
                              else None),
            "金币≥G(t)周期数": mon11.get("金币≥G(t)周期数"),
            "总周期": mon11.get("总周期", 0),
            "储备不足驳回率": mon11.get("储备不足驳回率", 0.0),
            # --- 2C-13 目标层 ---
            "周期数": mon13.get("周期数", 0),
            "空过周期": mon13.get("空过周期", 0),
            "空过占比": mon13.get("空过周期占比", 0.0),
            "次目标晋升": mon13.get("次目标晋升次数", 0),
            "次目标为空周期": mon13.get("次目标为空周期", 0),
            "次目标为空占比": mon13.get("次目标为空占比", 0.0),
            "释放_达成": mon13.get("释放_达成", 0),
            "释放_过期": mon13.get("释放_过期", 0),
            "释放_被抢占": mon13.get("释放_被抢占", 0),
            "主目标分布": mon13.get("主目标分布", {}),
            "空过挡下诉求": mon13.get("空过挡下诉求", {}),
            "目标创建": mon13.get("目标创建数", 0),
            "1.5G退出": mon13.get("1.5×G退出次数", 0),
            "目标预留_清理前": mon13.get("局末剩余预留(清理前)", 0),
            "目标预留_清理前_bench实测": mon13.get("局末剩余预留(清理前_bench实测)", {}),
            "目标预留_清理后": mon13.get("局末剩余预留(清理后)", 0),
            # --- 2C-12 承诺表（C 组）---
            "承诺生成": mon12.get("承诺生成数", 0),
            "承诺执行": mon12.get("承诺执行数", 0),
            "承诺过期": mon12.get("承诺过期数", 0),
            "承诺表_清理前": mon12.get("局末残留(清理前)", 0),
            "承诺表_清理前_bench实测": mon12.get("局末残留(清理前_bench实测)", 0),
            "承诺表_清理后": mon12.get("局末残留(清理后)", 0),
            "可自由资源均值": mon12.get("可自由资源均值", 0),
            "切换条数": len(sw), "切换序列": sw,
            "G_t_中位": round(statistics.median(gt), 1) if gt else None,
            "G_t_最小": round(min(gt), 1) if gt else None,
            "G_t_最大": round(max(gt), 1) if gt else None,
            "单件成本中位": round(statistics.median(unitc), 1) if unitc else None,
            "L3": noop_audit(tag), "运行日志": run_log_info(tag),
            "DONE": done_line(tag),
        }
        row.update(ws)
        # dept=off(A) 无仲裁周期、goal=off(C) 无目标层、goal=on(B) 不参与承诺表：
        # 不适用的观测量一律置 None(N/A)，不许拿 0 混进均值或归因。
        if g == "A":
            for k_na in ["执行率", "金币≥G(t)周期占比", "储备不足驳回率", "诉求", "执行",
                         "空过占比", "次目标晋升", "次目标为空占比", "目标创建",
                         "目标预留_清理前", "承诺表_清理前", "切换条数", "零执行占比"]:
                row[k_na] = None
        elif g == "C":
            for k_na in ["空过占比", "次目标晋升", "次目标为空占比", "目标创建",
                         "目标预留_清理前", "切换条数"]:
                row[k_na] = None
        else:
            row["承诺表_清理前"] = None
        rows.append(row)

ok = [r for r in rows if r["status"] == "ok"]
by_g = {g: [r for r in ok if r["组"] == g] for g in GROUPS}

# ---------------- 逐局表 ----------------
HDR = ["tag", "组", "exit", "wall_s", "波次", "达成率", "达成率_混合", "cap末",
       "农场座数", "兵末", "执行率", "空过占比", "次目标晋升", "次目标为空占比",
       "金币≥G(t)周期占比", "SCRIPT_ERROR"]
def sval(v, dec=4):
    if v is None:
        return "N/A"
    if isinstance(v, float):
        if v.is_integer():
            return str(int(v))
        return ("%%.%df" % dec) % v
    return str(v)


print("%-22s %2s %5s %7s %5s %8s %13s %6s %9s %5s %7s %9s %10s %14s %11s %s"
      % tuple(HDR))
for r in rows:
    if r["status"] != "ok":
        print("%-22s %s" % (r["tag"], "缺失"))
        continue
    dn = r["DONE"] or {}
    print("%-22s %2s %5s %7s %5s %8s %13s %6s %9s %5s %7s %9s %10s %14s %11s %s" % (
        r["tag"], r["组"], dn.get("exit", "?"), dn.get("wall_s", "?"),
        sval(r["波次"]), sval(r["达成率"]), sval(r["达成率_混合"]),
        sval(r["cap末"]), sval(r["农场座数"]), sval(r["兵末"]),
        sval(r["执行率"]), sval(r["空过占比"]), sval(r["次目标晋升"]),
        sval(r["次目标为空占比"]), sval(r["金币≥G(t)周期占比"]),
        "%d/%d" % (r["运行日志"].get("SCRIPT_ERROR_日志", -1),
                   dn.get("SCRIPT_ERROR_DONE", -1))))

# ---------------- 三组均值 ----------------
KEYS = ["波次", "达成率", "达成率_混合", "cap末", "农场座数", "兵末", "执行率",
        "金币≥G(t)周期占比", "储备不足驳回率", "零执行占比", "诉求", "执行",
        "空过占比", "次目标晋升", "次目标为空占比", "目标创建",
        "目标预留_清理前", "承诺表_清理前", "G_t_中位", "切换条数"]


def avg(sel, k):
    vals = [float(r[k]) for r in sel
            if isinstance(r.get(k), (int, float)) and r.get(k) is not None]
    return round(sum(vals) / len(vals), 4) if vals else None


means = {g: {k: avg(by_g[g], k) for k in KEYS} for g in GROUPS}
print("\n=== 三组均值（n=3/组，只作方向，不称显著）===")
print("%-22s %10s %10s %10s" % ("指标", "A", "B", "C"))
for k in KEYS:
    print("%-22s %10s %10s %10s" % (
        k, sval(means["A"][k]), sval(means["B"][k]), sval(means["C"][k])))

# ---------------- 归因 ----------------
def cmp(b, a, k):
    va, vb = means[a][k], means[b][k]
    if va is None or vb is None:
        return {"A或B缺失": True}
    return {"基准": va, "对比": vb, "差值": round(vb - va, 4),
            "相对": round((vb - va) / abs(va), 4) if va else None}


ATTR_KEYS = ["cap末", "农场座数", "波次", "达成率", "达成率_混合",
             "执行率", "兵末", "金币≥G(t)周期占比", "G_t_中位"]
attr = {"B_vs_A": {k: cmp("B", "A", k) for k in ATTR_KEYS},
        "B_vs_C": {k: cmp("B", "C", k) for k in ATTR_KEYS}}
print("\n=== B vs A（整体是否赢主线）===")
for k, v in attr["B_vs_A"].items():
    print("  %-16s %s" % (k, json.dumps(v, ensure_ascii=False)))
print("=== B vs C（目标层相对 2C-12 路径的增量）===")
for k, v in attr["B_vs_C"].items():
    print("  %-16s %s" % (k, json.dumps(v, ensure_ascii=False)))

# ---------------- 硬门禁 ----------------
gates = {}
for g in GROUPS:
    sel = by_g[g]
    exits = [(r["DONE"] or {}).get("exit") for r in sel]
    serr = [r["运行日志"].get("SCRIPT_ERROR_日志", -1) for r in sel]
    gates["%s_exit全0" % g] = len(sel) == 3 and all(e == 0 for e in exits)
    gates["%s_SCRIPT_ERROR全0" % g] = len(sel) == 3 and all(s == 0 for s in serr)
    gates["%s_局数" % g] = len(sel)

for g in ["B", "C"]:
    sel = by_g[g]
    if g == "B":
        before = [r["目标预留_清理前"] for r in sel]
        after = [r["目标预留_清理后"] for r in sel]
    else:
        before = [r["承诺表_清理前"] for r in sel]
        after = [r["承诺表_清理后"] for r in sel]
    gates["%s_预留清理前合计" % g] = sum(before)
    gates["%s_预留清理前全0" % g] = all(v == 0 for v in before)
    gates["%s_预留清理后合计" % g] = sum(after)
    gates["%s_预留清理后全0" % g] = all(v == 0 for v in after)
    gates["%s_明细_清理前" % g] = before

noop_viol = 0
noop_cyc = 0
for r in ok:
    l3 = r["L3"] or {}
    if l3.get("有日志"):
        noop_viol += l3.get("空过花钱执行数", 0)
        noop_cyc += l3.get("空过周期", 0)
gates["空过周期总数"] = noop_cyc
gates["空过期间花钱动作"] = noop_viol
gates["空过停花钱_过"] = noop_viol == 0

print("\n=== 硬门禁 ===")
for k, v in gates.items():
    print("  %-28s %s" % (k, v))

# ---------------- 切换序列人工判读素材 ----------------
print("\n=== 主目标切换序列（每组 s1 前 30 条，人工判读用）===")
for g in GROUPS:
    sel = [r for r in by_g[g] if r["tag"].endswith("_s1")]
    for r in sel:
        if r["切换条数"] is None:
            print("[%s] N/A（该组无目标层，无切换序列）" % r["tag"])
            continue
        print("[%s] %d 条" % (r["tag"], r["切换条数"]))
        for s in r["切换序列"][:30]:
            print("   t=%-7s %-8s → %-8s %-8s %s" % (
                s.get("t"), s.get("from") or "-", s.get("to") or "空过",
                s.get("阵营", ""), s.get("原因", "")))

with open(os.path.join(OUT, "longrun_summary_2c14.json"), "w", encoding="utf-8") as fh:
    json.dump({"rows": rows, "means": means, "attr": attr, "gates": gates,
               "switch_desc": SWITCH_DESC}, fh, ensure_ascii=False, indent=2, default=str)
print("\nWROTE", os.path.join(OUT, "longrun_summary_2c14.json"))
