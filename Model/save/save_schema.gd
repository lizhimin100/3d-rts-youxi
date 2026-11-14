extends RefCounted
## 职责：存档数据结构 + 校验 + 版本迁移（纯逻辑，不碰文件）
## 属于：Model/save
## 对外：CURRENT_VERSION / new_profile(seed) / validate(payload) / migrate(payload)
## 文件读写由 Engine/save/save_service.gd 负责；这里只认 Dictionary。

const CURRENT_VERSION := 1


static func new_profile(seed_value: int) -> Dictionary:
	return {
		"version": CURRENT_VERSION,
		"seed": seed_value,
		"created_at": "",
		"unlocks": [],
		"stats": {
			"games_played": 0,
			"wins": 0,
			"losses": 0,
			"play_seconds": 0.0,
		},
		"settings": {
			"locale": "zh",
			"master_volume_db": 0.0,
			"music_volume_db": -19.0,
		},
	}


## 返回 {ok, errors, data}。ok=false 时 data 是原样回传（不修一半）。
static func validate(payload: Variant) -> Dictionary:
	var errors: Array[String] = []
	if not (payload is Dictionary):
		return {"ok": false, "errors": ["payload 不是 Dictionary"], "data": payload}
	var data: Dictionary = (payload as Dictionary).duplicate(true)
	var version := int(data.get("version", 0))
	if version <= 0:
		errors.append("缺 version")
	elif version > CURRENT_VERSION:
		errors.append("version %d 比本程序新（%d）" % [version, CURRENT_VERSION])
	if not (data.get("unlocks", []) is Array):
		errors.append("unlocks 必须是数组")
	if not (data.get("stats", {}) is Dictionary):
		errors.append("stats 必须是对象")
	else:
		var stats: Dictionary = data["stats"]
		for key in ["games_played", "wins", "losses"]:
			if typeof(stats.get(key, 0)) not in [TYPE_INT, TYPE_FLOAT]:
				errors.append("stats.%s 必须是数字" % key)
			elif int(stats.get(key, 0)) < 0:
				errors.append("stats.%s 不能为负" % key)
		if int(stats.get("wins", 0)) > int(stats.get("games_played", 0)):
			errors.append("wins > games_played")
	if not (data.get("settings", {}) is Dictionary):
		errors.append("settings 必须是对象")
	if errors.is_empty():
		data = migrate(data)
	return {"ok": errors.is_empty(), "errors": errors, "data": data}


## 老版本补字段（只加不改：迁移永远不删玩家数据）
static func migrate(payload: Dictionary) -> Dictionary:
	var data := payload.duplicate(true)
	var v := int(data.get("version", 0))
	if v < 1:
		var base := new_profile(int(data.get("seed", 1)))
		for key in data.keys():
			base[key] = data[key]
		base["version"] = 1
		data = base
	if not data.has("unlocks"):
		data["unlocks"] = []
	if not data.has("stats"):
		data["stats"] = {"games_played": 0, "wins": 0, "losses": 0, "play_seconds": 0.0}
	if not data.has("settings"):
		data["settings"] = {"locale": "zh", "master_volume_db": 0.0, "music_volume_db": -19.0}
	data["version"] = CURRENT_VERSION
	return data
