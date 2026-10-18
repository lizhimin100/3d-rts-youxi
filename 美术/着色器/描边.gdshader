// =============================================================================
//  描边.gdshader  —— 反向外壳描边（挂在 卡通主体 的 next_pass 上）
// -----------------------------------------------------------------------------
//  用途：沿法线把模型"吹大"一圈，只渲染背面（cull_front），得到外轮廓黑边。
//  关键参数：
//     outline_width   描边宽度（视距自适应：偏移 ∝ 深度 ⇒ 屏幕上恒定粗细）
//     outline_color   描边色，深蓝黑（比纯黑柔和，且和冷阴影同色系）
//     max_dist        距离上限，防止远处描边过粗/发散
//  为什么写 POSITION：直接给裁剪空间坐标，绕过投影，粗细才真的与分辨率无关。
// =============================================================================
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;

uniform float outline_width : hint_range(0.0, 0.10) = 0.016;
uniform vec4  outline_color : source_color = vec4(0.055, 0.060, 0.095, 1.0);
uniform float max_dist : hint_range(1.0, 200.0) = 55.0;
uniform float min_dist : hint_range(0.1, 20.0) = 0.6;

void vertex() {
    vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    vec3 n = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
    float d = clamp(-vp.z, min_dist, max_dist);
    vp.xyz += n * outline_width * d * 0.25;
    POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
    ALBEDO = outline_color.rgb;
}
