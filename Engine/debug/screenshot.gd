extends RefCounted
## 职责：截图（离屏/窗口都能用）—— 唯一出口
## 属于：Engine/debug
## 对外：capture(path, viewport) / capture_image(viewport) / default_dir()
## 禁改：不要在游戏逻辑里直接 get_viewport().get_texture() 存图；走这里。

const DIR := "user://debug/shots/"


static func default_dir() -> String:
	return DIR


## 抓一帧并保存 PNG。成功返回绝对路径，失败返回空串。
static func capture(path: String, viewport: Viewport = null) -> String:
	var img := capture_image(viewport)
	if img == null:
		push_error("[Shot] 取不到画面（无头模式？）")
		return ""
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := img.save_png(path)
	if err != OK:
		push_error("[Shot] 存图失败 %s（%d）" % [path, err])
		return ""
	if path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


static func capture_image(viewport: Viewport = null) -> Image:
	var vp := viewport
	if vp == null:
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			vp = (loop as SceneTree).root
	if vp == null:
		return null
	var tex := vp.get_texture()
	if tex == null:
		return null
	return tex.get_image()
