// =============================================================================
//  沙盘网格.gdshader  —— 规划阶段的"固定势力范围"沙盘网格
// -----------------------------------------------------------------------------
//  用途：玩家/敌方初始区域的地面高光网格（蓝=我方、红=敌方）。
//        网格是**固定**的（按地图设计划区，不随战况扩张），只负责"这是谁的
//        地盘、边界在哪"。
//
//  一张网格里画五样东西（全部程序化，不用贴图）：
//    ① 细网格：每 cell 米一格，按屏幕导数做抗锯齿；远处自动淡成一层薄雾，
//       不会变成噪点（旧版贴图网格一拉远就糊成一片雪花）；
//    ② 主网格：every_n 格加粗一档，给"沙盘刻度"的读感；
//    ③ 边界：贴边一条亮线 + 向内衰减的辉光 —— 势力范围的分界线；
//    ④ 扫描：一道很缓的亮带沿 Z 向扫过（科技感，慢到不抢戏）；
//    ⑤ 流光：斜向流动的细亮纹，只叠在网格线上（不在空地上乱闪）。
//
//  另外还有一层"光墙"：uv2.x = 1 的顶点是边界处竖起来的一道渐变幕布，
//  让红蓝区在 3D 里读成"有高度的领地"，而不是一块贴纸。
//
//  关键参数：
//    zone_color    势力色（蓝/红）
//    zone_min/size 矩形（世界 XZ）
//    cell          细网格边长（米）
//    fade          整体淡入淡出（进/出规划阶段由脚本推，绝不硬切）
//    line_strength 网格线亮度；fill_strength 区内地色（很淡，别盖住地形）
//    edge_strength 边界亮度；scan_* / flow_* 扫描与流光
// =============================================================================
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 zone_color : source_color = vec4(0.32, 0.62, 1.0, 1.0);
uniform vec2 zone_min = vec2(-20.0, -20.0);
uniform vec2 zone_size = vec2(40.0, 40.0);
uniform float cell = 2.0;
uniform float major_every = 5.0;
uniform float fade = 1.0;
uniform float line_strength = 0.22;
uniform float fill_strength = 0.032;
uniform float edge_strength = 1.0;
uniform float scan_speed = 0.13;
uniform float scan_strength = 0.34;
uniform float flow_speed = 0.55;
uniform float pulse_speed = 0.85;

varying vec3 v_world;

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// 一格一格的线：返回 0..1 的"离线程度"，宽 1.1 像素（远处自然糊掉）
float grid_mask(vec2 p, vec2 fw, float width) {
    vec2 g = abs(fract(p + 0.5) - 0.5);
    vec2 m = 1.0 - smoothstep(vec2(0.0), fw * width, g);
    return max(m.x, m.y);
}

void fragment() {
    float curtain = step(0.5, UV2.x);
    float pulse = 0.90 + 0.10 * sin(TIME * pulse_speed);
    vec3 col = zone_color.rgb;
    float out_alpha = 0.0;

    if (curtain > 0.5) {
        // ------------------------------------------------------------ 光墙
        float hf = clamp(UV.y, 0.0, 1.0);
        // 底部亮、往上散开；竖向加一点肋骨状条纹，读成"能量幕"
        float body = pow(1.0 - hf, 2.4);
        float rib = 0.72 + 0.28 * sin(UV.x * 220.0 - TIME * 1.6);
        out_alpha = body * 0.52 * rib * fade * pulse;
        col *= (1.05 + 0.25 * body);
    } else {
        // ------------------------------------------------------------ 地面
        vec2 p = (v_world.xz - zone_min) / max(cell, 0.05);
        vec2 p_major = p / max(major_every, 1.0);
        vec2 fw = max(fwidth(p), vec2(0.0006));
        vec2 fw_major = max(fwidth(p_major), vec2(0.0006));

        float fine = grid_mask(p, fw, 1.00);
        float major = grid_mask(p_major, fw_major, 1.30);

        // 远处（一格不足一像素）把细线淡掉，只留下主网格 + 地色，避免噪点/糊成一片红
        float near = clamp(1.0 - max(fw.x, fw.y) * 3.2, 0.0, 1.0);
        fine *= near;

        // 边界距离（世界米）
        vec2 to_edge = min(v_world.xz - zone_min, zone_min + zone_size - v_world.xz);
        float edge_d = min(to_edge.x, to_edge.y);
        float edge_aa = max(fwidth(edge_d), 0.002);
        float edge_line = 1.0 - smoothstep(0.0, 0.09 + edge_aa * 1.6, abs(edge_d - 0.06));
        float edge_glow = exp(-max(edge_d, 0.0) * 0.42);

        // 扫描带（沿 Z 缓慢扫过整块领地）
        float zt = (v_world.z - zone_min.y) / max(zone_size.y, 1.0);
        float sweep = fract(zt - TIME * scan_speed);
        float band = exp(-pow((sweep - 0.5) * 5.2, 2.0));

        // 斜向流光（只叠在线上）
        float flow = pow(0.5 + 0.5 * sin((v_world.x * 0.20 + v_world.z * 0.14) - TIME * flow_speed), 7.0);

        float lines = clamp(fine * line_strength + major * 0.20, 0.0, 1.6);
        float light = lines;
        light += fill_strength * (0.65 + 0.75 * edge_glow);      // 区内地色
        light += band * scan_strength * (0.28 + lines * 0.9);    // 扫描
        light += flow * 0.34 * lines;                            // 流光
        light += edge_glow * 0.14 * edge_strength;               // 边界内辉光
        light += edge_line * 1.35 * edge_strength;               // 边界亮线
        light *= pulse;

        out_alpha = light * fade * zone_color.a;
        col *= 0.86 + 0.42 * major + 0.70 * edge_line + 0.22 * band;
    }

    ALBEDO = col;
    ALPHA = clamp(out_alpha, 0.0, 1.0);
}
