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

	var diff = OptionButton.new()
	diff.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	diff.custom_minimum_size = Vector2(220, 0)
	var difficulties = ["easy", "hard", "legendary"]
	diff.add_item("AI: Easy")
	diff.add_item("AI: Hard")
	diff.add_item("AI: Legendary")
	diff.selected = maxi(0, difficulties.find(GameManager.ai_difficulty))
	diff.item_selected.connect(func(idx):
		GameManager.ai_difficulty = difficulties[idx]
		GameManager.save_settings())
	$CenterBox.add_child(diff)

	var mode = OptionButton.new()
	mode.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mode.custom_minimum_size = Vector2(220, 0)
	# Items: 0 Classic, 1 Blitz, then one entry per puzzle.
	mode.add_item("Mode: Classic")
	mode.add_item("Mode: Blitz")
	for i in range(GameManager.PUZZLES.size()):
		mode.add_item("Puzzle: %s" % GameManager.PUZZLES[i]["name"])
	var sel = 0
	if GameManager.match_mode == "blitz":
		sel = 1
	elif GameManager.match_mode == "puzzle":
		sel = 2 + GameManager.puzzle_index
	mode.selected = sel
	mode.item_selected.connect(func(idx):
		if idx == 0:
			GameManager.match_mode = "classic"
		elif idx == 1:
			GameManager.match_mode = "blitz"
		else:
			GameManager.match_mode = "puzzle"
			GameManager.puzzle_index = idx - 2
		GameManager.save_settings())
	$CenterBox.add_child(mode)

	var fast = CheckBox.new()
	fast.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	fast.text = "Fast animations"
	fast.button_pressed = GameManager.fast_anim
	fast.toggled.connect(func(on):
		GameManager.fast_anim = on
		GameManager.save_settings())
	$CenterBox.add_child(fast)

	var reveal = CheckBox.new()
	reveal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	reveal.text = "Variant: permanent reveal"
	reveal.button_pressed = GameManager.variant_permanent_reveal
	reveal.toggled.connect(func(on):
		GameManager.variant_permanent_reveal = on
		GameManager.save_settings())
	$CenterBox.add_child(reveal)

	var deadly = CheckBox.new()
	deadly.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	deadly.text = "Variant: deadly Assassin"
	deadly.button_pressed = GameManager.variant_assassin_any
	deadly.toggled.connect(func(on):
		GameManager.variant_assassin_any = on
		GameManager.save_settings())
	$CenterBox.add_child(deadly)

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
