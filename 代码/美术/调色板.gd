## 调色板资源：一个 zone 一个颜色，改这一份 = 全场换色。
## 为什么做成 Resource 而不是常量表：策划/美术以后可以直接在编辑器里调，
## 甚至给敌我双方各存一份，运行时热切，不用改代码。
class_name RtsPalette
extends Resource

## zone 名 → 基色（与 Blender 侧 kit3.PALETTE 的键一一对应）
@export var colors: Dictionary = {
	"stone": Color(0.678, 0.631, 0.502),
	"stone_dark": Color(0.502, 0.463, 0.353),
	"stone_light": Color(0.769, 0.718, 0.588),
	"plaster": Color(0.890, 0.847, 0.737),
	"roof": Color(0.165, 0.361, 0.749),
	"roof_dark": Color(0.106, 0.243, 0.525),
	"gold": Color(0.886, 0.702, 0.298),
	"gold_dark": Color(0.659, 0.482, 0.165),
	"wood": Color(0.478, 0.322, 0.188),
	"wood_dark": Color(0.333, 0.216, 0.125),
	"steel": Color(0.596, 0.635, 0.682),
	"steel_dark": Color(0.369, 0.404, 0.451),
	"steel_light": Color(0.737, 0.769, 0.808),
	"iron": Color(0.420, 0.396, 0.361),
	"leather": Color(0.541, 0.357, 0.204),
	"leather_dark": Color(0.341, 0.220, 0.137),
	"cloth": Color(0.169, 0.373, 0.690),
	"cloth_dark": Color(0.110, 0.251, 0.475),
	"skin": Color(0.851, 0.647, 0.486),
	"skin_dark": Color(0.702, 0.482, 0.333),
	"hair": Color(0.420, 0.290, 0.169),
	"crystal": Color(0.498, 0.847, 1.0),
	"ember": Color(1.0, 0.541, 0.192),
	"glass": Color(0.125, 0.188, 0.290),
	"bark": Color(0.357, 0.255, 0.153),
	"leaf": Color(0.306, 0.486, 0.204),
	"leaf_dark": Color(0.204, 0.345, 0.157),
	"ore": Color(0.914, 0.761, 0.290),
	"grass": Color(0.420, 0.561, 0.227),
	"water": Color(0.180, 0.431, 0.557),
	"dirt": Color(0.482, 0.388, 0.267),
	"hay": Color(0.788, 0.663, 0.306),
	"rope": Color(0.612, 0.518, 0.333),
	"bone": Color(0.847, 0.824, 0.745),
}

## zone → 粗糙度（没写的用 0.8）
@export var roughness: Dictionary = {
	"steel": 0.38, "steel_dark": 0.42, "steel_light": 0.32, "gold": 0.34,
	"gold_dark": 0.42, "iron": 0.60, "crystal": 0.10, "glass": 0.20,
	"water": 0.10, "roof": 0.86, "roof_dark": 0.90, "hay": 0.95,
	"stone": 0.94, "stone_dark": 0.95, "stone_light": 0.92, "plaster": 0.95,
	"wood": 0.90, "wood_dark": 0.92, "dirt": 0.98, "leaf": 0.90, "leaf_dark": 0.92,
	"bark": 0.95, "grass": 0.95,
}

## zone → 金属度
@export var metallic: Dictionary = {
	"steel": 0.80, "steel_dark": 0.75, "steel_light": 0.82, "gold": 0.85,
	"gold_dark": 0.80, "iron": 0.55, "ore": 0.70, "glass": 0.10,
}

## 队伍色区：zone → 染色强度（0..1）
@export var team_zones: Dictionary = {
	"cloth": 0.92, "roof": 0.38, "banner": 0.95,
}

## 未知 zone 的兜底颜色（宁可灰一点，也不要整块变洋红）
@export var fallback: Color = Color(0.62, 0.62, 0.60)
