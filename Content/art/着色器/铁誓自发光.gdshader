// =============================================================================
//  铁誓自发光.gdshader —— 铁誓建筑资产包的第 4 层：窗光 / 炉火 / 门缝
// -----------------------------------------------------------------------------
//  为什么不用 BaseMaterial3D + emission_texture：
//    实测（红测试：把 emission 染成纯红）窗玻璃会**整片变成纯红**，
//    说明 emission_texture 根本没参与调制 —— 输出永远是 emission_color × 能量。
//    于是 1.8 的资产包原值把整片玻璃烧成白纸（玩家报的"窗户泛白"），
//    铁匠铺里那口炉子变成一坨白色；降到 0.5 也只是"淡一点的白"。
//
//  这里直接把图集当纹理采样：图集是 5×5 纯色格，格心就是每块面的颜色 ——
//    窗户格 = 暗蓝、炉火格 = 橙、旗面格 = 深色。乘上去之后各归各位。
//
//  采样必须 Nearest：格与格之间有黑缝，任何线性过滤都会把邻格和缝混进来。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D glow_tex : source_color, filter_nearest, repeat_enable;
// 玻璃底材：近乎黑但带一点冷调，白天是玻璃、不反光时不至于是个洞
uniform vec4  base_col : source_color = vec4(0.030, 0.036, 0.052, 1.0);
// 自发光强度：图集里最亮的一格是 0.95，乘 1.0 白天就过曝了
uniform float energy : hint_range(0.0, 2.0) = 0.85;
// 高光压缩：图集各格亮度差很大（窗 0.07 / 炉火 0.95）。
// 直接乘一个能量，要么窗户黑成洞、要么炉火白成纸。Reinhard 压缩后各归各位。
uniform float soft : hint_range(0.05, 1.0) = 0.30;
uniform float rough : hint_range(0.0, 1.0) = 0.88;
uniform float spec : hint_range(0.0, 1.0) = 0.12;

void fragment() {
	vec3 g = texture(glow_tex, UV).rgb;
	ALBEDO = base_col.rgb;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;
	EMISSION = (g / (g + vec3(soft))) * energy;
}
