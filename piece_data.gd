class_name PieceData
extends Resource

enum Team { PLAYER, ENEMY, NONE }

@export var team: Team = Team.NONE
@export var type: String = "Unknown"
@export var rank: int = 0
@export var is_revealed: bool = false
@export var has_moved: bool = false
@export var texture: Texture2D
