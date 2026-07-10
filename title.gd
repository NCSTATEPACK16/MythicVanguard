extends Control

func _ready():
	# Dev screenshot runs skip the title screen entirely
	var args = OS.get_cmdline_user_args()
	if "--screenshot-title" in args:
		_debug_screenshot()
	elif "--screenshot" in args or "--autodeploy" in args or "--rulestest" in args:
		get_tree().change_scene_to_file.call_deferred("res://main.tscn")
		return

	var play_button = $CenterBox/PlayButton
	play_button.pressed.connect(_on_play_pressed)

	# Gentle title pulse
	var title = $CenterBox/Title
	title.pivot_offset = title.size / 2.0
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(title, "scale", Vector2(1.03, 1.03), 1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(title, "scale", Vector2.ONE, 1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _on_play_pressed():
	GameManager.start_music()
	get_tree().change_scene_to_file("res://main.tscn")

func _debug_screenshot():
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://screenshot.png")
	print("screenshot saved: ", ProjectSettings.globalize_path("user://screenshot.png"))
	get_tree().quit()
