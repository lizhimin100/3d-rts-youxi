// GPU 箭矢着色器 —— 抛物线在这里现算，CPU 只给"起点/终点/时刻/弧高"。
//
// 输入（每实例）：
//   MODEL_MATRIX[3].xyz = 起点
//   MODEL_MATRIX[0].xyz = 终点 - 起点（借 basis.x 当数据通道，不做旋转）
//   INSTANCE_CUSTOM = (t0, 飞行时长, 弧高, 1)
//   uniform now = 全局秒（GDScript 每帧写一次）
//
// 为什么用 POSITION 而不是 MODELVIEW：实例变换里存的是"数据"不是"位姿"，
// 直接算世界坐标再投到裁剪空间，省掉一次矩阵分解。
shader_type spatial;
render_mode cull_disabled, unshaded, shadows_disabled, depth_draw_never;

uniform float now = 0.0;
uniform vec3 arrow_color : source_color = vec3(0.93, 0.87, 0.72);

void vertex() {
	vec3 start = MODEL_MATRIX[3].xyz;
	vec3 delta = MODEL_MATRIX[0].xyz;
	vec3 end = start + delta;
	float t0 = INSTANCE_CUSTOM.x;
	float dur = max(INSTANCE_CUSTOM.y, 0.001);
	float arc = INSTANCE_CUSTOM.z;
	float t = clamp((now - t0) / dur, 0.0, 1.0);

	vec3 base = mix(start, end, t);
	base.y += arc * 4.0 * t * (1.0 - t);

	// 切线（含重力方向），用来把箭杆摆正
	vec3 vel = delta;
	vel.y += arc * 4.0 * (1.0 - 2.0 * t);
	vec3 fwd = normalize(vel + vec3(0.0, 0.0001, 0.0));
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, fwd) + vec3(0.0001, 0.0, 0.0));
	vec3 realup = cross(fwd, right);
	vec3 local = right * VERTEX.x + realup * VERTEX.y + fwd * VERTEX.z;

	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(base + local, 1.0);
}

void fragment() {
	ALBEDO = arrow_color;
}
