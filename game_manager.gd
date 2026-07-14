extends Node
const PieceData = preload("res://piece_data.gd")

# Single source of truth for teams lives in PieceData; aliased here so
# existing GameManager.Team call sites keep working.
const Team = PieceData.Team

enum GameState { SETUP, PLAYER_TURN, AI_TURN, ANIMATING, GAME_OVER }

var current_state: GameState = GameState.SETUP

const SFX = {
	"select": preload("res://assets/audio/select.ogg"),
	"move": preload("res://assets/audio/move.ogg"),
	"deploy": preload("res://assets/audio/deploy.ogg"),
	"clash": preload("res://assets/audio/clash.ogg"),
	"destroyed": preload("res://assets/audio/destroyed.ogg"),
	"battle_start": preload("res://assets/audio/battle_start.ogg"),
	"victory": preload("res://assets/audio/victory.ogg"),
	"defeat": preload("res://assets/audio/defeat.ogg")
}
var music_stream: AudioStreamMP3 = preload("res://assets/audio/music.mp3")

var muted: bool = false
var _music_player: AudioStreamPlayer

const SETTINGS_PATH = "user://layouts.cfg"
var ai_difficulty: String = "easy"
var fast_anim: bool = false

func anim_time(t: float) -> float:
	return t * 0.5 if fast_anim else t

func save_settings():
	var cfg = ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # ignore error: file may not exist yet
	cfg.set_value("options", "ai_difficulty", ai_difficulty)
	cfg.set_value("options", "fast_anim", fast_anim)
	cfg.set_value("options", "muted", muted)
	cfg.set_value("options", "match_mode", match_mode)
	cfg.set_value("options", "puzzle_index", puzzle_index)
	cfg.set_value("options", "variant_permanent_reveal", variant_permanent_reveal)
	cfg.set_value("options", "variant_assassin_any", variant_assassin_any)
	cfg.save(SETTINGS_PATH)

func _load_settings():
	var cfg = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		ai_difficulty = cfg.get_value("options", "ai_difficulty", "easy")
		fast_anim = cfg.get_value("options", "fast_anim", false)
		muted = cfg.get_value("options", "muted", false)
		match_mode = cfg.get_value("options", "match_mode", "classic")
		puzzle_index = cfg.get_value("options", "puzzle_index", 0)
		variant_permanent_reveal = cfg.get_value("options", "variant_permanent_reveal", false)
		variant_assassin_any = cfg.get_value("options", "variant_assassin_any", false)

func _ready():
	_load_settings()
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)

	music_stream.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.stream = music_stream
	_music_player.bus = "Music"
	_music_player.volume_db = -12.0
	add_child(_music_player)
	_apply_mute()

# Must only be called after a user interaction (browser autoplay rules).
func start_music():
	if not _music_player.playing:
		_music_player.play()

func play_sfx(sfx_name: String, pitch: float = 1.0):
	var player = AudioStreamPlayer.new()
	player.stream = SFX[sfx_name]
	player.bus = "SFX"
	player.pitch_scale = pitch
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

# Swell the music louder as the battle thins out. `frac` is 0 (full boards)
# to 1 (many losses); the volume eases up so late-game feels more intense.
func set_music_intensity(frac: float):
	if _music_player == null:
		return
	frac = clampf(frac, 0.0, 1.0)
	var target_db = lerpf(-12.0, -3.0, frac)
	create_tween().tween_property(_music_player, "volume_db", target_db, 0.8)

func toggle_mute() -> bool:
	muted = not muted
	_apply_mute()
	save_settings()
	return muted

func _apply_mute():
	for i in range(AudioServer.bus_count):
		AudioServer.set_bus_mute(i, muted)

const RANKS = {
	"Champion": 10,
	"Warlord": 9,
	"Commander": 8,
	"Captain": 7,
	"Knight": 6,
	"Guard": 5,
	"Scout": 4,
	"Rogue": 3,
	"Runner": 2,
	"Assassin": 1,
	"Ward": 11,
	"Relic": 0
}

const REQUIRED_PIECES = {
	"Relic": 1,
	"Ward": 6,
	"Champion": 1,
	"Warlord": 1,
	"Commander": 2,
	"Captain": 3,
	"Knight": 4,
	"Guard": 4,
	"Scout": 4,
	"Rogue": 5,
	"Runner": 8,
	"Assassin": 1
}

# Reduced roster for the faster Blitz variant (8x8 board, 3 deploy rows).
const BLITZ_PIECES = {
	"Relic": 1,
	"Ward": 3,
	"Champion": 1,
	"Warlord": 1,
	"Commander": 1,
	"Captain": 1,
	"Knight": 2,
	"Guard": 2,
	"Scout": 2,
	"Rogue": 2,
	"Runner": 4,
	"Assassin": 1
}

# Which match variant to set up. Persisted with the other options.
var match_mode: String = "classic"

# Which puzzle is selected when match_mode == "puzzle".
var puzzle_index: int = 0

