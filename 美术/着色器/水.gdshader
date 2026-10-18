// =============================================================================
//  水.gdshader  —— 卡通水面
// -----------------------------------------------------------------------------
//  用途：低多边形水域。顶点做正弦波起伏，片元做**阶梯菲涅尔**（3 步），
//        反射色用简化的天空色 mix，不用真反射（省一个 pass，RTS 俯视看不出差别）。
//  关键参数：shallow/deep/sky 三色决定水体读感；wave_* 控制波纹；
//           fresnel_steps 阶梯数；alpha_base 基础不透明度。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_disabled;

uniform vec4  shallow_color : source_color = vec4(0.26, 0.55, 0.62, 1.0);
uniform vec4  deep_color : source_color = vec4(0.075, 0.19, 0.32, 1.0);
uniform vec4  sky_color : source_color = vec4(0.60, 0.72, 0.90, 1.0);
uniform vec4  foam_color : source_color = vec4(0.88, 0.93, 0.96, 1.0);

uniform float wave_scale : hint_range(0.1, 12.0) = 3.4;
uniform float wave_speed : hint_range(0.0, 4.0) = 1.15;
uniform float wave_amp : hint_range(0.0, 0.5) = 0.055;
uniform float ripple_scale : hint_range(0.1, 40.0) = 9.0;

uniform float fresnel_steps : hint_range(1.0, 6.0) = 3.0;
uniform float alpha_base : hint_range(0.0, 1.0) = 0.80;
uniform float foam_amount : hint_range(0.0, 1.0) = 0.35;
uniform vec3  shadow_color : source_color = vec3(0.30, 0.38, 0.58);

varying vec3 v_world;
varying vec3 v_wn;

void vertex() {
    vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float t = TIME * wave_speed;
    float h = sin(w.x * wave_scale + t) * cos(w.z * wave_scale * 0.86 - t * 0.8);
    h += 0.45 * sin((w.x + w.z) * wave_scale * 1.9 + t * 1.7);
    VERTEX.y += h * wave_amp;
    v_world = w;
    v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    // 用波形的解析导数伪造法线（比逐帧重算法线省）
    float t = TIME * wave_speed;
    float dx = cos(v_world.x * wave_scale + t) * wave_scale;
    float dz = -sin(v_world.z * wave_scale * 0.86 - t * 0.8) * wave_scale * 0.86;
    vec3 bump = normalize(vec3(-dx * wave_amp * 2.2, 1.0, -dz * wave_amp * 2.2));
    vec3 nrm = normalize(mix(v_wn, bump, 0.75));

    // 阶梯菲涅尔
    float f = 1.0 - clamp(dot(nrm, normalize(VIEW)), 0.0, 1.0);
    float fs = floor(clamp(f, 0.0, 0.999) * fresnel_steps) / max(1.0, fresnel_steps - 1.0);
    fs = clamp(fs, 0.0, 1.0);

    vec3 col = mix(deep_color.rgb, shallow_color.rgb, 1.0 - fs);
    col = mix(col, sky_color.rgb, fs * 0.85);

    // 泡沫/波纹亮点
    float r = sin(v_world.x * ripple_scale + t * 2.0) * cos(v_world.z * ripple_scale - t * 1.6);
    float foam = smoothstep(0.80, 1.0, r) * foam_amount;
    col = mix(col, foam_color.rgb, foam);

    ALBEDO = col;
    ROUGHNESS = 0.16;
    METALLIC = 0.0;
    ALPHA = clamp(alpha_base + foam * 0.25 + fs * 0.15, 0.0, 1.0);
}
