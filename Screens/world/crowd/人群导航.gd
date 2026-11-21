extends RefCounted
## **人群导航** —— 栅格漏斗（string pulling）+ 半径膨胀圆角 + 路径窗口。
##
## 这一层只回答两个问题：
##   1. 一条栅格路径，能不能压成"尽量少、尽量贴角"的拐点？（漏斗）
##   2. 拐点能不能用一段圆弧过掉，而不是直角折线？（半径膨胀过角）
##
## **为什么单位只记两个拐点**（SC2 口径）：世界随时在变（建筑落成、树被砍、
## 队友挤过来），一次算到终点的折线在 0.5 秒后多半已经无效。只留 next1/next2，
## 走完就取下一个、偏离就重算，反而比"全量路径 + 定时重算"更稳、更省内存。
## 一个单位 2 个 Vector2 = 16 字节，一万单位 = 160KB；全量路径是 20–40 点 = 3MB+。
##
## 圆角的两个档（对应 `Documents/寻路评估_星际2对照.md` §3.4）：
##   A. **圆弧倒角**（这里默认用）：拐点两侧各切一段，二次贝塞尔采样 3 点。
##   B. **圆-切线**（`arc_between`）：两个阻挡顶点之间走公切线，用于窄缝。
## 两档都带 `SKIN` 余量——零余量会被分离推 1mm 就掉出可走区，然后被墙推回来。

const C := preload("res://Screens/world/crowd/人群常量.gd")


## 栅格漏斗：把一条 A* 路径压成拐点。
## walk: 1m 可走表；path: 世界坐标折线（格心）；radius: 单位半径。
## 返回拐点数组（不含起点）。
static func funnel(path: PackedVector3Array, walk: PackedByteArray, radius: float) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var n: int = path.size()
	if n < 2:
		return out
	# 1) 展开成左右门户：沿路径法线左右扫，扫到墙前停下
	var left: PackedVector2Array = PackedVector2Array()
	var right: PackedVector2Array = PackedVector2Array()
	var margin: float = radius + C.SKIN
	for i in range(n):
		var p: Vector3 = path[i]
		var dir: Vector2 = Vector2.ZERO
		if i == 0:
			dir = Vector2(path[1].x - p.x, path[1].z - p.z)
		elif i == n - 1:
			dir = Vector2(p.x - path[i - 1].x, p.z - path[i - 1].z)
		else:
			dir = Vector2(path[i + 1].x - path[i - 1].x, path[i + 1].z - path[i - 1].z)
		if dir.length_squared() < 1e-6:
			dir = Vector2(1, 0)
		dir = dir.normalized()
		var nrm: Vector2 = Vector2(-dir.y, dir.x)   # 左法线
		var lw: float = _scan(p.x, p.z, nrm, margin, walk)
		var rw: float = _scan(p.x, p.z, -nrm, margin, walk)
		left.append(Vector2(p.x, p.z) + nrm * lw)
		right.append(Vector2(p.x, p.z) - nrm * rw)

	# 2) Simple Stupid Funnel（Mikko Mononen 版），2D 用 (x,z)
	var apex: Vector2 = left[0]
	var pl: Vector2 = left[0]
	var pr: Vector2 = right[0]
	var ai: int = 0
	var li: int = 0
	var ri: int = 0
	for i in range(1, n):
		var l: Vector2 = left[i]
		var r: Vector2 = right[i]
		# --- 右边界收 ---
		if _tri(apex, pr, r) <= 0.0:
			if apex == pr or _tri(apex, pl, r) > 0.0:
				pr = r
				ri = i
			else:
				out.append(Vector3(pl.x, 0.0, pl.y))
				apex = pl
				ai = li
				pl = apex
				pr = apex
				li = ai
				ri = ai
				continue
		# --- 左边界收 ---
		if _tri(apex, pl, l) >= 0.0:
			if apex == pl or _tri(apex, pr, l) < 0.0:
				pl = l
				li = i
			else:
				out.append(Vector3(pr.x, 0.0, pr.y))
				apex = pr
				ai = ri
				pl = apex
				pr = apex
				li = ai
				ri = ai
				continue
	# 终点
	var last: Vector3 = path[n - 1]
	if out.is_empty() or Vector3(out[out.size() - 1].x, 0, out[out.size() - 1].z) != Vector3(last.x, 0, last.z):
		out.append(last)
	return out


## 沿 dir 方向从 (x,z) 探多远还安全（最多探 4m，步长 0.25m）。
static func _scan(x: float, z: float, dir: Vector2, margin: float, walk: PackedByteArray) -> float:
	var d: float = 0.0
	while d < 4.0:
		var nx: float = x + dir.x * (d + 0.25)
		var nz: float = z + dir.y * (d + 0.25)
		if nx < -128.0 or nx >= 128.0 or nz < -128.0 or nz >= 128.0:
			break
		var cx: int = (floori(nx) + 128) & 255
		var cz: int = (floori(nz) + 128) & 255
		if walk[(cz << 8) | cx] == 0:
			break
		d += 0.25
	return maxf(margin, d - margin)


