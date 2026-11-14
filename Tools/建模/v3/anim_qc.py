# -*- coding: utf-8 -*-
"""
anim_qc.py —— 动画抽帧检查：把某个单位在指定动作/帧的姿势渲染出来。

为什么需要：骨骼动画是"看不见就不知道对不对"的东西，headless 下必须抽帧看，
否则很容易导出一个人物走起来像瘸子、或者攻击帧根本没举手的假动画。

用法：blender -b --python tools/建模/v3/anim_qc.py -- footman walk:7 attack:13
"""
import bpy, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3
import units as U

QC_DIR = os.path.join(HERE, "qc")


def main():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "footman"
    shots = args[1:] if len(args) > 1 else ["idle:8", "walk:7", "attack:13"]
    r, objs = U.BUILDERS[which](U.TARGET_H[which])
    # ★ 必须先复位：建完动画时骨架停在最后一个关键帧（death 会整个人塌下去），
    #   拿那个姿态量 bbox 会把相机拉得太近（上一次就拍成了"只剩腿"）。
    r.rest_pose()
    mn, mx = K3.bbox(objs)
    center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
    radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
    out = []
    for spec in shots:
        anim, _, frame = spec.partition(":")
        r.preview_action(anim, int(frame or 1))
        paths = K3.render_views("%s_%s" % (which, anim), QC_DIR, center, radius * 1.02,
                                res=(520, 660), views={"三四": (0.9, 1.0, 0.22)})
        out.append({"anim": anim, "frame": frame, "path": paths[0]})
    print("HEADLESS " + json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
