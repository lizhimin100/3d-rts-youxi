// =============================================================================
//  贴花层.gdshader —— 铁誓建筑的 team / team_trim 两层
// -----------------------------------------------------------------------------
//  为什么单独写一个 shader：
//    这两层是"贴在主体上的薄片"——旗帜、纹章、金线腰线、门钉。
//    在资产包里它们和主体墙面几乎共面，深度值完全相等 → 只要相机一动，
//    同一块像素在"贴花"和"墙"之间来回赢 → 玩家看到的就是"旗帜符号在闪"。
//
//  解决：fragment 里把 DEPTH 往相机方向轻推 `depth_pull`。
//    这是标准的 depth bias（polygon offset）做法，视觉上看不出任何位移，
//    但深度比较永远由贴花胜出，闪烁消失。
//    depth_pull 用 [0,1] 的归一化深度，2e-4 在 20~60m 机位下足够。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float metallic_v : hint_range(0.0, 1.0) = 0.0;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.7;
uniform float specular_v : hint_range(0.0, 1.0) = 0.45;
uniform vec4 emission_col : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;
/// 往相机方向推进的归一化深度量（治 z-fighting）
uniform float depth_pull : hint_range(0.0, 0.002) = 0.00035;

void fragment() {
	ALBEDO = albedo.rgb;
	METALLIC = metallic_v;
	ROUGHNESS = roughness_v;
	SPECULAR = specular_v;
	EMISSION = emission_col.rgb * emission_energy;
	// depth bias：贴花层永远比主体靠前一点
	DEPTH = DEPTH + depth_pull;
}
