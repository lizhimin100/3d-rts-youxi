// =============================================================================
//  沙盘光环.gdshader  —— 建筑锚点的柔和辐射光圈
// -----------------------------------------------------------------------------
//  每座建筑脚下的一圈脉冲（内→外），把“势力范围从这里长出来”读成动态的光，
//  而不是一块静态贴纸。uv.x = 径向进度（0 内圈 / 1 外圈）。
//  加色混合：只提亮，不挡地形。
// =============================================================================
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 ring_color : source_color = vec4(0.30, 0.62, 1.0, 1.0);
uniform float fade = 1.0;

varying vec2 v_uv;

void vertex() {
    v_uv = UV;
}

void fragment() {
    float t = clamp(v_uv.x, 0.0, 1.0);
    float band = smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.52, 1.0, t));
    float ripple = 0.55 + 0.45 * sin(t * 9.0 - TIME * 2.2);
    float a = band * (0.10 + 0.18 * ripple) * fade * ring_color.a;
    ALBEDO = ring_color.rgb * (0.85 + ripple * 0.45);
    ALPHA = a;
}
