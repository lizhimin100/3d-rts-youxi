// =============================================================================
//  选中圈.gdshader  —— 贴地选中圆环（细芯 + 内柔光 + 极慢呼吸）
// -----------------------------------------------------------------------------
//  用途：单位/建筑被选中时脚下的光环。
//
//  ★ 2026-11-07 重做（玩家口径「很丑的一个很粗的圆圈」「既要显眼又不突兀」）：
//    旧版是「加法混合 + 16 段旋转刻度 + 过曝 1.4~2.0 倍」，在 44m 视距下读成
//    一条发白的荧光胖环，还会随半径变粗（大本营 0.38m 宽）。新版：
//      · 一条**细芯**（世界宽度固定 0.06m 左右，靠调用方把 ring_width 换算成 UV）
//      · 芯外侧一圈**很淡的柔光**，让它在草地上"浮"起来，但不抢戏
//      · 刻度默认关闭（dash_strength=0），只留极慢的呼吸（1.1Hz、幅度 0.12）
//      · 改用 ALPHA 混合：不再把颜色推到白，阵营色能读出来
//
//  关键参数：
//     team_color   阵营色
//     ring_radius  环半径（UV 空间 0..1，1.0 = 贴到面片边缘）
//     ring_width   细芯宽度（UV）
//     halo         内侧柔光强度（0 = 只有一条线）
//     pulse_*      呼吸速度与幅度
//     dash_count   刻度数（0 = 关闭）
//     opacity      整体不透明度
// =============================================================================
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4  team_color : source_color = vec4(0.32, 1.0, 0.52, 1.0);
uniform float ring_radius : hint_range(0.05, 1.0) = 0.80;
uniform float ring_width : hint_range(0.002, 0.2) = 0.030;
uniform float halo : hint_range(0.0, 1.0) = 0.34;
uniform float inner_ring : hint_range(0.0, 1.0) = 0.0;
uniform float pulse_speed : hint_range(0.0, 12.0) = 1.10;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.12;
uniform float dash_count : hint_range(0.0, 48.0) = 0.0;
uniform float dash_strength : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 2.0) = 0.88;
uniform float spin_speed : hint_range(-2.0, 2.0) = 0.18;

void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    float r = length(p);
    float ang = atan(p.y, p.x);

    // 抗锯齿：用屏幕导数估一个像素宽度
    float aa = max(fwidth(r), 0.0012);

    // 细芯：一条干净的线，边缘只留 1.5 像素的过渡
    float ring = 1.0 - smoothstep(ring_width, ring_width + aa * 1.5, abs(r - ring_radius));

    // 内侧柔光：贴着芯往里衰减 9% 半径，给"落在地上"的体积感
    float glow = 0.0;
    if (halo > 0.001) {
        float d = (ring_radius - r) / max(ring_radius * 0.085, 0.002);
        glow = exp(-d * d) * step(r, ring_radius) * halo;
        // 芯本身不要再叠一层，否则又变粗
        glow *= 1.0 - ring;
    }

    // 内环（可选，默认关）
    float ring2 = 0.0;
    if (inner_ring > 0.001) {
        ring2 = 1.0 - smoothstep(ring_width * 0.8 - aa, ring_width * 0.8 + aa,
                                 abs(r - ring_radius * 0.62));
        ring2 *= inner_ring;
    }

    // 旋转刻度（默认关）
    float dash = 1.0;
    if (dash_count >= 1.0 && dash_strength > 0.001) {
        float a = fract((ang + TIME * spin_speed) / 6.2831853 * dash_count);
        dash = mix(1.0, smoothstep(0.35, 0.55, a) * smoothstep(1.0, 0.75, a), dash_strength);
    }

    float pulse = 1.0 + pulse_amount * sin(TIME * pulse_speed);
    // 芯 = 实心线（亮），柔光 = 低 alpha（暗），加法关系放在 alpha 上而不是颜色上
    float a = clamp((ring * dash + glow * 0.30 + ring2) * pulse * opacity, 0.0, 1.0);

    // 不做 1.4 倍过曝：只在芯上轻微提亮 8%，保证阵营色不被洗白
    ALBEDO = team_color.rgb * mix(1.0, 1.08, ring);
    ALPHA = a * team_color.a;

    // 贴地效果：越靠边缘越暗一点（面片是方的，避免看到硬边）
    ALPHA *= 1.0 - smoothstep(ring_radius + 0.10, 1.0, r);
}
