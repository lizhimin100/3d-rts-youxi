#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生产队列空转诊断（2C-1）。

输入（全部来自 bench，不需要改任何 AI 代码）：
  --bench      _qa/bench_A_1<tag>.json      AI基准 输出
  --situations _qa/situations_<tag>.jsonl   --dump-situations 输出（5 s 粒度）
  --probe      _qa/prod_<tag>.jsonl         可选：--prod-probe 临时探针输出

输出：队列空转时长、四个假设的确认/排除、金币 vs 有效门槛对照、过滤原因分布。

为什么需要"有效门槛"这一列：
  `_can_spend()` 要求"花完还剩 reserve_gold"，所以最便宜兵 130 金 +
  保留 150 金 = **有效门槛 280 金**，而不是标称的 130。只看标称成本会把
  "买得起但过不了闸"误判成"钱不够"。本脚本把两个门槛并排列出。
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict

# 单位表（代码/配置/单位表.gd）里的金币/木材成本；诊断只读，不参与决策
COST = {
    "peasant": (75, 0), "footman": (135, 0), "archer": (130, 15),
    "mage": (155, 45), "steam_guard": (190, 45),
}
PROD_ID = ["townhall", "barracks", "sanctum", "workshop"]
# 难度档（镜像 代码/配置/单位表.gd build_difficulties()；bench json 里只存 index）
DIFF = [
    ("easy", 10, 6, {"footman": 5, "archer": 3, "mage": 1}),
    ("normal", 16, 8, {"footman": 5, "archer": 4, "mage": 2, "steam_guard": 1}),
    ("hard", 24, 10, {"footman": 6, "archer": 5, "mage": 3, "steam_guard": 2}),
]


