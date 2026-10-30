# -*- coding: utf-8 -*-
"""只重建指定的几个资产（迭代用）：blender -b -P _one.py -- tent flag"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _v7_common as C

MOD = os.environ.get("V7_MOD", "decor_v7")
mod = __import__(MOD)
argv = sys.argv
args = argv[argv.index("--") + 1:] if "--" in argv else []
names = args or list(mod.BUILDERS.keys())[:1]
C.run({k: mod.BUILDERS[k] for k in names}, mod.FILE_OF,
      res_of=mod.RES_OF, emissive_of=mod.EMISSIVE, ao_dist_of=mod.AO_DIST, samples=40)
