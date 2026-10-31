shader_type spatial;
// 战场迷雾：一块贴在相机前的全屏四边形，按**世界坐标**采样迷雾贴图，
// 把"没探索过的地面 / 单位 / 树 / 建筑"整体压黑。
//
// 为什么不用"贴地半透明网格"（旧版做法）：
//   雾面只抬 30cm，比它高的东西（树干、单位、建筑）从雾里"长出来"，
//   雾中的树顶照样全亮 —— 那不叫战争迷雾，那叫地上铺了块灰布。
// 为什么不用 CanvasLayer 后处理：
//   canvas_item 着色器拿不到可靠的深度/世界坐标（还要跟 UI 抢层）。
//   3D 全屏四边形 + 深度重建世界坐标，是引擎里最直接的一条路。
//
// 深度重建沿用引擎文档的写法（Godot 4 是反向 Z：近=1、远=0），
// 天空（深度 0）直接 discard，否则镜头抬一下整屏发黑。
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D fog_tex : repeat_disable, filter_linear;
// 地图边长（米，正方形，以原点为中心）
uniform vec2 map_size = vec2(224.0, 224.0);
// 迷雾色（近黑偏冷，别用纯黑：纯黑会把地形纹理彻底吃掉）
uniform vec3 fog_color = vec3(0.015, 0.020, 0.030);
// 整体强度（1 = 完全按贴图 alpha；调小可用于"轻度迷雾"）
uniform float strength = 1.0;

void fragment() {
	float d = texture(depth_tex, SCREEN_UV).x;
	if (d <= 0.00001) {
		discard;
	}
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec2 uv = (world.xz + map_size * 0.5) / map_size;
	float a = texture(fog_tex, clamp(uv, vec2(0.0), vec2(1.0))).a;
	ALBEDO = fog_color;
	ALPHA = clamp(a * strength, 0.0, 1.0);
}
