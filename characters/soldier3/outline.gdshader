shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled;

// Inverted-hull outline. A second MeshInstance3D shares the paladin's mesh and
// skeleton, runs the same GPU skinning, and is pushed out along its own normals
// far enough to clear the silhouette in front of the body. Front faces are
// culled, so all that remains visible is the rim poking past the model.
uniform float outline_width : hint_range(0.0, 0.05, 0.001) = 0.012;
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
