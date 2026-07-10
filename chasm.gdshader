shader_type canvas_item;

// Animated dark-water shimmer for the impassable chasms.
void fragment() {
	vec2 uv = UV;
	float w1 = sin(uv.x * 18.0 + TIME * 1.2 + sin(uv.y * 9.0 + TIME * 0.7) * 2.0) * 0.5 + 0.5;
	float w2 = sin((uv.x + uv.y) * 14.0 - TIME * 0.9) * 0.5 + 0.5;
	vec3 deep = vec3(0.04, 0.10, 0.18);
	vec3 glow = vec3(0.10, 0.32, 0.42);
	vec3 col = mix(deep, glow, w1 * 0.55 + w2 * 0.45);
	// Soft inner vignette so the pool edges read darker
	float edge = smoothstep(0.0, 0.15, uv.x) * smoothstep(1.0, 0.85, uv.x)
		* smoothstep(0.0, 0.15, uv.y) * smoothstep(1.0, 0.85, uv.y);
	col *= mix(0.55, 1.0, edge);
	COLOR = vec4(col, 1.0);
}
