// =============================================================================
//  选中圈.gdshader  —— 贴地选中圆环（脉冲呼吸 + 队伍色）
// -----------------------------------------------------------------------------
//  用途：单位/建筑被选中时脚下的光环。
//  ★ 刻意用**程序化圆环**而不是环形网格：一个 2×2 的 QuadMesh + UV 距离场就能
//    画任意半径/粗细的环，缩放节点即可改半径，零网格开销、精确贴地。
//  关键参数：
//     team_color   队伍色（绿=玩家 / 红=敌人）
//     ring_radius  环的半径（UV 空间 0..1，1.0 = 贴到面片边缘）
//     ring_width   环宽
//     pulse_*      脉冲呼吸速度与幅度
//     dash_count   外圈刻度数（0 = 关闭刻度）
//     opacity      整体不透明度
// =============================================================================
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4  team_color : source_color = vec4(0.32, 1.0, 0.52, 1.0);
uniform float ring_radius : hint_range(0.05, 1.0) = 0.80;
uniform float ring_width : hint_range(0.005, 0.4) = 0.075;
uniform float inner_ring : hint_range(0.0, 1.0) = 0.0;
uniform float pulse_speed : hint_range(0.0, 12.0) = 2.4;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.32;
uniform float dash_count : hint_range(0.0, 48.0) = 16.0;
uniform float dash_strength : hint_range(0.0, 1.0) = 0.55;
uniform float opacity : hint_range(0.0, 2.0) = 0.95;
uniform float spin_speed : hint_range(-2.0, 2.0) = 0.22;

void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    float r = length(p);
    float ang = atan(p.y, p.x);

    // 抗锯齿：用屏幕导数估一个像素宽度
    float aa = max(fwidth(r), 0.0015);

    float ring = 1.0 - smoothstep(ring_width - aa, ring_width + aa, abs(r - ring_radius));
    // 内环（越界提示 / 建筑占地的第二道）
    float ring2 = 0.0;
    if (inner_ring > 0.001) {
        ring2 = 1.0 - smoothstep(ring_width * 0.55 - aa, ring_width * 0.55 + aa,
                                 abs(r - ring_radius * 0.62));
        ring2 *= inner_ring;
    }

    // 旋转刻度：让环"活"起来，而不是一张静态贴图
    float dash = 1.0;
    if (dash_count >= 1.0) {
        float a = fract((ang + TIME * spin_speed) / 6.2831853 * dash_count);
        dash = mix(1.0, smoothstep(0.35, 0.55, a) * smoothstep(1.0, 0.75, a),
                   dash_strength);
    }

    float pulse = 1.0 + pulse_amount * sin(TIME * pulse_speed);
    float a = clamp((ring * dash + ring2) * pulse * opacity, 0.0, 1.0);

    ALBEDO = team_color.rgb * (1.4 + 0.6 * pulse);
    ALPHA = a * team_color.a;
}
