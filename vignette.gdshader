shader_type canvas_item;

// Radial darkening toward the screen edges, tinted. Used for the defeat
// overlay: a bloody vignette that closes in around the board.
uniform vec4 edge_color : source_color = vec4(0.45, 0.0, 0.0, 1.0);
uniform float strength : hint_range(0.0, 2.0) = 1.15;
uniform float inner : hint_range(0.0, 1.0) = 0.22;

void fragment() {
	float d = distance(UV, vec2(0.5));
	float v = smoothstep(inner, 0.78, d) * strength;
	COLOR = vec4(edge_color.rgb, clamp(v, 0.0, 1.0) * edge_color.a);
}
