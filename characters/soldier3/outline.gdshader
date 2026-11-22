shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;

// Inverted-hull outline. A second MeshInstance3D shares the paladin's mesh and
// skeleton, runs the same GPU skinning, and is pushed out along its own normals
// far enough to clear the silhouette in front of the body. Front faces are
// culled, so all that remains visible is the rim poking past the model.
//
// depth_draw_opaque lets the hull write depth so the real body still occludes
// it correctly; shadows_disabled stops the expanded copy casting its own,
// slightly larger shadow.
uniform float outline_width : hint_range(0.0, 0.05, 0.001) = 0.012;
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void vertex() {
	// Expand in world space so a non-uniform node scale cannot skew the width.
	VERTEX += NORMAL * outline_width;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * (MODEL_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	ALBEDO = outline_color.rgb;
	// Unshaded, so ALPHA is used directly rather than as a fade mask.
	ALPHA = outline_color.a;
}
