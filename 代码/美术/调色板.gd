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
	"roof": Color(0.420, 0.471, 0.502),
	"roof_dark": Color(0.247, 0.286, 0.322),
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
	# --- 自然物（v3，2026-10-24）---
	# 出处：文档/美术规范.md §2.5「土 / 植被」。原有 leaf/grass 偏荧光（H≈100、S≈0.55），
	# 和建筑的暖褐石摆在一起像贴纸；这里补的是规范里的**橄榄绿三档**，
	# 供 代码/美术/自然材质.gd 使用（原键保留，旧调用方不受影响）。
	"leaf_olive": Color(0.353, 0.478, 0.267),   # #5A7A44 叶（树冠主色）
	"leaf_light": Color(0.541, 0.549, 0.275),   # #8A8C46 叶黄（受光顶面 / 秋叶 / 草尖）
	"leaf_deep": Color(0.227, 0.322, 0.188),    # #3A5230 叶暗（树冠底部 / 内层）
	"bark_dark": Color(0.306, 0.208, 0.125),    # #4E3520 木暗（树皮暗面 / 板根）
	"rock": Color(0.470, 0.502, 0.510),         # 冷灰（自然岩石，比建筑石偏冷一档，读得开）
	"rock_dark": Color(0.310, 0.341, 0.353),    # 冷灰暗（石缝 / 背光面）
	"canvas": Color(0.706, 0.647, 0.541),       # 帐篷布（布麻偏亮）
	"canvas_dark": Color(0.478, 0.412, 0.318),  # 帐篷布暗（门帘 / 背光面）
	"cavity": Color(0.086, 0.090, 0.098),       # 洞窟 / 内腔（矿洞、树洞、骨架内部）
	"grass_dark": Color(0.259, 0.365, 0.161),   # 草根暗（草丛底部）
}

## zone → 粗糙度（没写的用 0.8）
@export var roughness: Dictionary = {
	"steel": 0.45, "steel_dark": 0.55, "steel_light": 0.34, "gold": 0.38,
	"gold_dark": 0.50, "iron": 0.60, "crystal": 0.10, "glass": 0.20,
	"water": 0.10, "roof": 0.86, "roof_dark": 0.90, "hay": 0.95,
	"stone": 0.94, "stone_dark": 0.95, "stone_light": 0.92, "plaster": 0.95,
	"wood": 0.90, "wood_dark": 0.92, "dirt": 0.98, "leaf": 0.90, "leaf_dark": 0.92,
	"bark": 0.95, "grass": 0.95,
	# 自然物（与 §2.5 的 rough 列一致；叶面留一点润泽，别整片死哑）
	"leaf_olive": 0.88, "leaf_light": 0.86, "leaf_deep": 0.90, "bark_dark": 0.93,
	"rock": 0.90, "rock_dark": 0.92, "canvas": 0.95, "canvas_dark": 0.95,
	"cavity": 0.98, "grass_dark": 0.95,
}

## zone → 金属度
@export var metallic: Dictionary = {
	"steel": 0.25, "steel_dark": 0.20, "steel_light": 0.30, "gold": 0.30,
	"gold_dark": 0.25, "iron": 0.15, "ore": 0.15, "glass": 0.10,
}

## 队伍色区：zone → 染色强度（0..1）
@export var team_zones: Dictionary = {
	"cloth": 0.92, "roof": 0.10, "banner": 0.95,
}

## 未知 zone 的兜底颜色（宁可灰一点，也不要整块变洋红）
@export var fallback: Color = Color(0.62, 0.62, 0.60)
