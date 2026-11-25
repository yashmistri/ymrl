# Godot Project Rules

- **Must use MCP or tell the user to set it up.** Always check `godot-ai` (`session_manage` -> `session_activate`) and prioritize using `godot-ai` MCP tools (`scene_open`, `scene_manage`, `node_create`, `node_set_property`, `node_manage`, `scene_save`, `resource_manage`, etc.) over editing `.tscn` / `.tres` scene files directly.
- If the `godot-ai` MCP server has no connected/ready Godot editor session, stop and tell the user to open Godot / set up the MCP plugin instead of bypassing MCP with direct `.tscn` edits.
- **Scene Hierarchy Over Script Spawning:** Add nodes, configure exported/inspector properties, timers, cameras, UI rows, and static actors directly in the `.tscn` scene hierarchy via `godot-ai` MCP—do not create/spawn persistent scene nodes or configure scene properties in GDScript unless strictly required for dynamic runtime behavior (e.g., CLI overrides, arena rotation, or pooled respawns).
