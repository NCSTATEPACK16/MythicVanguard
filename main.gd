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
var armed_attack: Vector2i = Vector2i(-1, -1)

var PieceScene = preload("res://piece.tscn")
var ExplosionScene = preload("res://explosion.tscn")
var ai = preload("res://ai_controller.gd").new()

# How long a rank stays visible after a combat before hiding again.
const COMBAT_REVEAL_TIME = 2.0

@onready var camera = $Camera2D
@onready var ui = $CanvasLayer/UI
@onready var current_turn_label = $CanvasLayer/UI/CurrentTurnLabel

var deploy_panel: PanelContainer
var start_button: Button
var captured_panel: PanelContainer
var player_losses_list: VBoxContainer
var enemy_losses_list: VBoxContainer
var banner: Label
var combat_label: Label
var captured_counts = {}
var forces_labels = {}
var history_panel: PanelContainer
var history_list: VBoxContainer
var history_scroll: ScrollContainer
var move_number: int = 0
var rules_overlay: PanelContainer

var attack_confirm_overlay: ColorRect
var attack_confirm_label: Label

var _pulse_time: float = 0.0

func _ready():
	_initialize_grid()
	_center_camera()
	_build_chasm_overlays()
	_build_deploy_tray()
	_build_captured_panel()
	_build_banner()
	_build_history_panel()
	_build_rules_overlay()
	_build_attack_confirm()
	captured_counts = {GameManager.Team.PLAYER: {}, GameManager.Team.ENEMY: {}}
	pool_counts = GameManager.REQUIRED_PIECES.duplicate()
	_refresh_tray()
	_generate_ai_setup()
	current_turn_label.text = "Deploy Your Army"
	queue_redraw()
	if "--screenshot" in OS.get_cmdline_user_args():
		_debug_screenshot()
	if "--rulestest" in OS.get_cmdline_user_args():
		_debug_rules_test.call_deferred()

# Dev helper: `godot --path . -- --screenshot [--autodeploy] [--aitest]` saves a
# PNG of the running game to user://screenshot.png and quits.
func _debug_screenshot():
	await get_tree().create_timer(1.0).timeout
	var args = OS.get_cmdline_user_args()
	if "--legendary" in args:
		GameManager.ai_difficulty = "legendary"
	if "--autodeploy" in args:
		_on_auto_deploy_pressed()
		_on_start_battle_pressed()
		await get_tree().create_timer(1.0).timeout
	if "--aitest" in args:
		await _debug_play_turns(25)
	if "--victory" in args:
		GameManager.current_state = GameManager.GameState.GAME_OVER
		_show_victory_screen(true)
	if "--defeat" in args:
		GameManager.current_state = GameManager.GameState.GAME_OVER
		_show_victory_screen(false)
	if "--rulesoverlay" in args:
		rules_overlay.visible = true
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

# Quick decaying camera shake for combat impacts. Tweens the camera offset
# through a few random points, then settles back to zero so board centering
# (which uses position) is untouched.
func _screen_shake(strength: float = 8.0, duration: float = 0.2):
	var steps = 6
	var step_t = GameManager.anim_time(duration / steps)
	var tw = create_tween()
	for i in range(steps):
		var mag = strength * (1.0 - float(i) / steps)
		var off = Vector2(randf_range(-mag, mag), randf_range(-mag, mag))
		tw.tween_property(camera, "offset", off, step_t)
	tw.tween_property(camera, "offset", Vector2.ZERO, step_t)

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

	for row_name in ["Save", "Load"]:
		var hbox = HBoxContainer.new()
		var lbl = Label.new()
		lbl.text = row_name + " Layout:"
		hbox.add_child(lbl)
		for slot in range(1, 4):
			var b = Button.new()
			b.text = str(slot)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if row_name == "Save":
				b.pressed.connect(_save_layout.bind(slot))
			else:
				b.pressed.connect(_load_layout.bind(slot))
			hbox.add_child(b)
		vbox.add_child(hbox)

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

	var rules_btn = Button.new()
	rules_btn.text = "Rules ?"
	rules_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	rules_btn.offset_left = -160
	rules_btn.offset_right = -20
	rules_btn.offset_top = 65
	rules_btn.offset_bottom = 100
	rules_btn.pressed.connect(func(): rules_overlay.visible = not rules_overlay.visible)
	ui.add_child(rules_btn)

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

	var forces_title = Label.new()
	forces_title.text = "Forces Remaining (You / Foe)"
	forces_title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(forces_title)

	for type in GameManager.REQUIRED_PIECES.keys():
		var row = Label.new()
		row.add_theme_font_size_override("font_size", 16)
		vbox.add_child(row)
		forces_labels[type] = row
	vbox.add_child(HSeparator.new())

	var enemy_title = Label.new()
	enemy_title.text = "Enemy Losses"
	enemy_title.add_theme_font_size_override("font_size", 22)
	enemy_title.add_theme_color_override("font_color", Color.TOMATO)
	vbox.add_child(enemy_title)

	enemy_losses_list = VBoxContainer.new()
	var enemy_scroll = ScrollContainer.new()
	enemy_scroll.custom_minimum_size = Vector2(0, 150)
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
	player_scroll.custom_minimum_size = Vector2(0, 150)
	player_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	player_scroll.add_child(player_losses_list)
	vbox.add_child(player_scroll)

