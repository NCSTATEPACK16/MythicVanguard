extends Node2D

const TILE_SIZE = 80
const BOARD_SIZE = 10

var grid = []

# Setup phase state
var pool_counts = {}
var selected_deploy_type: String = ""
var tray_buttons = {}

# Play phase state
var selected_piece = null
var valid_moves = []
var last_move_from: Vector2i = Vector2i(-1, -1)
var last_move_to: Vector2i = Vector2i(-1, -1)

var PieceScene = preload("res://piece.tscn")
var ExplosionScene = preload("res://explosion.tscn")
var ai = preload("res://ai_controller.gd").new()

@onready var camera = $Camera2D
@onready var ui = $CanvasLayer/UI
@onready var current_turn_label = $CanvasLayer/UI/CurrentTurnLabel

var deploy_panel: PanelContainer
var start_button: Button
var captured_panel: PanelContainer
var player_losses_list: VBoxContainer
var enemy_losses_list: VBoxContainer
var banner: Label

var _pulse_time: float = 0.0

func _ready():
	_initialize_grid()
	_center_camera()
	_build_chasm_overlays()
	_build_deploy_tray()
	_build_captured_panel()
	_build_banner()
	pool_counts = GameManager.REQUIRED_PIECES.duplicate()
	_refresh_tray()
	_generate_ai_setup()
	current_turn_label.text = "Deploy Your Army"
	queue_redraw()
	if "--screenshot" in OS.get_cmdline_user_args():
		_debug_screenshot()

# Dev helper: `godot --path . -- --screenshot [--autodeploy] [--aitest]` saves a
# PNG of the running game to user://screenshot.png and quits.
func _debug_screenshot():
	await get_tree().create_timer(1.0).timeout
	var args = OS.get_cmdline_user_args()
	if "--autodeploy" in args:
		_on_auto_deploy_pressed()
		_on_start_battle_pressed()
		await get_tree().create_timer(1.0).timeout
	if "--aitest" in args:
		await _debug_play_turns(25)
	if "--victory" in args:
		GameManager.current_state = GameManager.GameState.GAME_OVER
		_show_victory_screen(true)
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var img = get_viewport().get_texture().get_image()
	img.save_png("user://screenshot.png")
	print("screenshot saved: ", ProjectSettings.globalize_path("user://screenshot.png"))
	get_tree().quit()

# Plays N random player moves, letting the AI answer each one.
func _debug_play_turns(turns: int):
	for i in range(turns):
		if GameManager.current_state != GameManager.GameState.PLAYER_TURN:
			break
		var candidates = []
		for x in range(BOARD_SIZE):
			for y in range(BOARD_SIZE):
				var p = _piece_at(Vector2i(x, y))
				if p and p.data.team == GameManager.Team.PLAYER:
					var moves = _calculate_valid_moves(p)
					if moves.size() > 0:
						candidates.append({"piece": p, "moves": moves})
		if candidates.is_empty():
			break
		var pick = candidates[randi() % candidates.size()]
		var target = pick["moves"][randi() % pick["moves"].size()]
		print("[aitest] player: %s %s -> %s" % [pick["piece"].data.type, pick["piece"].current_grid_pos, target])
		_execute_move(pick["piece"], target, true)
		while GameManager.current_state != GameManager.GameState.PLAYER_TURN:
			if GameManager.current_state == GameManager.GameState.GAME_OVER:
				return
			await get_tree().process_frame
		print("[aitest] ai moved: %s -> %s" % [last_move_from, last_move_to])

func _initialize_grid():
	grid.resize(BOARD_SIZE)
	for x in range(BOARD_SIZE):
		grid[x] = []
		grid[x].resize(BOARD_SIZE)
		for y in range(BOARD_SIZE):
			if (x == 2 or x == 3 or x == 6 or x == 7) and (y == 4 or y == 5):
				grid[x][y] = "CHASM"
			else:
				grid[x][y] = null

func _is_chasm(pos: Vector2i) -> bool:
	return typeof(grid[pos.x][pos.y]) == TYPE_STRING and grid[pos.x][pos.y] == "CHASM"

func _piece_at(pos: Vector2i):
	var cell = grid[pos.x][pos.y]
	if typeof(cell) == TYPE_NIL or typeof(cell) == TYPE_STRING:
		return null
	return cell

