extends SceneTree

func _initialize() -> void:
	print(Engine.get_version_info())
	print("KEY_LEFT=", KEY_LEFT, " KEY_UP=", KEY_UP, " KEY_RIGHT=", KEY_RIGHT, " KEY_DOWN=", KEY_DOWN)
	quit()