func _refresh_forces():
	for type in forces_labels.keys():
		var total = GameManager.REQUIRED_PIECES[type]
		var mine = total - captured_counts[GameManager.Team.PLAYER].get(type, 0)
		var foes = total - captured_counts[GameManager.Team.ENEMY].get(type, 0)
		forces_labels[type].text = "%2s %-10s %d / %d" % [_rank_display(type), type, mine, foes]

var _captures_seen: int = 0

func _record_capture(piece):
	var counts = captured_counts[piece.data.team]
	counts[piece.data.type] = counts.get(piece.data.type, 0) + 1
	# Ramp music intensity as losses mount (full swell by ~30 captures).
	_captures_seen += 1
	GameManager.set_music_intensity(_captures_seen / 30.0)
	_refresh_forces()
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

	combat_label = Label.new()
	combat_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	combat_label.offset_top = 90
	combat_label.offset_bottom = 150
	combat_label.offset_left = -600
	combat_label.offset_right = 600
	combat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combat_label.add_theme_font_size_override("font_size", 34)
	combat_label.add_theme_constant_override("outline_size", 10)
	combat_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	combat_label.modulate.a = 0.0
	combat_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(combat_label)

func _show_combat_result(attacker, defender, result: String):
	var outcome := ""
	match result:
		"attacker_wins": outcome = "attacker wins"
		"defender_wins": outcome = "defender wins"
		"draw": outcome = "both fall"
		"game_over": outcome = "Relic captured!"
	combat_label.text = "%s (%s) vs %s (%s) — %s" % [
		attacker.type, _rank_display(attacker.type),
		defender.type, _rank_display(defender.type), outcome]
	var tween = create_tween()
	tween.tween_property(combat_label, "modulate:a", 1.0, 0.15)
	tween.tween_interval(1.6)
	tween.tween_property(combat_label, "modulate:a", 0.0, 0.4)

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

func _build_history_panel():
	history_panel = PanelContainer.new()
	history_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	history_panel.offset_left = -320
	history_panel.offset_right = -20
	history_panel.offset_top = -420
	history_panel.offset_bottom = 420
	history_panel.visible = false
	ui.add_child(history_panel)

	var vbox = VBoxContainer.new()
	history_panel.add_child(vbox)
	var title = Label.new()
	title.text = "Move History"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	history_scroll = ScrollContainer.new()
	history_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(history_scroll)
	history_list = VBoxContainer.new()
	history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_scroll.add_child(history_list)

const RULES_LINES = [
	["10  Champion ×1", "Strongest — falls only to the Assassin's strike"],
	["9  Warlord ×1", ""],
	["8  Commander ×2", ""],
	["7  Captain ×3", ""],
	["6  Knight ×4", ""],
	["5  Guard ×4", ""],
	["4  Scout ×4", ""],
	["3  Rogue ×5", "The only piece that can disarm Wards"],
	["2  Runner ×8", "Moves any distance in a straight line"],
	["1  Assassin ×1", "Defeats the Champion — but only when attacking"],
	["W  Ward ×6", "Immobile — destroys any attacker except the Rogue"],
	["R  Relic ×1", "Immobile — capture the enemy's Relic to win"],
]