func _in_bounds(pos: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < BOARD_SIZE and pos.y >= 0 and pos.y < BOARD_SIZE

func _tile_center(pos: Vector2i) -> Vector2:
	return Vector2(pos.x * TILE_SIZE + TILE_SIZE / 2.0, pos.y * TILE_SIZE + TILE_SIZE / 2.0)

func _center_camera():
	camera.position = Vector2(BOARD_SIZE * TILE_SIZE / 2.0, BOARD_SIZE * TILE_SIZE / 2.0)

func _build_chasm_overlays():
	var shader = load("res://chasm.gdshader")
	for origin in [Vector2(2, 4), Vector2(6, 4)]:
		var rect = ColorRect.new()
		rect.material = ShaderMaterial.new()
		rect.material.shader = shader
		rect.position = origin * TILE_SIZE
		rect.size = Vector2(2, 2) * TILE_SIZE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)

func _process(delta):
	# Gentle pulse on the valid-move markers
	if GameManager.current_state == GameManager.GameState.PLAYER_TURN and valid_moves.size() > 0:
		_pulse_time += delta
		queue_redraw()

# ---------------------------------------------------------------- UI building

func _build_deploy_tray():
	deploy_panel = PanelContainer.new()
	deploy_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	deploy_panel.offset_left = -320
	deploy_panel.offset_right = -20
	deploy_panel.offset_top = -420
	deploy_panel.offset_bottom = 420
	ui.add_child(deploy_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	deploy_panel.add_child(vbox)

	var title = Label.new()
	title.text = "Deploy Your Army"
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint = Label.new()
	hint.text = "Pick a unit, then click a tile\nin your bottom 4 rows."
	hint.add_theme_font_size_override("font_size", 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	var group = ButtonGroup.new()
	for type in GameManager.REQUIRED_PIECES.keys():
		var btn = Button.new()
		btn.toggle_mode = true
		btn.button_group = group
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_tray_type_pressed.bind(type))
		vbox.add_child(btn)
		tray_buttons[type] = btn

	vbox.add_child(HSeparator.new())

	var auto_btn = Button.new()
	auto_btn.text = "Auto-Deploy Remaining"
	auto_btn.pressed.connect(_on_auto_deploy_pressed)
	vbox.add_child(auto_btn)

	var rand_btn = Button.new()
	rand_btn.text = "Randomize All"
	rand_btn.pressed.connect(_on_randomize_pressed)
	vbox.add_child(rand_btn)

	start_button = Button.new()
	start_button.text = "Start Battle!"
	start_button.disabled = true
	start_button.add_theme_font_size_override("font_size", 22)
	start_button.pressed.connect(_on_start_battle_pressed)
	vbox.add_child(start_button)

	var mute_btn = Button.new()
	mute_btn.text = "Mute Sound" if not GameManager.muted else "Unmute Sound"
	mute_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mute_btn.offset_left = -160
	mute_btn.offset_right = -20
	mute_btn.offset_top = 20
	mute_btn.offset_bottom = 55
	mute_btn.pressed.connect(func():
		mute_btn.text = "Unmute Sound" if GameManager.toggle_mute() else "Mute Sound")
	ui.add_child(mute_btn)

func _rank_display(type: String) -> String:
	if type == "Ward":
		return "W"
	elif type == "Relic":
		return "R"
	return str(GameManager.RANKS[type])

func _refresh_tray():
	var remaining_total = 0
	for type in tray_buttons.keys():
		var count = pool_counts[type]
		remaining_total += count
		var btn: Button = tray_buttons[type]
		btn.text = "%2s  %s   ×%d" % [_rank_display(type), type, count]
		btn.disabled = count == 0
		if count == 0 and selected_deploy_type == type:
			btn.button_pressed = false
			selected_deploy_type = ""
	start_button.disabled = remaining_total > 0
	if remaining_total == 0:
		current_turn_label.text = "Army Ready — Start the Battle!"

	# Auto-advance selection to the next available type
	if selected_deploy_type == "":
		for type in tray_buttons.keys():
			if pool_counts[type] > 0:
				selected_deploy_type = type
				tray_buttons[type].button_pressed = true
				break

func _build_captured_panel():
	captured_panel = PanelContainer.new()
	captured_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	captured_panel.offset_left = 20
	captured_panel.offset_right = 280
	captured_panel.offset_top = -420
	captured_panel.offset_bottom = 420
	captured_panel.visible = false
	ui.add_child(captured_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	captured_panel.add_child(vbox)

	var enemy_title = Label.new()
	enemy_title.text = "Enemy Losses"
	enemy_title.add_theme_font_size_override("font_size", 22)
	enemy_title.add_theme_color_override("font_color", Color.TOMATO)
	vbox.add_child(enemy_title)

	enemy_losses_list = VBoxContainer.new()
	var enemy_scroll = ScrollContainer.new()
	enemy_scroll.custom_minimum_size = Vector2(0, 330)
	enemy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	enemy_scroll.add_child(enemy_losses_list)
	vbox.add_child(enemy_scroll)

	vbox.add_child(HSeparator.new())

	var player_title = Label.new()
	player_title.text = "Your Losses"
	player_title.add_theme_font_size_override("font_size", 22)
	player_title.add_theme_color_override("font_color", Color.CORNFLOWER_BLUE)
	vbox.add_child(player_title)

	player_losses_list = VBoxContainer.new()
	var player_scroll = ScrollContainer.new()
	player_scroll.custom_minimum_size = Vector2(0, 330)
	player_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	player_scroll.add_child(player_losses_list)
	vbox.add_child(player_scroll)

func _record_capture(piece):
	var entry = Label.new()
	entry.text = "%s  %s" % [_rank_display(piece.data.type), piece.data.type]
	entry.add_theme_font_size_override("font_size", 18)
	if piece.data.team == GameManager.Team.PLAYER:
		entry.add_theme_color_override("font_color", Color.CORNFLOWER_BLUE)
		player_losses_list.add_child(entry)
	else:
		entry.add_theme_color_override("font_color", Color.TOMATO)
		enemy_losses_list.add_child(entry)

func _build_banner():
	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 90)
	banner.add_theme_constant_override("outline_size", 16)
	banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.modulate.a = 0.0
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(banner)

func _show_banner(text: String, color: Color):
	banner.text = text
	banner.add_theme_color_override("font_color", color)
	banner.pivot_offset = banner.size / 2.0
	banner.scale = Vector2(0.85, 0.85)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(banner, "modulate:a", 1.0, 0.25)
	tween.tween_property(banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_interval(0.7)
	tween.tween_property(banner, "modulate:a", 0.0, 0.3)

# ---------------------------------------------------------------- board drawing

func _draw():
	# Outer frame
	var board_px = BOARD_SIZE * TILE_SIZE
	draw_rect(Rect2(-8, -8, board_px + 16, board_px + 16), Color(0.16, 0.12, 0.08))

	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var rect = Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
			var color: Color

			if _is_chasm(Vector2i(x, y)):
				color = Color(0.04, 0.10, 0.18)  # base under the shader overlay
			elif (x + y) % 2 == 0:
				color = Color(0.47, 0.60, 0.38)
			else:
				color = Color(0.40, 0.53, 0.32)

			draw_rect(rect, color)
			draw_rect(rect, Color(0, 0, 0, 0.12), false, 1.0)

	# During setup, show the player's deployable zone
	if GameManager.current_state == GameManager.GameState.SETUP:
		for x in range(BOARD_SIZE):
			for y in range(6, BOARD_SIZE):
				if _piece_at(Vector2i(x, y)) == null:
					var rect = Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
					draw_rect(rect, Color(0.35, 0.55, 0.95, 0.18))

	# Last-move marker
	if last_move_from.x >= 0:
		var from_rect = Rect2(last_move_from.x * TILE_SIZE, last_move_from.y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
		var to_rect = Rect2(last_move_to.x * TILE_SIZE, last_move_to.y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
		draw_rect(from_rect, Color(1.0, 0.85, 0.2, 0.9), false, 4.0)
		draw_rect(to_rect, Color(1.0, 0.85, 0.2, 0.9), false, 4.0)

	if GameManager.current_state == GameManager.GameState.PLAYER_TURN:
		var pulse = 0.55 + 0.25 * sin(_pulse_time * 5.0)
		for pos in valid_moves:
			var center = _tile_center(pos)
			if _piece_at(pos) != null:
				# Attack target: red ring
				draw_arc(center, 27.0, 0.0, TAU, 40, Color(0.95, 0.25, 0.2, pulse), 4.0)
			else:
				draw_circle(center, 13.0, Color(0.95, 0.92, 0.55, pulse))

		if selected_piece:
			var pos = selected_piece.current_grid_pos
			var rect = Rect2(pos.x * TILE_SIZE + 3, pos.y * TILE_SIZE + 3, TILE_SIZE - 6, TILE_SIZE - 6)
			draw_rect(rect, Color(1.0, 0.85, 0.2, 0.95), false, 4.0)

# ---------------------------------------------------------------- setup phase

func _spawn_piece(team, type: String, pos: Vector2i):
	var piece = PieceScene.instantiate()
	add_child(piece)
	piece.initialize(GameManager.create_piece_data(team, type))
	piece.global_position = _tile_center(pos)
	piece.current_grid_pos = pos
	grid[pos.x][pos.y] = piece
	piece.piece_clicked.connect(_on_piece_clicked)
	if team == GameManager.Team.PLAYER:
		piece.piece_dropped.connect(_on_piece_dropped)
	return piece

func _on_tray_type_pressed(type: String):
	selected_deploy_type = type

func _try_deploy_at(pos: Vector2i):
	if selected_deploy_type == "" or pool_counts.get(selected_deploy_type, 0) <= 0:
		return
	if pos.y < 6 or not _in_bounds(pos):
		return
	if grid[pos.x][pos.y] != null:
		return
	_spawn_piece(GameManager.Team.PLAYER, selected_deploy_type, pos)
	pool_counts[selected_deploy_type] -= 1
	GameManager.play_sfx("deploy")
	_refresh_tray()
	queue_redraw()

func _player_deploy_positions() -> Array:
	var empty = []
	for x in range(BOARD_SIZE):
		for y in range(6, BOARD_SIZE):
			if grid[x][y] == null:
				empty.append(Vector2i(x, y))
	return empty

func _on_auto_deploy_pressed():
	var empty = _player_deploy_positions()
	empty.shuffle()
	var back = []
	var front = []
	for pos in empty:
		if pos.y >= 8:
			back.append(pos)
		else:
			front.append(pos)

	var take_pos = func(prefer_back: bool):
		if prefer_back and back.size() > 0:
			return back.pop_back()
		elif front.size() > 0:
			return front.pop_back()
		elif back.size() > 0:
			return back.pop_back()
		return null

	# Relic and Wards go to the back rows first
	for type in ["Relic", "Ward"]:
		while pool_counts[type] > 0:
			var pos = take_pos.call(true)
			if pos == null:
				break
			_spawn_piece(GameManager.Team.PLAYER, type, pos)
			pool_counts[type] -= 1

	for type in pool_counts.keys():
		while pool_counts[type] > 0:
			var pos = take_pos.call(false)
			if pos == null:
				break
			_spawn_piece(GameManager.Team.PLAYER, type, pos)
			pool_counts[type] -= 1

	_refresh_tray()
	queue_redraw()

func _on_randomize_pressed():
	for x in range(BOARD_SIZE):
		for y in range(6, BOARD_SIZE):
			var piece = _piece_at(Vector2i(x, y))
			if piece and piece.data.team == GameManager.Team.PLAYER:
				grid[x][y] = null
				piece.queue_free()
	pool_counts = GameManager.REQUIRED_PIECES.duplicate()
	_on_auto_deploy_pressed()

func _on_start_battle_pressed():
	if GameManager.current_state != GameManager.GameState.SETUP:
		return
	deploy_panel.visible = false
	captured_panel.visible = true
	GameManager.current_state = GameManager.GameState.PLAYER_TURN
	current_turn_label.text = "Your Turn"
	_show_banner("Battle Begins!", Color.GOLD)
	GameManager.play_sfx("battle_start")
	queue_redraw()

func _generate_ai_setup():
	var available_positions = []
	for x in range(BOARD_SIZE):
		for y in range(4):
			available_positions.append(Vector2i(x, y))

	available_positions.shuffle()

	var back_positions = []
	var front_positions = []
	for pos in available_positions:
		if pos.y <= 1:
			back_positions.append(pos)
		else:
			front_positions.append(pos)

	var place_piece = func(type, is_back_row):
		var pos
		if is_back_row and back_positions.size() > 0:
			pos = back_positions.pop_back()
		elif front_positions.size() > 0:
			pos = front_positions.pop_back()
		else:
			pos = back_positions.pop_back()
		_spawn_piece(GameManager.Team.ENEMY, type, pos)

	place_piece.call("Relic", true)
	for i in range(GameManager.REQUIRED_PIECES["Ward"]):
		place_piece.call("Ward", true)

	for type in GameManager.REQUIRED_PIECES.keys():
		if type != "Relic" and type != "Ward":
			for i in range(GameManager.REQUIRED_PIECES[type]):
				place_piece.call(type, false)

func _on_piece_dropped(piece):
	if GameManager.current_state != GameManager.GameState.SETUP:
		return

	var drop_pos = piece.global_position
	var target = Vector2i(int(drop_pos.x / TILE_SIZE), int(drop_pos.y / TILE_SIZE))

	if _in_bounds(target) and target.y >= 6 and grid[target.x][target.y] == null:
		grid[piece.current_grid_pos.x][piece.current_grid_pos.y] = null
		var tween = create_tween()
		tween.tween_property(piece, "global_position", _tile_center(target), 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		piece.current_grid_pos = target
		grid[target.x][target.y] = piece
	else:
		# Snap back to where it came from
		var tween = create_tween()
		tween.tween_property(piece, "global_position", _tile_center(piece.current_grid_pos), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	queue_redraw()

# ---------------------------------------------------------------- play phase

func _on_piece_clicked(piece):
	if GameManager.current_state != GameManager.GameState.PLAYER_TURN:
		return

	if piece.data.team == GameManager.Team.PLAYER:
		if piece == selected_piece:
			selected_piece = null
			valid_moves.clear()
		elif piece.data.type != "Ward" and piece.data.type != "Relic":
			selected_piece = piece
			valid_moves = _calculate_valid_moves(piece)
			GameManager.play_sfx("select")
		queue_redraw()
	elif piece.data.team == GameManager.Team.ENEMY:
		if selected_piece and piece.current_grid_pos in valid_moves:
			_execute_move(selected_piece, piece.current_grid_pos, true)

func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var pos = get_global_mouse_position()
		var target = Vector2i(int(pos.x / TILE_SIZE), int(pos.y / TILE_SIZE))
		if pos.x < 0 or pos.y < 0 or not _in_bounds(target):
			return

		if GameManager.current_state == GameManager.GameState.SETUP:
			_try_deploy_at(target)
		elif GameManager.current_state == GameManager.GameState.PLAYER_TURN:
			if selected_piece and target in valid_moves and _piece_at(target) == null:
				_execute_move(selected_piece, target, true)

func _calculate_valid_moves(piece) -> Array:
	var moves = []
	var pos = piece.current_grid_pos

	if piece.data.type == "Ward" or piece.data.type == "Relic":
		return moves

	var directions = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

	if piece.data.type == "Runner":
		for dir in directions:
			var current_check = pos + dir
			while _in_bounds(current_check):
				if _is_chasm(current_check):
					break
				var piece_at_pos = _piece_at(current_check)
				if piece_at_pos:
					if piece_at_pos.data.team != piece.data.team:
						moves.append(current_check)
					break
				moves.append(current_check)
				current_check += dir
	else:
		for dir in directions:
			var current_check = pos + dir
			if _in_bounds(current_check):
				if _is_chasm(current_check):
					continue
				var piece_at_pos = _piece_at(current_check)
				if piece_at_pos:
					if piece_at_pos.data.team != piece.data.team:
						moves.append(current_check)
				else:
					moves.append(current_check)
	return moves

func _execute_move(piece_to_move, target_pos: Vector2i, is_player: bool):
	GameManager.current_state = GameManager.GameState.ANIMATING

	var old_pos = piece_to_move.current_grid_pos
	var target_tile = _piece_at(target_pos)

	grid[old_pos.x][old_pos.y] = null
	last_move_from = old_pos
	last_move_to = target_pos

	selected_piece = null
	valid_moves.clear()
	queue_redraw()

	var start_world_pos = piece_to_move.global_position
	var end_world_pos = _tile_center(target_pos)

	if target_tile:
		# Combat
		var result = GameManager.resolve_combat(piece_to_move.data, target_tile.data)

		# Slide forward to bump
		GameManager.play_sfx("clash")
		piece_to_move.z_index = 50
		var bump_tween = create_tween()
		var halfway_pos = start_world_pos.lerp(end_world_pos, 0.6)
		bump_tween.tween_property(piece_to_move, "global_position", halfway_pos, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await bump_tween.finished

		# Reveal pieces
		target_tile.data.is_revealed = true
		target_tile._update_visuals()
		piece_to_move.data.is_revealed = true
		piece_to_move._update_visuals()

		await get_tree().create_timer(1.0).timeout

		if result == "attacker_wins" or result == "game_over":
			_explode_at(target_tile)
			_record_capture(target_tile)
			target_tile.queue_free()

			var land_tween = create_tween()
			land_tween.tween_property(piece_to_move, "global_position", end_world_pos, 0.15).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
			await land_tween.finished

			grid[target_pos.x][target_pos.y] = piece_to_move
			piece_to_move.current_grid_pos = target_pos

		elif result == "defender_wins":
			_explode_at(piece_to_move)
			_record_capture(piece_to_move)
			piece_to_move.queue_free()

			# Little shake for the victorious defender
			var shake_tween = create_tween()
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(10, 0), 0.05)
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(-10, 0), 0.05)
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(0, 0), 0.05)
			await shake_tween.finished

		elif result == "draw":
			_explode_at(target_tile)
			_explode_at(piece_to_move)
			_record_capture(target_tile)
			_record_capture(piece_to_move)
			target_tile.queue_free()
			piece_to_move.queue_free()
			grid[target_pos.x][target_pos.y] = null
			await get_tree().create_timer(0.2).timeout

		if is_instance_valid(piece_to_move):
			piece_to_move.z_index = 10

		if result == "game_over":
			GameManager.current_state = GameManager.GameState.GAME_OVER
			_show_victory_screen(is_player)
			return
	else:
		# Empty tile smooth slide
		GameManager.play_sfx("move")
		var slide_tween = create_tween()
		slide_tween.tween_property(piece_to_move, "global_position", end_world_pos, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await slide_tween.finished

		grid[target_pos.x][target_pos.y] = piece_to_move
		piece_to_move.current_grid_pos = target_pos

	queue_redraw()

	if GameManager.current_state != GameManager.GameState.GAME_OVER:
		if is_player:
			GameManager.current_state = GameManager.GameState.AI_TURN
			current_turn_label.text = "Enemy Turn"
			_show_banner("Enemy Turn", Color.TOMATO)
			_execute_ai_turn()
		else:
			GameManager.current_state = GameManager.GameState.PLAYER_TURN
			current_turn_label.text = "Your Turn"
			_show_banner("Your Turn", Color.CORNFLOWER_BLUE)
			queue_redraw()

func _explode_at(piece):
	GameManager.play_sfx("destroyed")
	var explosion = ExplosionScene.instantiate()
	explosion.global_position = piece.global_position
	explosion.color = Color.TOMATO if piece.data.team == GameManager.Team.ENEMY else Color.CORNFLOWER_BLUE
	add_child(explosion)

func _execute_ai_turn():
	await get_tree().create_timer(0.8).timeout

	var move = ai.choose_move(self)
	if move.is_empty():
		# AI has no legal moves: the player wins by stalemate
		GameManager.current_state = GameManager.GameState.GAME_OVER
		_show_victory_screen(true)
		return
	_execute_move(move["piece"], move["target"], false)

func _show_victory_screen(player_won: bool):
	GameManager.play_sfx("victory" if player_won else "defeat")
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	$CanvasLayer.add_child(overlay)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.offset_left = -400
	vbox.offset_right = 400
	vbox.offset_top = -160
	vbox.offset_bottom = 160
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 30)
	overlay.add_child(vbox)

	var label = Label.new()
	label.text = "VICTORY!" if player_won else "DEFEAT!"
	label.add_theme_font_size_override("font_size", 120)
	label.add_theme_color_override("font_color", Color.GOLD if player_won else Color.CRIMSON)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(label)

	var again = Button.new()
	again.text = "Play Again"
	again.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	again.add_theme_font_size_override("font_size", 32)
	again.pressed.connect(func():
		GameManager.current_state = GameManager.GameState.SETUP
		get_tree().reload_current_scene())
	vbox.add_child(again)

	if player_won:
		for i in range(3):
			var confetti = ExplosionScene.instantiate()
			confetti.global_position = Vector2(960, 540)
			confetti.amount = 200
			confetti.lifetime = 2.5
			confetti.spread = 360
			confetti.initial_velocity_min = 300
			confetti.initial_velocity_max = 800
			confetti.scale_amount_min = 10
			confetti.scale_amount_max = 20

			var colors = [Color.RED, Color.GREEN, Color.CORNFLOWER_BLUE, Color.GOLD, Color.PURPLE]
			confetti.color = colors[i % colors.size()]
			$CanvasLayer.add_child(confetti)