# Tactical scenarios: a fixed position with a goal of "capture the enemy Relic
# within `moves` player turns". These are all mate-in-1 finishers — the player
# must spot the single winning move. Pieces are placed exactly; enemy ranks are
# shown (full-information tactics). Coordinates: y=0 is the far/enemy edge.
const PUZZLES = [
	{
		"name": "The Long Shot",
		"board_size": 6,
		"moves": 1,
		"pieces": [
			{"team": "enemy", "type": "Relic", "x": 2, "y": 0},
			{"team": "enemy", "type": "Ward", "x": 1, "y": 0},
			{"team": "enemy", "type": "Ward", "x": 3, "y": 0},
			{"team": "enemy", "type": "Champion", "x": 5, "y": 0},
			{"team": "player", "type": "Runner", "x": 2, "y": 5},
			{"team": "player", "type": "Guard", "x": 0, "y": 5},
			{"team": "player", "type": "Knight", "x": 4, "y": 5},
		],
	},
	{
		"name": "Down the Line",
		"board_size": 6,
		"moves": 1,
		"pieces": [
			{"team": "enemy", "type": "Relic", "x": 0, "y": 0},
			{"team": "enemy", "type": "Warlord", "x": 0, "y": 1},
			{"team": "enemy", "type": "Champion", "x": 2, "y": 2},
			{"team": "player", "type": "Runner", "x": 5, "y": 0},
			{"team": "player", "type": "Captain", "x": 3, "y": 5},
		],
	},
	{
		"name": "Decisive Step",
		"board_size": 6,
		"moves": 1,
		"pieces": [
			{"team": "enemy", "type": "Relic", "x": 2, "y": 0},
			{"team": "enemy", "type": "Champion", "x": 1, "y": 1},
			{"team": "enemy", "type": "Warlord", "x": 3, "y": 1},
			{"team": "player", "type": "Knight", "x": 2, "y": 1},
			{"team": "player", "type": "Guard", "x": 4, "y": 3},
		],
	},
]

func current_puzzle() -> Dictionary:
	return PUZZLES[clampi(puzzle_index, 0, PUZZLES.size() - 1)]

# Optional rule variants, selectable before a match and persisted.
# permanent_reveal: a piece's rank stays visible forever once seen in combat
#   (instead of the default temporary flash).
# assassin_any: the Assassin defeats ANY piece it attacks, not just the Champion.
var variant_permanent_reveal: bool = false
var variant_assassin_any: bool = false

# Full board/roster/rules description for a match. main.gd reads this at
# startup instead of the old board-size and roster constants, so variants
# (Classic, Blitz, and later puzzles) are just different configs.
func get_match_config() -> Dictionary:
	if match_mode == "puzzle":
		var pz = current_puzzle()
		return {
			"board_size": pz["board_size"],
			"deploy_rows": 0,  # puzzles place pieces directly, no deploy phase
			"pieces": REQUIRED_PIECES.duplicate(),  # full key set for UI labels
			"chasms": pz.get("chasms", []),
			"two_square_rule": true,
			"permanent_reveal": true,  # tactics are full-information
		}
	if match_mode == "blitz":
		return {
			"board_size": 8,
			"deploy_rows": 3,
			"pieces": BLITZ_PIECES.duplicate(),
			"chasms": [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)],
			"two_square_rule": false,
			"permanent_reveal": variant_permanent_reveal,
		}
	# Classic (default)
	var chasms = []
	for cx in [2, 3, 6, 7]:
		for cy in [4, 5]:
			chasms.append(Vector2i(cx, cy))
	return {
		"board_size": 10,
		"deploy_rows": 4,
		"pieces": REQUIRED_PIECES.duplicate(),
		"chasms": chasms,
		"two_square_rule": true,
		"permanent_reveal": variant_permanent_reveal,
	}

const PIECE_ICONS = {
	"Champion": preload("res://assets/pieces/champion.svg"),
	"Warlord": preload("res://assets/pieces/warlord.svg"),
	"Commander": preload("res://assets/pieces/commander.svg"),
	"Captain": preload("res://assets/pieces/captain.svg"),
	"Knight": preload("res://assets/pieces/knight.svg"),
	"Guard": preload("res://assets/pieces/guard.svg"),
	"Scout": preload("res://assets/pieces/scout.svg"),
	"Rogue": preload("res://assets/pieces/rogue.svg"),
	"Runner": preload("res://assets/pieces/runner.svg"),
	"Assassin": preload("res://assets/pieces/assassin.svg"),
	"Ward": preload("res://assets/pieces/ward.svg"),
	"Relic": preload("res://assets/pieces/relic.svg")
}
const BACK_ICON = preload("res://assets/pieces/back.svg")

func create_piece_data(team: Team, type: String) -> PieceData:
	var data = PieceData.new()
	data.team = team
	data.type = type
	data.rank = RANKS[type]
	data.is_revealed = (team == Team.PLAYER)
	data.texture = PIECE_ICONS[type]
	return data

# Resolve combat between two pieces.
# Returns: "attacker_wins", "defender_wins", "draw", or "game_over"
func resolve_combat(attacker: PieceData, defender: PieceData) -> String:
	# Capturing the Relic ends the game immediately
	if defender.type == "Relic":
		return "game_over"

	# Variant: the Assassin is deadly to anything it attacks.
	if variant_assassin_any and attacker.type == "Assassin":
		return "attacker_wins"

	# Wards defeat everything except Rogues
	if defender.type == "Ward":
		if attacker.type == "Rogue":
			return "attacker_wins"
		else:
			return "defender_wins"

	# The Assassin defeats the Champion ONLY if attacking
	if defender.type == "Champion" and attacker.type == "Assassin":
		return "attacker_wins"

	# Default resolution based on rank
	if attacker.rank > defender.rank:
		return "attacker_wins"
	elif attacker.rank < defender.rank:
		return "defender_wins"
	else:
		return "draw"