func _build_rules_overlay():
	rules_overlay = PanelContainer.new()
	rules_overlay.set_anchors_preset(Control.PRESET_CENTER)
	rules_overlay.offset_left = -420
	rules_overlay.offset_right = 420
	rules_overlay.offset_top = -400
	rules_overlay.offset_bottom = 400
	rules_overlay.visible = false
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.13, 0.97)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(24)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	rules_overlay.add_theme_stylebox_override("panel", sb)
	ui.add_child(rules_overlay)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	rules_overlay.add_child(vbox)

	var title = Label.new()
	title.text = "Ranks & Rules"
	title.add_theme_font_size_override("font_size", 30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	for line in RULES_LINES:
		var row = Label.new()
		row.text = line[0] + ("   — " + line[1] if line[1] != "" else "")
		row.add_theme_font_size_override("font_size", 18)
		vbox.add_child(row)

	vbox.add_child(HSeparator.new())
	var core = Label.new()
	core.text = "Move one tile up/down/left/right (Runner: any clear distance).\nNo piece may pass over another piece or cross the chasms.\nAttack by moving onto an adjacent enemy — you'll be asked to confirm.\nHigher rank wins, equal ranks both fall, and both pieces are revealed.\nYou can't shuttle between the same two tiles three moves running.\nIf you have no legal moves, you lose."
	core.add_theme_font_size_override("font_size", 16)
	core.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(core)

	var close = Button.new()
	close.text = "Close"
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(func(): rules_overlay.visible = false)
	vbox.add_child(close)

func _build_attack_confirm():
	# Full-rect dimmer that swallows clicks so the board is blocked while
	# the confirmation is up (works for both mouse and touch).
	attack_confirm_overlay = ColorRect.new()
	attack_confirm_overlay.color = Color(0, 0, 0, 0.35)
	attack_confirm_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	attack_confirm_overlay.visible = false
	ui.add_child(attack_confirm_overlay)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -230
	panel.offset_right = 230
	panel.offset_top = -120
	panel.offset_bottom = 120
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.13, 0.97)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(24)
	sb.border_color = Color(0.95, 0.35, 0.25)
	sb.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", sb)
	attack_confirm_overlay.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	attack_confirm_label = Label.new()
	attack_confirm_label.text = "Attack?"
	attack_confirm_label.add_theme_font_size_override("font_size", 32)
	attack_confirm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(attack_confirm_label)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 24)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var yes = Button.new()
	yes.text = "Yes"
	yes.custom_minimum_size = Vector2(150, 60)
	yes.add_theme_font_size_override("font_size", 26)
	yes.pressed.connect(_on_attack_confirmed)
	hbox.add_child(yes)

	var cancel = Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(150, 60)
	cancel.add_theme_font_size_override("font_size", 26)
	cancel.pressed.connect(_on_attack_canceled)
	hbox.add_child(cancel)

func _on_attack_confirmed():
	attack_confirm_overlay.visible = false
	if selected_piece and armed_attack.x >= 0 and armed_attack in valid_moves:
		_execute_move(selected_piece, armed_attack, true)
	else:
		armed_attack = Vector2i(-1, -1)
		queue_redraw()

func _on_attack_canceled():
	attack_confirm_overlay.visible = false
	armed_attack = Vector2i(-1, -1)
	queue_redraw()

func _coord(pos: Vector2i) -> String:
	return "%s%d" % [char(65 + pos.x), BOARD_SIZE - pos.y]

