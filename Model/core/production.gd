extends RefCounted
## 职责：生产队列（按 tick 推进）—— 训练/建造的计时唯一实现
## 属于：Model/core
## 对外：enqueue / tick / total_food / is_full
## 队列元素：{"id": String, "remaining": float, "total": float, "food": int}

const EPS := 0.000001


static func enqueue(queue: Array, id: String, seconds: float, food: int = 0) -> Dictionary:
	var item := {"id": id, "remaining": maxf(seconds, 0.0), "total": maxf(seconds, EPS), "food": maxi(food, 0)}
	queue.append(item)
	return item


## 推进 dt 秒；返回这一 tick 完成的条目（数组，可能多件）
static func tick(queue: Array, dt: float) -> Array:
	var done: Array = []
	var i := 0
	while i < queue.size():
		var item: Dictionary = queue[i]
		item["remaining"] = float(item.get("remaining", 0.0)) - maxf(dt, 0.0)
		if float(item["remaining"]) <= EPS:
			done.append(item)
			queue.remove_at(i)
			continue
		i += 1
	return done


static func total_food(queue: Array) -> int:
	var total := 0
	for item in queue:
		if item is Dictionary:
			total += maxi(int(item.get("food", 0)), 0)
	return total


static func remaining_seconds(queue: Array) -> float:
	var total := 0.0
	for item in queue:
		if item is Dictionary:
			total += maxf(float(item.get("remaining", 0.0)), 0.0)
	return total


static func is_full(queue: Array, capacity: int) -> bool:
	return capacity > 0 and queue.size() >= capacity
