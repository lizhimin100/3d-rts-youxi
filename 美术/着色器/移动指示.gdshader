// =============================================================================
//  移动指示.gdshader  —— 贴地绿色虚线（marching ants）+ 目的地标记
// -----------------------------------------------------------------------------
//  用途：RtsMoveIndicator 生成的"走位指示"几何。**同一份着色器画两样东西**：
//    · 虚线带 —— ImmediateMesh 沿地形逐点采样出来的贴地条带；
//                UV.x = 已经走过多少个"虚线周期"，UV.y = 带宽方向 0 → 1；
//    · 目的地圆环 + 十字准星 —— UV.x = 圆周刻度（转起来像刻度环），
//                UV.y = 环带方向；准星顶点的 UV2.x = 1 → 恒亮，不吃虚线相位。
//
//  为什么把虚线相位烘进 UV.x、而不是拿世界坐标现算：
//    条带是每帧按单位当前位置重建的，长度一直在变。用 UV.x 才能保证虚线
//    **永远从单位脚下起算**，往前流动时整条线不会突然抖一下或者整条换相位。
//
//  关键参数：
//    dash_color   虚线颜色（魔兽感亮绿 #3DFF72）
//    dash_scale   相位倍数（1.0 = UV.x 已经是"周期数"，脚本里按距离自适应过了）
//    scroll_speed marching-ants 流速（周期/秒），正值 = 朝目的地流动
//    fade         整体淡出系数（0 = 完全消失），由脚本推，绝不硬切
//    dash_duty    一个周期里"亮"的占比（0.58 ≈ 亮 6 成、空 4 成）
//    dash_soft    虚线段两端的柔化宽度（周期占比），方块头最难看
//    edge_soft    带宽方向的柔边；core_power / halo_power = 亮芯 / 辉光强度
//    pulse_*      呼吸脉动（圆环给得多、虚线只给一点点，绝不许晃眼）
//    base_opacity 整体不透明度
// =============================================================================
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4  dash_color : source_color = vec4(0.239, 1.0, 0.447, 1.0);
uniform float dash_scale : hint_range(0.0, 8.0) = 1.0;
uniform float scroll_speed : hint_range(-4.0, 4.0) = 0.75;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float dash_duty : hint_range(0.05, 0.98) = 0.58;
uniform float dash_soft : hint_range(0.005, 0.5) = 0.10;
uniform float edge_soft : hint_range(0.05, 1.0) = 0.95;
uniform float core_power : hint_range(0.0, 4.0) = 1.30;
uniform float halo_power : hint_range(0.0, 2.0) = 0.34;
uniform float pulse_speed : hint_range(0.0, 12.0) = 2.4;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.06;
uniform float base_opacity : hint_range(0.0, 2.0) = 0.95;

varying vec4 v_col;
varying vec2 v_uv2;

void vertex() {
    // uv2.x = 1 表示"这是准星刻度，别给我切虚线"；uv2.y = 该标记自己的脉动相位
    v_col = COLOR;
    v_uv2 = UV2;
}

void fragment() {
    // --- 1) 虚线：UV.x 上按周期 fract，TIME 一推就往前流动 ---
    float phase = fract(UV.x * dash_scale - TIME * scroll_speed);
    float head = smoothstep(0.0, max(dash_soft, 0.001), phase);
    float tail = 1.0 - smoothstep(max(dash_duty - dash_soft, 0.001),
                                  max(dash_duty, 0.002), phase);
    float dash = head * tail;
    // 准星刻度恒亮（否则虚线相位一转，十字准星会"闪没"，像坏了）
    dash = mix(dash, 1.0, step(0.5, v_uv2.x));

    // --- 2) 宽度方向：中间亮芯 + 两侧辉光柔边（一刀切的硬边最廉价）---
    float across = abs(UV.y * 2.0 - 1.0);
    float core = 1.0 - smoothstep(edge_soft * 0.55, edge_soft, across);
    float halo = 1.0 - smoothstep(edge_soft * 0.75, 1.0, across);

    // --- 3) 呼吸：每个标记有自己的相位（UV2.y），多个圆环不会整齐划一地闪 ---
    float pulse = 1.0 + pulse_amount * sin(TIME * pulse_speed + v_uv2.y * 6.2831853);

    float light = core * core_power + halo * halo_power;
    float a = dash * light * base_opacity * v_col.a * fade * pulse;

    // 加色混合：贡献 = ALBEDO * ALPHA。亮芯把绿推到 1.3 左右，
    // 刚好够环境泛光(阈值 1.35)吃到一个不刺眼的光晕。
    ALBEDO = dash_color.rgb * v_col.rgb * (0.75 + 0.70 * core);
    ALPHA = clamp(a, 0.0, 1.0);
}