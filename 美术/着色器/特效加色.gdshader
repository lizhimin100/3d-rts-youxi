// =============================================================================
//  特效加色.gdshader  —— 粒子加色混合（火花 / 魔法 / 爆裂）
// -----------------------------------------------------------------------------
//  用途：GPUParticles3D 的绘制材质。加色混合 + 无光照 + 关闭深度写入，
//        粒子叠加时自动过曝成白热，正好喂给环境泛光（bloom 阈值 1.35）。
//  关键参数：
//     color     基础色（粒子顶点色 COLOR 再乘一次，便于同一材质多色复用）
//     power     亮度增益（>1 才会触发泛光）
//     soft      圆形柔边；quad_* 控制 UV 蒙版形状（0=圆，1=方/条）
//     fade_by_life  用 COLOR.a 做生命淡出（粒子材质里 alpha 曲线已烘进 COLOR）
// =============================================================================
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4  color : source_color = vec4(1.0, 0.72, 0.32, 1.0);
uniform float power : hint_range(0.0, 12.0) = 2.4;
uniform float soft : hint_range(0.02, 1.0) = 0.55;
uniform float quad_sharp : hint_range(0.0, 1.0) = 0.0;
uniform float use_vertex_color : hint_range(0.0, 1.0) = 1.0;

void vertex() {
    // 屏幕对齐：让粒子片始终面向相机（缩放交给 transform，位置不变）
}

void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    float r = length(uv);
    float core = smoothstep(1.0, 1.0 - soft, r);
    // quad_sharp → 叠一层方形，得到"火星碎片"的棱角感
    float box = 1.0 - smoothstep(0.80, 1.0, max(abs(uv.x), abs(uv.y)));
    float mask = mix(core, box, quad_sharp);

    vec3 c = mix(color.rgb, COLOR.rgb, use_vertex_color);
    ALBEDO = c * power;
    ALPHA = clamp(mask * COLOR.a * color.a, 0.0, 1.0);
}
