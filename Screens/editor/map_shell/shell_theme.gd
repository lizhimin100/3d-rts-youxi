@tool
extends RefCounted
## 地图底壳编辑器的皮：深岩灰 #12161F 现代深色工具主题 + 旧地图编辑器的嵌入配色。
## 属于：Screens/editor/map_shell
##
## 为什么保留旧配色：底壳编辑器是旧 3D 地图编辑器的继任者，战术格子/脊线/面板的强调色
## 沿用旧编辑器的石色与金色（编辑器皮肤 编辑器皮肤.gd 的 STONE / GOLD），底色换成 #12161F。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")

const BG := Color("#12161F")
const BG_DEEP := Color("#0E1219")
const PANEL := Color("#1B2230")
const PANEL_HI := Color("#212A3A")
const STROKE := Color("#2B3548")
const TEXT := Color("#E8EDF7")
const TEXT_SUB := Color("#96A3BA")
const TEXT_DIM := Color("#617089")

# 旧地图编辑器（addons/map_editor/编辑器皮肤.gd）的嵌入色
const STONE := Color(0.153, 0.145, 0.125)
const STONE_DEEP := Color(0.106, 0.102, 0.090)
const LEGACY_GOLD := Color(0.784, 0.639, 0.302)
const LEGACY_GOLD_HI := Color(0.949, 0.831, 0.545)
const LEGACY_RED := Color(0.702, 0.271, 0.235)
const LEGACY_TEXT := Color(0.886, 0.863, 0.812)

const ACCENT := ThemeKit.ACCENT
const CYAN := ThemeKit.CYAN
const GREEN := ThemeKit.GREEN
const RED := ThemeKit.RED
const GOLD := LEGACY_GOLD


static func build_theme() -> Theme:
	return ThemeKit.build_theme()


static func panel(accent: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	return ThemeKit.card(accent, 14.0, 12)


static func legacy_chip(text: String) -> PanelContainer:
	return ThemeKit.chip(text, LEGACY_GOLD_HI)
