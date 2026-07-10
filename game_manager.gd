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

func _ready():
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)

	music_stream.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.stream = music_stream
	_music_player.bus = "Music"
	_music_player.volume_db = -10.0
	add_child(_music_player)

# Must only be called after a user interaction (browser autoplay rules).
func start_music():
	if not _music_player.playing:
		_music_player.play()

func play_sfx(sfx_name: String):
	var player = AudioStreamPlayer.new()
	player.stream = SFX[sfx_name]
	player.bus = "SFX"
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

func toggle_mute() -> bool:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
	return muted

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
