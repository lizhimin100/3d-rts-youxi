# -*- coding: utf-8 -*-
"""把一个 glb 里的**指定动作**合并进另一个 glb，原有动作一个不动。

为什么需要这个工具（2026-11-07 事故）：
  `工具/加举盾动作.py` 走的是 Blender「导入 → 新建 action → 导出 ACTIONS」，
  Blender 5.x 的 slotted action 在导出时**只正确写出了新建的那个 action**，
  其余 action 的骨骼旋转曲线被写成常量 —— 结果 `方块人_联盟步兵.glb` 里
  walk/attack/idle/hurt 全部退化成"胯部抖 2cm"，玩家看到的就是「所有动画都没了」。
  而 Blender 里是正常的，光看 Blender 永远查不出来。

所以改走**纯数据合并**：不经过 Blender，直接把动作的 sampler/accessor 原样搬过去。
  · 只认骨骼名字（两边的节点名必须一致，本工程都是同一套 rig）；
  · 搬过去的是**采样后的关键帧数据**，不存在"重新烘焙"这一步，所以不可能丢动作；
  · 写完自带校验：逐动作统计"真正在动的通道"，全静止就报错。

用法：
  python 工具/合并glb动作.py --base <基础.glb> --donor <提供动作.glb> \
      --names shield_hold[,shield_up] --out <输出.glb>

  # 只做体检（不改文件）：
  python 工具/合并glb动作.py --check <某个.glb>
"""
import argparse
import json
import math
import os
import struct
import sys

MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
        5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def read_glb(path):
    data = open(path, "rb").read()
    magic, ver, _length = struct.unpack_from("<III", data, 0)
    if magic != MAGIC:
        raise SystemExit("不是 GLB：%s" % path)
    off = 12
    js, binc = None, b""
    while off + 8 <= len(data):
        ln, ty = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + ln]
        if ty == CHUNK_JSON:
            js = json.loads(chunk.decode("utf-8"))
        elif ty == CHUNK_BIN:
            binc = chunk
        off += 8 + ln
    if js is None:
        raise SystemExit("GLB 里没有 JSON 块：%s" % path)
    return js, binc


def write_glb(path, js, binc):
    jb = json.dumps(js, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    bb = binc + b"\x00" * ((4 - len(binc) % 4) % 4)
    total = 12 + 8 + len(jb) + (8 + len(bb) if bb else 0)
    out = bytearray()
    out += struct.pack("<III", MAGIC, 2, total)
    out += struct.pack("<II", len(jb), CHUNK_JSON) + jb
    if bb:
        out += struct.pack("<II", len(bb), CHUNK_BIN) + bb
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)


