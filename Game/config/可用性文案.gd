extends RefCounted
## 职责：可用性结果 → 玩家文案（唯一映射；Model 只给 ASCII reason）
## 属于：Game/config（表现适配层，不属于 Model）
## 对外：text(result) / is_ok(result)
## 为什么不用直接写中文到 Model：Model 要保持引擎/语言无关，以后 C# 内核也能共用 reason。

## 动态取 I18n（避免 --script 在 autoload 注册前编译时裸引用 I18n 失败）
static func _t(key: String, params: Dictionary = {}) -> String:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var n: Node = (loop as SceneTree).root.get_node_or_null("I18n")
		if n != null and n.has_method("t"):
			return String(n.call("t", key, params))
	return key


static func is_ok(result: Dictionary) -> bool:
	return bool(result.get("ok", false))


static func text(result: Dictionary) -> String:
	if is_ok(result):
		return ""
	var code := String(result.get("reason", ""))
	var p: Dictionary = result.get("params", {})
	match code:
		"not_constructed":
			return _t("avail.not_constructed")
		"not_in_trains":
			return _t("avail.not_in_trains")
		"not_researchable":
			return _t("avail.not_researchable")
		"upgrading":
			return _t("avail.upgrading")
		"tier_locked":
			return _t("avail.tier_locked", {"required": int(p.get("required", 0))})
		"queue_full":
			return _t("avail.queue_full")
		"no_food":
			return _t("avail.no_food", {"free": int(p.get("free", 0))})
		"no_cp":
			return _t("avail.no_cp", {"short": int(p.get("short", 0))})
		"no_gold":
			return _t("avail.no_gold", {"short": int(p.get("short", 0))})
		"no_wood":
			return _t("avail.no_wood", {"short": int(p.get("short", 0))})
		"max_level":
			return _t("avail.max_level")
		"research_busy":
			return _t("avail.research_busy")
		"no_worker":
			return _t("avail.no_worker")
		"not_defined":
			return _t("avail.not_defined")
	return _t("avail.unknown")