func _log_move(is_player: bool, from: Vector2i, to: Vector2i, attacker, defender, result: String):
	move_number += 1
	var who = "You" if is_player else "Enemy"
	var text = "%d. %s %s→%s" % [move_number, who, _coord(from), _coord(to)]
	if defender != null:
		var outcome = {"attacker_wins": "attacker wins", "defender_wins": "defender wins",
			"draw": "both fall", "game_over": "Relic captured!"}[result]
		text += "\n    %s(%s) × %s(%s) — %s" % [attacker.type, _rank_display(attacker.type),
			defender.type, _rank_display(defender.type), outcome]
	var entry = Label.new()
	entry.text = text
	entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	entry.custom_minimum_size = Vector2(270, 0)
	entry.add_theme_font_size_override("font_size", 14)
	entry.modulate = Color.CORNFLOWER_BLUE if is_player else Color.TOMATO
	history_list.add_child(entry)
	await get_tree().process_frame
	history_scroll.scroll_vertical = int(history_scroll.get_v_scroll_bar().max_value)

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
		var pulse01 = 0.5 + 0.5 * sin(_pulse_time * 5.0)
		var pulse = 0.55 + 0.25 * (pulse01 * 2.0 - 1.0)
		for pos in valid_moves:
			var center = _tile_center(pos)
			var rect = Rect2(pos.x * TILE_SIZE, pos.y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
			if _piece_at(pos) != null:
				# Attack target: glowing red tile + pulsing ring
				draw_rect(rect, Color(0.95, 0.25, 0.2, 0.10 + 0.10 * pulse01))
				draw_arc(center, 27.0, 0.0, TAU, 40, Color(0.95, 0.25, 0.2, pulse), 4.0)
			else:
				# Reachable tile: soft glow + marker dot
				draw_rect(rect, Color(0.95, 0.92, 0.55, 0.09 + 0.09 * pulse01))
				draw_circle(center, 13.0, Color(0.95, 0.92, 0.55, pulse))

		if armed_attack.x >= 0:
			# Crossed swords mark the attack awaiting confirmation
			var c = _tile_center(armed_attack)
			var s = 18.0
			draw_line(c + Vector2(-s, -s), c + Vector2(s, s), Color(1.0, 0.3, 0.2, 0.95), 6.0)
			draw_line(c + Vector2(-s, s), c + Vector2(s, -s), Color(1.0, 0.3, 0.2, 0.95), 6.0)

		if selected_piece:
			var pos = selected_piece.current_grid_pos
			# Pulse the selection outline so the active piece breathes.
			var inset = 3.0 + 2.0 * pulse01
			var rect = Rect2(pos.x * TILE_SIZE + inset, pos.y * TILE_SIZE + inset, TILE_SIZE - inset * 2.0, TILE_SIZE - inset * 2.0)
			draw_rect(rect, Color(1.0, 0.85, 0.2, 0.7 + 0.25 * pulse01), false, 4.0)

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

const LAYOUTS_PATH = "user://layouts.cfg"

func _save_layout(slot: int):
	var pieces = []
	for x in range(BOARD_SIZE):
		for y in range(6, BOARD_SIZE):
			var piece = _piece_at(Vector2i(x, y))
			if piece and piece.data.team == GameManager.Team.PLAYER:
				pieces.append({"type": piece.data.type, "x": x, "y": y})
	if pieces.size() != 40:
		current_turn_label.text = "Place all 40 pieces before saving"
		return
	var cfg = ConfigFile.new()
	cfg.load(LAYOUTS_PATH)  # ignore error: file may not exist yet
	cfg.set_value("slot_%d" % slot, "pieces", pieces)
	cfg.save(LAYOUTS_PATH)
	current_turn_label.text = "Layout saved to slot %d" % slot

func _load_layout(slot: int):
	var cfg = ConfigFile.new()
	if cfg.load(LAYOUTS_PATH) != OK:
		current_turn_label.text = "No saved layouts yet"
		return
	var pieces = cfg.get_value("slot_%d" % slot, "pieces", [])
	# Validate: exact required counts, all in bottom 4 rows, unique tiles.
	var counts = {}
	var seen = {}
	var valid = pieces.size() == 40
	for entry in pieces:
		var pos = Vector2i(entry["x"], entry["y"])
		if not _in_bounds(pos) or pos.y < 6 or seen.has(pos):
			valid = false
			break
		seen[pos] = true
		counts[entry["type"]] = counts.get(entry["type"], 0) + 1
	if valid:
		for type in GameManager.REQUIRED_PIECES.keys():
			if counts.get(type, 0) != GameManager.REQUIRED_PIECES[type]:
				valid = false
	if not valid:
		current_turn_label.text = "Slot %d is empty or invalid" % slot
		return
	for x in range(BOARD_SIZE):
		for y in range(6, BOARD_SIZE):
			var piece = _piece_at(Vector2i(x, y))
			if piece and piece.data.team == GameManager.Team.PLAYER:
				grid[x][y] = null
				piece.queue_free()
	for entry in pieces:
		_spawn_piece(GameManager.Team.PLAYER, entry["type"], Vector2i(entry["x"], entry["y"]))
	for type in pool_counts.keys():
		pool_counts[type] = 0
	_refresh_tray()
	queue_redraw()
	current_turn_label.text = "Layout %d loaded" % slot

func _on_start_battle_pressed():
	if GameManager.current_state != GameManager.GameState.SETUP:
		return
	deploy_panel.visible = false
	captured_panel.visible = true
	history_panel.visible = true
	GameManager.current_state = GameManager.GameState.PLAYER_TURN
	current_turn_label.text = "Your Turn"
	_show_banner("Battle Begins!", Color.GOLD)
	GameManager.play_sfx("battle_start")
	_refresh_forces()
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
		armed_attack = Vector2i(-1, -1)
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
			# Ask for confirmation before the attack lands (misclick/mistap guard).
			armed_attack = piece.current_grid_pos
			GameManager.play_sfx("select")
			queue_redraw()
			attack_confirm_label.text = "%s → %s\nAttack?" % [selected_piece.data.type, _coord(armed_attack)]
			attack_confirm_overlay.visible = true

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

	var banned = _banned_square(piece)
	if banned.x >= 0:
		moves.erase(banned)
	return moves

func _team_has_moves(team) -> bool:
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var piece = _piece_at(Vector2i(x, y))
			if piece and piece.data.team == team and _calculate_valid_moves(piece).size() > 0:
				return true
	return false

func _banned_square(piece) -> Vector2i:
	# Two-square rule: last move was the exact reverse of the one before it →
	# the piece may not immediately return to where it just came from.
	if piece.move_history.size() >= 2:
		var prev = piece.move_history[0]
		var last = piece.move_history[1]
		if last["from"] == prev["to"] and last["to"] == prev["from"]:
			return last["from"]
	return Vector2i(-1, -1)

func _execute_move(piece_to_move, target_pos: Vector2i, is_player: bool):
	GameManager.current_state = GameManager.GameState.ANIMATING

	var old_pos = piece_to_move.current_grid_pos
	var target_tile = _piece_at(target_pos)

	grid[old_pos.x][old_pos.y] = null
	last_move_from = old_pos
	last_move_to = target_pos
	piece_to_move.record_move(old_pos, target_pos)
	piece_to_move.data.has_moved = true

	selected_piece = null
	valid_moves.clear()
	armed_attack = Vector2i(-1, -1)
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
		bump_tween.tween_property(piece_to_move, "global_position", halfway_pos, GameManager.anim_time(0.2)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await bump_tween.finished

		# Reveal both ranks for a moment only; they hide again after the
		# flash, so players have to remember what they saw. The AI records
		# what it just learned in its own memory.
		target_tile.flash_reveal(COMBAT_REVEAL_TIME)
		piece_to_move.flash_reveal(COMBAT_REVEAL_TIME)
		ai.observe_combat(piece_to_move.data, target_tile.data)
		_show_combat_result(piece_to_move.data, target_tile.data, result)
		_log_move(is_player, old_pos, target_pos, piece_to_move.data, target_tile.data, result)

		await get_tree().create_timer(GameManager.anim_time(1.0)).timeout

		# Flash the losing piece(s) white and shake the board, then let them
		# explode. Gives the clash a beat of impact before the smoke.
		var losers = []
		if result == "attacker_wins" or result == "game_over":
			losers = [target_tile]
		elif result == "defender_wins":
			losers = [piece_to_move]
		elif result == "draw":
			losers = [target_tile, piece_to_move]
		for loser in losers:
			loser.hit_flash()
		_screen_shake(9.0, 0.22)
		await get_tree().create_timer(GameManager.anim_time(0.25)).timeout

		if result == "attacker_wins" or result == "game_over":
			_explode_at(target_tile)
			_record_capture(target_tile)
			target_tile.queue_free()

			var land_tween = create_tween()
			land_tween.tween_property(piece_to_move, "global_position", end_world_pos, GameManager.anim_time(0.15)).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
			await land_tween.finished

			grid[target_pos.x][target_pos.y] = piece_to_move
			piece_to_move.current_grid_pos = target_pos

		elif result == "defender_wins":
			_explode_at(piece_to_move)
			_record_capture(piece_to_move)
			piece_to_move.queue_free()

			# Little shake for the victorious defender
			var shake_tween = create_tween()
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(10, 0), GameManager.anim_time(0.05))
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(-10, 0), GameManager.anim_time(0.05))
			shake_tween.tween_property(target_tile.visuals, "position", Vector2(0, 0), GameManager.anim_time(0.05))
			await shake_tween.finished

		elif result == "draw":
			_explode_at(target_tile)
			_explode_at(piece_to_move)
			_record_capture(target_tile)
			_record_capture(piece_to_move)
			target_tile.queue_free()
			piece_to_move.queue_free()
			grid[target_pos.x][target_pos.y] = null
			await get_tree().create_timer(GameManager.anim_time(0.2)).timeout

		if is_instance_valid(piece_to_move):
			piece_to_move.z_index = 10

		if result == "game_over":
			GameManager.current_state = GameManager.GameState.GAME_OVER
			_show_victory_screen(is_player)
			return
	else:
		# Empty tile smooth slide
		GameManager.play_sfx("move")
		_log_move(is_player, old_pos, target_pos, null, null, "")
		var slide_tween = create_tween()
		slide_tween.tween_property(piece_to_move, "global_position", end_world_pos, GameManager.anim_time(0.3)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await slide_tween.finished

		grid[target_pos.x][target_pos.y] = piece_to_move
		piece_to_move.current_grid_pos = target_pos

	if is_instance_valid(piece_to_move):
		piece_to_move._update_visuals()
	queue_redraw()

	if GameManager.current_state != GameManager.GameState.GAME_OVER:
		if is_player:
			GameManager.current_state = GameManager.GameState.AI_TURN
			current_turn_label.text = "Enemy Turn"
			_show_banner("Enemy Turn", Color.TOMATO)
			_execute_ai_turn()
		else:
			if not _team_has_moves(GameManager.Team.PLAYER):
				# Player has no legal moves: loss by stalemate.
				GameManager.current_state = GameManager.GameState.GAME_OVER
				_show_victory_screen(false)
				return
			GameManager.current_state = GameManager.GameState.PLAYER_TURN
			current_turn_label.text = "Your Turn"
			_show_banner("Your Turn", Color.CORNFLOWER_BLUE)
			queue_redraw()

func _explode_at(piece):
	# Pitch the destruction cue by whose piece fell: a brighter ring when an
	# enemy dies, a darker one when you lose a piece — an outcome stinger with
	# no extra audio assets.
	var pitch = 1.12 if piece.data.team == GameManager.Team.ENEMY else 0.85
	GameManager.play_sfx("destroyed", pitch)
	var explosion = ExplosionScene.instantiate()
	explosion.global_position = piece.global_position
	explosion.color = Color.TOMATO if piece.data.team == GameManager.Team.ENEMY else Color.CORNFLOWER_BLUE
	add_child(explosion)

func _execute_ai_turn():
	await get_tree().create_timer(GameManager.anim_time(0.8)).timeout

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
	overlay.modulate.a = 0.0
	$CanvasLayer.add_child(overlay)
	create_tween().tween_property(overlay, "modulate:a", 1.0, 0.35)

	# Defeat: a bloody vignette closes in behind the message.
	if not player_won:
		var vignette = ColorRect.new()
		vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
		vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vignette.material = ShaderMaterial.new()
		vignette.material.shader = load("res://vignette.gdshader")
		vignette.modulate.a = 0.0
		overlay.add_child(vignette)
		create_tween().tween_property(vignette, "modulate:a", 1.0, 0.8)

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

	# Punch the banner in from oversized so the result lands with weight.
	_punch_banner(label)

	var again = Button.new()
	again.text = "Play Again"
	again.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	again.add_theme_font_size_override("font_size", 32)
	again.pressed.connect(func():
		GameManager.current_state = GameManager.GameState.SETUP
		get_tree().reload_current_scene())
	vbox.add_child(again)

	if player_won:
		var colors = [Color.RED, Color.GREEN, Color.CORNFLOWER_BLUE, Color.GOLD, Color.PURPLE, Color.ORANGE]
		# A central burst plus two flanking cannons for a fuller celebration.
		var origins = [Vector2(960, 540), Vector2(360, 760), Vector2(1560, 760)]
		for j in range(origins.size()):
			for i in range(colors.size()):
				var confetti = ExplosionScene.instantiate()
				confetti.global_position = origins[j]
				confetti.amount = 220
				confetti.lifetime = 2.8
				confetti.spread = 360
				confetti.initial_velocity_min = 300
				confetti.initial_velocity_max = 850
				confetti.scale_amount_min = 10
				confetti.scale_amount_max = 20
				confetti.color = colors[i]
				$CanvasLayer.add_child(confetti)

# Scale-punch a banner in from oversized, settling with a back-ease so the
# result lands with weight. Pivot is set after layout so it scales from center.
func _punch_banner(label: Label):
	await get_tree().process_frame
	if not is_instance_valid(label):
		return
	label.pivot_offset = label.size / 2.0
	label.scale = Vector2(1.7, 1.7)
	var tw = create_tween()
	tw.tween_property(label, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# ---------------------------------------------------------------- rules test
# `godot --headless --path . -- --rulestest` asserts the ruleset and quits
# with a non-zero exit code on any failure.
var _rt_failures: int = 0

func _rt_assert(cond: bool, name: String):
	if cond:
		print("[rulestest] PASS: ", name)
	else:
		_rt_failures += 1
		printerr("[rulestest] FAIL: ", name)

func _rt_finish():
	if _rt_failures == 0:
		print("[rulestest] ALL PASSED")
	else:
		printerr("[rulestest] %d FAILURES" % _rt_failures)
	get_tree().quit(0 if _rt_failures == 0 else 1)

func _debug_rules_test():
	var P = GameManager.Team.PLAYER
	var E = GameManager.Team.ENEMY
	var rc = func(a, d):
		return GameManager.resolve_combat(
			GameManager.create_piece_data(P, a), GameManager.create_piece_data(E, d))

	_rt_assert(rc.call("Assassin", "Champion") == "attacker_wins", "assassin beats champion attacking")
	_rt_assert(rc.call("Champion", "Assassin") == "attacker_wins", "champion beats assassin")
	_rt_assert(rc.call("Rogue", "Ward") == "attacker_wins", "rogue disarms ward")
	_rt_assert(rc.call("Champion", "Ward") == "defender_wins", "ward beats champion")
	_rt_assert(rc.call("Knight", "Relic") == "game_over", "relic capture ends game")
	_rt_assert(rc.call("Knight", "Knight") == "draw", "equal ranks draw")
	_rt_assert(rc.call("Guard", "Knight") == "defender_wins", "lower rank loses")
	_rt_assert(rc.call("Knight", "Guard") == "attacker_wins", "higher rank wins")
	_rt_assert(rc.call("Assassin", "Warlord") == "defender_wins", "assassin only beats champion")

	# AI memory: ranks seen in combat are remembered per difficulty.
	# Hard never forgets; easy rolls to forget each piece every turn.
	var seen = GameManager.create_piece_data(P, "Knight")
	var old_diff = GameManager.ai_difficulty
	GameManager.ai_difficulty = "hard"
	ai.observe_combat(seen, GameManager.create_piece_data(E, "Guard"))
	_rt_assert(ai.knows_rank(seen), "AI remembers player rank after combat")
	for i in range(50):
		ai._decay_memory()
	_rt_assert(ai.knows_rank(seen), "hard AI never forgets")
	GameManager.ai_difficulty = "easy"
	for i in range(200):
		ai._decay_memory()
	_rt_assert(not ai.knows_rank(seen), "easy AI eventually forgets")
	GameManager.ai_difficulty = old_diff

	# Two-square rule: after A→B, B→A the piece may not immediately return to B.
	var kn = _spawn_piece(GameManager.Team.PLAYER, "Knight", Vector2i(0, 6))
	kn.move_history = [
		{"from": Vector2i(0, 6), "to": Vector2i(0, 7)},
		{"from": Vector2i(0, 7), "to": Vector2i(0, 6)},
	]
	var kn_moves = _calculate_valid_moves(kn)
	_rt_assert(not Vector2i(0, 7) in kn_moves, "two-square rule bans third shuttle")
	_rt_assert(Vector2i(1, 6) in kn_moves, "two-square rule leaves other moves legal")
	# Non-oscillating history does not ban anything.
	grid[0][6] = null
	grid[0][7] = kn
	kn.current_grid_pos = Vector2i(0, 7)
	kn.move_history = [
		{"from": Vector2i(1, 6), "to": Vector2i(0, 6)},
		{"from": Vector2i(0, 6), "to": Vector2i(0, 7)},
	]
	_rt_assert(Vector2i(0, 6) in _calculate_valid_moves(kn), "non-oscillating history does not ban")

	# Piece clicks must actually be wired up (regression: signal was never connected).
	_rt_assert(kn.input_event.is_connected(kn._on_input_event), "piece click signal connected")

	# Movement blocking: no jumping over pieces, no crossing chasms,
	# and an adjacent enemy shows up as an attackable square.
	var rn = _spawn_piece(GameManager.Team.PLAYER, "Runner", Vector2i(0, 9))
	var rn_moves = _calculate_valid_moves(rn)
	_rt_assert(Vector2i(0, 8) in rn_moves, "runner reaches first clear tile")
	_rt_assert(not Vector2i(0, 7) in rn_moves, "runner blocked by own piece")
	_rt_assert(not Vector2i(0, 6) in rn_moves, "runner cannot jump over a piece")

	var rn2 = _spawn_piece(GameManager.Team.PLAYER, "Runner", Vector2i(2, 6))
	var rn2_moves = _calculate_valid_moves(rn2)
	_rt_assert(not Vector2i(2, 5) in rn2_moves, "chasm blocks movement")
	_rt_assert(not Vector2i(2, 4) in rn2_moves, "runner cannot cross the chasm")

	var sc = _spawn_piece(GameManager.Team.PLAYER, "Scout", Vector2i(5, 4))
	_rt_assert(Vector2i(5, 3) in _calculate_valid_moves(sc), "adjacent enemy is attackable")

	# Stalemate detection: only immobile pieces left = no moves. Clears the
	# board, so these assertions must stay last.
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var pc = _piece_at(Vector2i(x, y))
			if pc:
				grid[x][y] = null
				pc.queue_free()
	_spawn_piece(GameManager.Team.PLAYER, "Ward", Vector2i(0, 9))
	_spawn_piece(GameManager.Team.PLAYER, "Relic", Vector2i(1, 9))
	_rt_assert(not _team_has_moves(GameManager.Team.PLAYER), "immobile-only army has no moves")
	_spawn_piece(GameManager.Team.PLAYER, "Knight", Vector2i(5, 5))
	_rt_assert(_team_has_moves(GameManager.Team.PLAYER), "mobile piece restores moves")

	# Combat reveal is temporary: the rank flashes, then hides again.
	var fr = _spawn_piece(GameManager.Team.ENEMY, "Guard", Vector2i(8, 0))
	fr.flash_reveal(0.1)
	_rt_assert(fr.data.is_revealed, "combat flash shows the rank")
	await get_tree().create_timer(0.3).timeout
	_rt_assert(not fr.data.is_revealed, "combat flash hides the rank again")
	# A flash that starts during an earlier one extends the reveal.
	fr.flash_reveal(0.1)
	await get_tree().create_timer(0.05).timeout
	fr.flash_reveal(0.3)
	await get_tree().create_timer(0.15).timeout
	_rt_assert(fr.data.is_revealed, "overlapping flash keeps the rank shown")
	await get_tree().create_timer(0.3).timeout
	_rt_assert(not fr.data.is_revealed, "extended flash still hides in the end")

	# Legendary lookahead: it must not take the forward advance into a square
	# where a stronger player piece captures it next turn — the greedy tiers
	# walk right in for the progress bonus.
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var pc2 = _piece_at(Vector2i(x, y))
			if pc2:
				grid[x][y] = null
				pc2.queue_free()
	_spawn_piece(GameManager.Team.ENEMY, "Warlord", Vector2i(5, 4))
	_spawn_piece(GameManager.Team.PLAYER, "Champion", Vector2i(5, 6))
	var pre_diff = GameManager.ai_difficulty
	GameManager.ai_difficulty = "hard"
	var hard_move = ai.choose_move(self)
	_rt_assert(hard_move.get("target") == Vector2i(5, 5), "hard AI advances into the trap")
	GameManager.ai_difficulty = "legendary"
	var leg_move = ai.choose_move(self)
	_rt_assert(leg_move.get("target") != Vector2i(5, 5), "legendary AI avoids hanging its warlord")
	GameManager.ai_difficulty = pre_diff

	_rt_finish()