def read_accessor(js, binc, idx):
    """返回 (componentType, type, [tuple...])，只支持紧密排列（动画数据都是）。"""
    a = js["accessors"][idx]
    bv = js["bufferViews"][a["bufferView"]]
    if bv.get("byteStride"):
        raise SystemExit("暂不支持 byteStride 的 accessor（动画不该有）")
    fmt, size = COMP[a["componentType"]]
    nc = NCOMP[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    vals = []
    for k in range(a["count"]):
        vals.append(struct.unpack_from("<" + fmt * nc, binc, start + k * size * nc))
    return a["componentType"], a["type"], vals


class Builder:
    """往目标 glb 的 bin 尾巴上追加 accessor / bufferView。"""

    def __init__(self, js, binc):
        self.js = js
        self.bin = bytearray(binc)
        js.setdefault("accessors", [])
        js.setdefault("bufferViews", [])
        if not js.get("buffers"):
            js["buffers"] = [{"byteLength": 0}]

    def add(self, component_type, acc_type, values):
        fmt, size = COMP[component_type]
        nc = NCOMP[acc_type]
        raw = bytearray()
        for v in values:
            raw += struct.pack("<" + fmt * nc, *v)
        while len(self.bin) % 4:
            self.bin.append(0)
        offset = len(self.bin)
        self.bin += raw
        bv_index = len(self.js["bufferViews"])
        self.js["bufferViews"].append({
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": len(raw),
        })
        acc = {
            "bufferView": bv_index,
            "componentType": component_type,
            "count": len(values),
            "type": acc_type,
        }
        if component_type == 5126 and values:
            for axis in range(nc):
                col = [float(v[axis]) for v in values]
                key = "min" if axis == 0 else None
                acc.setdefault("min", []).append(min(col))
                acc.setdefault("max", []).append(max(col))
        self.js["accessors"].append(acc)
        return len(self.js["accessors"]) - 1


def channel_motion(js, binc, anim):
    """统计这个动作里真正在动的通道（供校验）。"""
    moving = []
    for ch in anim["channels"]:
        s = anim["samplers"][ch["sampler"]]
        _ct, _ty, vals = read_accessor(js, binc, s["output"])
        if len(vals) < 2:
            continue
        spread = max(max(abs(vals[i][k] - vals[0][k]) for i in range(len(vals)))
                     for k in range(len(vals[0])))
        if spread > 0.002:
            node = js["nodes"][ch["target"]["node"]].get("name", "?")
            moving.append("%s.%s" % (node, ch["target"]["path"]))
    return moving


def report(path):
    js, binc = read_glb(path)
    print("== %s ==" % path)
    if not js.get("animations"):
        print("  （没有动作）")
        return False
    ok = True
    for anim in js["animations"]:
        mv = channel_motion(js, binc, anim)
        flag = "OK " if mv else "空!"
        if not mv:
            ok = False
        print("  [%s] %-14s 通道 %3d  在动 %2d  %s" % (
            flag, anim.get("name", "?"), len(anim["channels"]), len(mv),
            ", ".join(mv[:6]) + (" …" if len(mv) > 6 else "")))
    return ok


def merge(base, donor, names, out, fill_rest=False):
    bjs, bbin = read_glb(base)
    djs, dbin = read_glb(donor)
    bld = Builder(bjs, bbin)

    base_by_name = {}
    for i, n in enumerate(bjs["nodes"]):
        base_by_name[n.get("name", "")] = i

    bjs.setdefault("animations", [])
    bjs["animations"] = [a for a in bjs["animations"] if a.get("name") not in names]

    for name in names:
        src = None
        for a in djs.get("animations", []):
            if a.get("name") == name:
                src = a
                break
        if src is None:
            raise SystemExit("donor 里没有动作：%s（有：%s）" % (
                name, [a.get("name") for a in djs.get("animations", [])]))

        samplers, channels, map_s = [], [], {}
        covered = set()
        for ch in src["channels"]:
            src_node = djs["nodes"][ch["target"]["node"]].get("name", "")
            if src_node not in base_by_name:
                print("  ! 跳过通道（基础模型没有骨骼 %s）" % src_node)
                continue
            si = ch["sampler"]
            if si not in map_s:
                s = src["samplers"][si]
                _ct_in, _ty_in, times = read_accessor(djs, dbin, s["input"])
                ct_out, ty_out, values = read_accessor(djs, dbin, s["output"])
                i_in = bld.add(5126, "SCALAR", [(float(t[0]),) for t in times])
                i_out = bld.add(ct_out, ty_out, values)
                map_s[si] = len(samplers)
                samplers.append({
                    "input": i_in,
                    "interpolation": s.get("interpolation", "LINEAR"),
                    "output": i_out,
                })
            channels.append({
                "sampler": map_s[si],
                "target": {
                    "node": base_by_name[src_node],
                    "path": ch["target"]["path"],
                },
            })
            covered.add((base_by_name[src_node], ch["target"]["path"]))

        # ★ 补齐"供体没有、但基座有"的骨骼通道（用基座静止姿势写常量关键帧）。
        #
        # 为什么必须补：Godot 里新动画**不会重置**它没有 track 的骨骼 —— 那条骨骼会
        # 保留上一个动画留下的姿势。于是"放下盾 → 随机播 idle_scratch（没有 shield track）
        # → 盾还举在半空"。补满之后每个动作都是完整姿势，不存在姿势残留。
        if fill_rest:
            dur = 0.0
            for s in samplers:
                a = bjs["accessors"][s["input"]]
                dur = max(dur, float(a["max"][0]) if a.get("max") else 0.0)
            if dur <= 0.0:
                dur = 1.0
            joints = []
            for sk in bjs.get("skins", []):
                joints.extend(sk.get("joints", []))
            added = 0
            for ni in set(joints):
                node = bjs["nodes"][ni]
                for path, comp_type, acc_type, default in (
                        ("translation", 5126, "VEC3", (0.0, 0.0, 0.0)),
                        ("rotation", 5126, "VEC4", (0.0, 0.0, 0.0, 1.0)),
                        ("scale", 5126, "VEC3", (1.0, 1.0, 1.0))):
                    if (ni, path) in covered:
                        continue
                    val = node.get(path)
                    v = tuple(float(x) for x in val) if val else default
                    i_in = bld.add(5126, "SCALAR", [(0.0,), (dur,)])
                    i_out = bld.add(comp_type, acc_type, [v, v])
                    samplers.append({"input": i_in, "interpolation": "LINEAR", "output": i_out})
                    channels.append({"sampler": len(samplers) - 1,
                                     "target": {"node": ni, "path": path}})
                    added += 1
            print("  · 补齐静止通道 %d 条（避免姿势残留）" % added)

        bjs["animations"].append({"channels": channels, "name": name, "samplers": samplers})
        print("  + %s：%d 通道 / %d sampler" % (name, len(channels), len(samplers)))

    bjs["buffers"][0]["byteLength"] = len(bld.bin)
    write_glb(out, bjs, bytes(bld.bin))
    print("写出：%s" % out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base")
    ap.add_argument("--donor")
    ap.add_argument("--names", default="")
    ap.add_argument("--out")
    ap.add_argument("--check", default="")
    ap.add_argument("--fill-rest", action="store_true",
                    help="给供体缺的骨骼补静止姿势关键帧（防姿势残留，跨 rig 借动作时必开）")
    args = ap.parse_args()
    if args.check:
        sys.exit(0 if report(args.check) else 1)
    if not (args.base and args.donor and args.out and args.names):
        ap.error("需要 --base --donor --names --out（或 --check）")
    merge(args.base, args.donor, args.names.split(","), args.out, args.fill_rest)
    report(args.out)


if __name__ == "__main__":
    main()
