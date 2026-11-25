extends SceneTree

func _init():
	var nr = NavigationRegion3D.new()
	var list := []
	for m in nr.get_method_list():
		if "bake" in m["name"]:
			list.append(m["name"])
	print("NavigationRegion3D bake methods: ", list)
	quit(0)