def load_bench(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_jsonl(path):
    out, bad = [], 0
    if not path or not os.path.exists(path):
        return out, bad
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                bad += 1
    return out, bad


def cheapest(composition):
    ids = [i for i in composition if i in COST]
    if not ids:
        ids = ["footman"]
    return min(COST[i][0] for i in ids), min(ids, key=lambda i: COST[i][0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", required=True)
    ap.add_argument("--situations", default="")
    ap.add_argument("--probe", default="")
    ap.add_argument("--faction", default="AI·1队")
    a = ap.parse_args()

    b = load_bench(a.bench)
    elapsed = float(b.get("elapsed_game_s") or 0.0)
    idx = int(b.get("difficulty") or 0)
    dname, max_army, tgt_p, comp = DIFF[idx] if 0 <= idx < len(DIFF) else DIFF[0]
    cg, cid = cheapest(comp)
    reserve = 150  # Cfg.game.ai_reserve_gold（诊断页写死：探针记录的是运行期真值）

    print("=" * 78)
    print("生产队列空转诊断  bench=%s  时长=%.0f 游戏秒" % (os.path.basename(a.bench), elapsed))
    print("难度=%s  max_army=%d  target_peasants=%d  最便宜兵=%s(%d 金)"
          % (dname, max_army, tgt_p, cid, cg))
    print("有效门槛 = 兵价 + 保留金 = %d + %d = %d 金" % (cg, reserve, cg + reserve))
    print("=" * 78)

    # ---- 1. 空转时长 ----
    print("\n[1] 队列空转（有已完工产能 + 队列全空 + 金币 ≥130）")
    for name, s in b.get("factions", {}).items():
        idle = float(s.get("prod_idle_seconds") or 0.0)
        pct = 100.0 * idle / elapsed if elapsed else 0.0
        print("  %-8s %7.1f s / %4.0f s  = %5.1f%%   波次=%-2s 末兵力=%-3s 金收入=%s"
              % (name, idle, elapsed, pct, s.get("wave_count"), s.get("army_n_last"),
                 s.get("gold_income")))

    # ---- 2. 情况文本：金币/人口/计划 ----
    sits, bad = load_jsonl(a.situations)
    print("\n[2] 情况文本（%d 条，坏行 %d）" % (len(sits), bad))
    if sits:
        rows = [r for r in sits if r.get("faction") == a.faction and r.get("tag") == "periodic"]
        if rows:
            golds = [r["own_summary"]["gold"] for r in rows]
            woods = [r["own_summary"]["wood"] for r in rows]
            foods = [(r["own_summary"]["food_used"], r["own_summary"]["food_cap"]) for r in rows]
            plans = Counter(r["posture"].get("plan_id", "?") for r in rows)
            armies = [r["own_summary"]["army"] for r in rows]
            print("  %s：金币 %d~%d（中位 %d） 木 %d~%d  人口 %d/%d ~ %d/%d"
                  % (a.faction, min(golds), max(golds), sorted(golds)[len(golds) // 2],
                     min(woods), max(woods), foods[0][0], foods[0][1], foods[-1][0], foods[-1][1]))
            print("  兵力 %d → %d   plan 分布 %s" % (armies[0], armies[-1], dict(plans)))
            reached = sum(1 for g in golds if g >= cg + reserve)
            print("  金币曾达到'有效门槛 %d'的采样点：%d / %d"
                  % (cg + reserve, reached, len(golds)))

    # ---- 3. 四假设 ----
    print("\n[3] 四个假设")
    verdict = {}

    golds = [r["own_summary"]["gold"] for r in sits
             if r.get("faction") == a.faction and r.get("tag") == "periodic"] if sits else []
    if golds:
        affordable = sum(1 for g in golds if g >= cg)
        effective = sum(1 for g in golds if g >= cg + reserve)
        verdict["H1"] = ("部分确认",
                         "金币 < 兵价(%d) 的采样点 %d/%d；但过不了'有效门槛 %d' 的采样点 %d/%d"
                         % (cg, len(golds) - affordable, len(golds), cg + reserve,
                            len(golds) - effective, len(golds)))
    else:
        verdict["H1"] = ("无数据", "缺 --situations")

    if sits and golds:
        worst_margin = min(c - (u + rsv) for u, c in foods for rsv in [0])
        verdict["H2"] = ("排除" if worst_margin >= 1 else "部分确认",
                         "人口余量最小 %d（used+reserved 最坏 -cap）" % worst_margin)
    else:
        verdict["H2"] = ("无数据", "缺 --situations")

    if sits:
        plans = sorted({r["posture"].get("plan_id", "?") for r in sits
                        if r.get("faction") == a.faction})
        cap_hit = 0
        probe_rows, _ = load_jsonl(a.probe)
        if probe_rows:
            cap_hit = sum(1 for r in probe_rows
                          if r.get("faction") == a.faction and r.get("tag") == "cap")
        h3 = "排除" if cap_hit == 0 else "确认（早退在 max_army 上）"
        verdict["H3"] = (h3, "plan 列表 %s（无'暂停训练'标志）；army 达上限(max_army=%d) 的 tick 数 %d"
                         % (plans, max_army, cap_hit))
    else:
        verdict["H3"] = ("无数据", "缺 --situations")

    probe_rows, pbad = load_jsonl(a.probe)
    if probe_rows:
        mine = [r for r in probe_rows if r.get("faction") == a.faction
                and r.get("bldg") == "barracks"]
        tags = Counter(r.get("tag") for r in mine)
        why = Counter()
        for r in mine:
            for w in r.get("why", []):
                why[w.split("(")[0]] += 1
        verdict["H4"] = ("确认（成本过滤把候选池清空）",
                         "兵营行 %d：pick_ok=%d pick_empty=%d；原因 %s"
                         % (len(mine), tags.get("pick_ok", 0), tags.get("pick_empty", 0),
                            dict(why.most_common(5))))
    else:
        verdict["H4"] = ("无数据", "缺 --probe（临时探针，不入库）")

    print("  %-4s %-26s %s" % ("假设", "结论", "证据"))
    for h, (v, e) in sorted(verdict.items()):
        print("  %-4s %-26s %s" % (h, v, e))

    print("\n[4] 结论口径")
    print("  空转 = 队列真空 + 钱在账上；'钱在账上'的判据必须是 **有效门槛**（兵价+保留金），")
    print("  不能用标称兵价 —— 否则'买得起但过不了保留金闸'会被误判成'钱不够'。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
