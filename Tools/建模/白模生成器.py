#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GLB 白模生成器（纯标准库，无第三方依赖）

做法：解析 glTF 2.0 二进制（GLB），保留几何 BIN 数据不动，
把每个 mesh primitive 的材质引用重定向到一枚中性白色 PBR 材质，
并删除不再使用的 textures / images / samplers，从而得到一个
可被 Godot / 任意 glTF 查看器直接导入的「白模」。

用法：
    python glb_white.py <input.glb> <output.glb>
"""
import json
import os
import struct
import sys


def _align4(b: bytes) -> bytes:
    pad = (-len(b)) % 4
    return b + b" " * pad  # JSON chunk 用空格补齐


def make_white(in_path: str, out_path: str) -> None:
    with open(in_path, "rb") as f:
        data = f.read()

    magic, version, total_len = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError(f"{in_path} 不是 GLB 文件 (magic={magic})")

    # 解析两个 chunk：JSON + BIN
    off = 12
    json_bytes = None
    bin_bytes = None
    while off < len(data):
        (clen, ctype) = struct.unpack_from("<I4s", data, off)
        off += 8
        cdata = data[off:off + clen]
        off += clen
        if ctype == b"JSON":
            json_bytes = cdata
        elif ctype == b"BIN\x00":
            bin_bytes = cdata
        # 跳过未知 chunk

    if json_bytes is None:
        raise ValueError("GLB 缺少 JSON chunk")

    gltf = json.loads(json_bytes.decode("utf-8"))

    # 1) 单一中性白色材质
    white_mat = {
        "name": "WhiteProxy",
        "pbrMetallicRoughness": {
            "baseColorFactor": [0.8, 0.8, 0.8, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 1.0,
        },
        "doubleSided": True,
    }
    gltf["materials"] = [white_mat]
    white_idx = 0

    # 2) 所有 primitive 指向白模，清理扩展/顶点色之外的材质相关字段
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            prim["material"] = white_idx
            # 去掉依赖原贴图的扩展（如 KHR_materials_* 等），避免悬空引用
            for k in list(prim.keys()):
                if k.startswith("extensions") or k == "material" and prim[k] is None:
                    pass
            prim.pop("extensions", None)
            # 顶点色在白模里无意义，保留几何但忽略（viewer 用材质色覆盖）
            prim.pop("extras", None)

    # 3) 删除不再使用的纹理资源
    for key in ("textures", "images", "samplers"):
        gltf.pop(key, None)

    # 4) 重新打包 GLB
    new_json = json.dumps(gltf, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    new_json_chunk = _align4(new_json)

    chunks = b""
    chunks += struct.pack("<I4s", len(new_json_chunk), b"JSON") + new_json_chunk
    if bin_bytes is not None:
        bin_padded = bin_bytes + b"\x00" * ((-len(bin_bytes)) % 4)
        chunks += struct.pack("<I4s", len(bin_padded), b"BIN\x00") + bin_padded

    total = 12 + len(chunks)
    out = struct.pack("<4sII", b"glTF", 2, total) + chunks

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(out)


def main():
    if len(sys.argv) != 3:
        print("用法: python glb_white.py <input.glb> <output.glb>")
        sys.exit(1)
    make_white(sys.argv[1], sys.argv[2])
    print(f"OK  {sys.argv[1]} -> {sys.argv[2]}  ({os.path.getsize(sys.argv[2])} bytes)")


if __name__ == "__main__":
    main()
