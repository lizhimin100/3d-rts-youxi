class_name RtsTerrainAssets
extends RefCounted
## 职责：地表材质 / 图集 / 贴图 / 一格米数的**唯一真源**（资源路径常量）。
## 属于：Screens/world/art（表现层）
##
## 为什么单独一个文件：这些路径原本挂在旧的 `RtsTerrain`（整块程序化地形渲染器）上，
## 2026-11-22 旧单兵系统下线时那个渲染器被物理删除，但**底壳编辑器还在用同一份材质与贴图**
## —— 编辑器看到的地表必须等于局内看到的地表。所以把"路径"从"渲染器"里拆出来单独存一份，
## 谁也不许再写第二份路径字面量。

const MATERIAL_PATH := "res://Content/art/材质/地形材质.tres"
const ATLAS_PATH := "res://Content/art/贴图/地形/材质/草泥/atlas_草泥_rgba.png"
const ATLAS_N_PATH := "res://Content/art/贴图/地形/材质/草泥/atlas_草泥_n.png"
const TEX_GRASS_PATH := "res://Content/art/贴图/地形/草地.png"
const TEX_DIRT_PATH := "res://Content/art/贴图/地形/泥土.png"
const TEX_CRACKED_PATH := "res://Content/art/贴图/地形/裂纹泥地.png"
const ROCK_DETAIL_PATH := "res://Content/art/贴图/rock_albedo.png"
## 一格多少米（地表材质平铺距离；改它等于改所有地表花纹的密度）。
const TILE_M: float = 8.0

## 生态换色：[基色, 混合量 0~1]。底壳的 biome 字段只影响**观感**，不影响任何判定。
const BIOME_TINT: Dictionary = {
	"temperate": [Color(0.55, 0.72, 0.46), 0.00],
	"arid": [Color(0.74, 0.61, 0.38), 0.62],
	"snow": [Color(0.86, 0.90, 0.95), 0.72],
	"volcanic": [Color(0.30, 0.23, 0.21), 0.66],
	"swamp": [Color(0.26, 0.34, 0.22), 0.55],
}


## 生态换色参数：[基色, 混合量]；未知生态按温带。
static func biome_tint(id: String) -> Array:
	var raw: Variant = BIOME_TINT.get(id, BIOME_TINT["temperate"])
	if raw is Array and (raw as Array).size() >= 2:
		return [(raw as Array)[0] as Color, float((raw as Array)[1])]
	return [Color(0.55, 0.72, 0.46), 0.0]