## 圆弧倒角：把折线每个拐点替换成半径 r 的二次贝塞尔（3 点采样）。
## 每个采样点都要过 `walkable` 检查；任何一点穿墙就保留原拐点（宁方勿卡）。
static func fillet(points: PackedVector3Array, r: float, walk: PackedByteArray) -> PackedVector3Array:
	var n: int = points.size()
	if n < 3:
		return points
	var out: PackedVector3Array = PackedVector3Array()
	out.append(points[0])
	for i in range(1, n - 1):
		var a: Vector3 = points[i - 1]
		var b: Vector3 = points[i]
		var c: Vector3 = points[i + 1]
		var u1: Vector3 = (b - a)
		var u2: Vector3 = (c - b)
		u1.y = 0.0
		u2.y = 0.0
		if u1.length_squared() < 1e-6 or u2.length_squared() < 1e-6:
			out.append(b)
			continue
		u1 = u1.normalized()
		u2 = u2.normalized()
		var dot: float = clampf(u1.dot(u2), -1.0, 1.0)
		var turn: float = acos(dot)
		# 直行（转角 < 8°）不倒角；掉头（>165°）也不倒（几何退化）
		if turn < 0.14 or turn > 2.88:
			out.append(b)
			continue
		var half: float = turn * 0.5
		var d: float = r / tan(half)
		var max_d: float = minf(u1.length() * 0.0 + 3.0, minf((b - a).length(), (c - b).length()) * 0.5)
		d = minf(d, max_d)
		var p0: Vector3 = b - u1 * d
		var p1: Vector3 = b + u2 * d
		# 二次贝塞尔 P0 - B - P1，采样 t=0.25/0.5/0.75
		var ok: bool = true
		var samples: PackedVector3Array = PackedVector3Array()
		for k in range(1, 4):
			var t: float = float(k) * 0.25
			var it: float = 1.0 - t
			var q: Vector3 = p0 * (it * it) + b * (2.0 * it * t) + p1 * (t * t)
			if not _walk_at(q.x, q.z, walk):
				ok = false
				break
			samples.append(q)
		if ok:
			for s in samples:
				out.append(s)
		else:
			out.append(b)
	out.append(points[n - 1])
	return out


static func _walk_at(x: float, z: float, walk: PackedByteArray) -> bool:
	if x < -128.0 or x >= 128.0 or z < -128.0 or z >= 128.0:
		return false
	var cx: int = (floori(x) + 128) & 255
	var cz: int = (floori(z) + 128) & 255
	return walk[(cz << 8) | cx] != 0


## 圆-切线（B 档）：两个阻挡顶点之间走公切线。
## 返回 (切线起点, 切线终点)；两圆相交/内含时返回空数组表示"过不去"。
static func arc_between(c1: Vector2, r1: float, c2: Vector2, r2: float) -> PackedVector2Array:
	var d: Vector2 = c2 - c1
	var dist: float = d.length()
	if dist < 1e-4 or dist <= absf(r1 - r2) + 1e-4:
		return PackedVector2Array()
	var u: Vector2 = d / dist
	# 外公切线：切点沿 u 的分量 = (r1 - r2) * r1 / dist 之类；这里用统一半径近似
	var rr: float = (r1 + r2) * 0.5
	if dist <= 2.0 * rr:
		return PackedVector2Array()
	var a: float = sqrt(dist * dist - (r1 - r2) * (r1 - r2))
	var n: Vector2 = Vector2(-u.y, u.x)
	var t: float = (r1 - r2) / dist
	var k: float = sqrt(maxf(0.0, 1.0 - t * t))
	var p1: Vector2 = c1 + u * (r1 * t) + n * (r1 * k)
	var p2: Vector2 = c2 + u * (r2 * t) + n * (r2 * k)
	return PackedVector2Array([p1, p2])


## 有符号三角形面积 ×2（用于漏斗的左右判定）
static func _tri(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)


## 路径窗口：只保留接下来两个拐点。
## 返回 [next1, next2]；如果偏移超过 PATH_DEVIATE，返回空数组表示"该重算了"。
static func window_of(pts: PackedVector3Array, from: Vector3, start_i: int) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	if start_i >= pts.size():
		return out
	# 偏离检查：当前位置到第一段的垂距
	var a: Vector3 = pts[maxi(0, start_i - 1)]
	var b: Vector3 = pts[start_i]
	var ab: Vector3 = b - a
	ab.y = 0.0
	var ap: Vector3 = from - a
	ap.y = 0.0
	if ab.length_squared() > 1e-6:
		var t: float = clampf(ap.dot(ab) / ab.length_squared(), 0.0, 1.0)
		var proj: Vector3 = a + ab * t
		if Vector2(from.x - proj.x, from.z - proj.z).length() > C.PATH_DEVIATE:
			return out
	out.append(pts[start_i])
	if start_i + 1 < pts.size():
		out.append(pts[start_i + 1])
	return out
