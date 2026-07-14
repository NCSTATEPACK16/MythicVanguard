extends Area2D
const PieceData = preload("res://piece_data.gd")

signal piece_dragged(piece)
signal piece_dropped(piece)
signal piece_clicked(piece)

var data: PieceData
var is_dragging: bool = false
var start_pos: Vector2
var current_grid_pos: Vector2i = Vector2i(-1, -1)

# Last two moves ({"from": Vector2i, "to": Vector2i}), newest last. Two-square rule.
var move_history: Array = []

func record_move(from: Vector2i, to: Vector2i):
	move_history.append({"from": from, "to": to})
	if move_history.size() > 2:
		move_history.pop_front()

const PLAYER_COLOR = Color(0.45, 0.62, 0.95)
const ENEMY_COLOR = Color(0.95, 0.45, 0.4)
const HIDDEN_COLOR = Color(0.32, 0.2, 0.26)
const ICON_DARK = Color(0.08, 0.08, 0.14)

@onready var token = $Visuals/Token
@onready var icon = $Visuals/Icon
@onready var rank_label = $Visuals/RankLabel
@onready var visuals = $Visuals

func _ready():
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	if data:
		_update_visuals()
	_start_idle_breathe()

func _interactable() -> bool:
	return GameManager.current_state == GameManager.GameState.SETUP or GameManager.current_state == GameManager.GameState.PLAYER_TURN

# Gentle pop on hover for tactile feedback. Scales the piece root so it does
# not fight the idle-breathe tween running on Visuals.
func _on_mouse_entered():
	if not _interactable() or is_dragging:
		return
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector2(1.09, 1.09), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _on_mouse_exited():
	if is_dragging:
		return
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _start_idle_breathe():
	# Small random delay so pieces don't all breathe perfectly in sync
	await get_tree().create_timer(randf_range(0.0, 1.0)).timeout
	if is_inside_tree():
		var tween = create_tween()
		tween.set_loops()
		tween.tween_property(visuals, "scale", Vector2(1.02, 1.02), 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(visuals, "scale", Vector2(1.0, 1.0), 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func initialize(piece_data: PieceData):
	data = piece_data
	if is_inside_tree():
		_update_visuals()

# Show the real rank for a moment (combat reveal), then hide it again so the
# opponent has to remember what they saw. Overlapping flashes extend the
# reveal instead of cutting it short.
var _reveal_gen: int = 0

func flash_reveal(duration: float):
	_reveal_gen += 1
	var gen = _reveal_gen
	data.is_revealed = true
	_update_visuals()
	await get_tree().create_timer(duration).timeout
	if _reveal_gen != gen:
		return
	data.is_revealed = false
	_update_visuals()

# Punch the token to pure white and fade it back — a hit flash for the moment
# a piece loses a combat. The token's stylebox bg is white, so self_modulate
# doubles as its color, and pushing it to white reads as an impact flash.
func hit_flash():
	var base = token.self_modulate
	token.self_modulate = Color(1, 1, 1, 1)
	var tw = create_tween()
	tw.tween_property(token, "self_modulate", base, GameManager.anim_time(0.3)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# Permanent-reveal variant: show the rank and keep it shown, cancelling any
# pending flash-hide.
func reveal_permanently():
	_reveal_gen += 1
	data.is_revealed = true
	_update_visuals()

func _update_visuals():
	if data.is_revealed or data.team == PieceData.Team.PLAYER:
		icon.texture = data.texture
		icon.self_modulate = ICON_DARK
		if data.type == "Ward":
			rank_label.text = "W"
		elif data.type == "Relic":
			rank_label.text = "R"
		else:
			rank_label.text = str(data.rank)
		rank_label.add_theme_color_override("font_color", ICON_DARK)
		token.self_modulate = PLAYER_COLOR if data.team == PieceData.Team.PLAYER else ENEMY_COLOR
	else:
		icon.texture = GameManager.BACK_ICON
		icon.self_modulate = Color(0.92, 0.78, 0.72)
		if data.has_moved:
			# This piece has moved, so it cannot be a Ward or the Relic.
			rank_label.text = "•"
			rank_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
		else:
			rank_label.text = ""
		token.self_modulate = HIDDEN_COLOR

func _process(_delta):
	if is_dragging:
		global_position = get_global_mouse_position()

func _on_input_event(_viewport, event, _shape_idx):
	if GameManager.current_state != GameManager.GameState.SETUP and GameManager.current_state != GameManager.GameState.PLAYER_TURN:
		return

	# Only react to the press here. Touch is delivered as an emulated mouse
	# button (project setting emulate_mouse_from_touch), so handling mouse
	# alone covers finger taps too — reacting to the raw touch event as well
	# would double-fire and cancel the play-phase selection toggle. The
	# release is handled globally in _input() so it still fires when the
	# finger/cursor lifts just off the token after a fast drag.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if GameManager.current_state == GameManager.GameState.SETUP:
			if data.team == PieceData.Team.PLAYER:
				start_drag()
		elif GameManager.current_state == GameManager.GameState.PLAYER_TURN:
			piece_clicked.emit(self)

# Release can land off the token on a fast drag, so watch globally. end_drag()
# is idempotent, so it's harmless if the on-token release also fires.
func _input(event):
	if not is_dragging:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		end_drag()
	elif event is InputEventScreenTouch and not event.pressed:
		end_drag()

func start_drag():
	is_dragging = true
	start_pos = global_position
	z_index = 100
	piece_dragged.emit(self)

func end_drag():
	if not is_dragging:
		return
	is_dragging = false
	z_index = 10
	stop_jiggle()
	piece_dropped.emit(self)

# iOS-home-screen wobble: a small looping rotation, layered over the idle
# breathe (which tweens Visuals' scale) so the two don't fight. Used to signal
# "let go here and we'll swap" while another piece hovers over this one.
var _jiggle_tween: Tween

func start_jiggle():
	if _jiggle_tween and _jiggle_tween.is_valid():
		return
	_jiggle_tween = create_tween().set_loops()
	_jiggle_tween.tween_property(self, "rotation_degrees", 4.0, 0.09).set_trans(Tween.TRANS_SINE)
	_jiggle_tween.tween_property(self, "rotation_degrees", -4.0, 0.18).set_trans(Tween.TRANS_SINE)
	_jiggle_tween.tween_property(self, "rotation_degrees", 0.0, 0.09).set_trans(Tween.TRANS_SINE)

func stop_jiggle():
	if _jiggle_tween and _jiggle_tween.is_valid():
		_jiggle_tween.kill()
	_jiggle_tween = null
	rotation_degrees = 0.0

# Quick one-off shake for the piece that gets displaced by a swap, as it slides
# to its new home. Cancels any hover jiggle first so they don't overlap.
func settle_shake():
	stop_jiggle()
	var tw = create_tween()
	tw.tween_property(self, "rotation_degrees", 7.0, 0.05).set_trans(Tween.TRANS_SINE)
	tw.tween_property(self, "rotation_degrees", -5.0, 0.07).set_trans(Tween.TRANS_SINE)
	tw.tween_property(self, "rotation_degrees", 3.0, 0.06).set_trans(Tween.TRANS_SINE)
	tw.tween_property(self, "rotation_degrees", 0.0, 0.05).set_trans(Tween.TRANS_SINE)
