extends RefCounted

# Heuristic AI. Plays fair: it only acts on ranks of player pieces it has
# seen in a past combat, held in its own memory rather than the visual
# is_revealed flag (which now only flashes briefly). Hard AI never forgets;
# easy AI rolls to forget each remembered piece every turn, so it may well
# probe a piece that already beat it.

const EASY_FORGET_CHANCE = 0.25

# Player PieceData instance ids whose rank the AI has seen in combat.
var _known_ranks := {}

func observe_combat(attacker_data, defender_data) -> void:
	for data in [attacker_data, defender_data]:
		if data.team == GameManager.Team.PLAYER:
			_known_ranks[data.get_instance_id()] = true

func knows_rank(data) -> bool:
	return _known_ranks.has(data.get_instance_id())

func _decay_memory() -> void:
	# Only easy AI forgets; hard and legendary keep perfect memory.
	if GameManager.ai_difficulty != "easy":
		return
	for key in _known_ranks.keys():
		if randf() < EASY_FORGET_CHANCE:
			_known_ranks.erase(key)

# Returns {"piece": ..., "target": Vector2i} or {} if no move exists.
func choose_move(main) -> Dictionary:
	_decay_memory()
	var relic_pos = _find_own_relic(main)
	var best = {}
	var best_score = -INF

	for x in range(main.BOARD_SIZE):
		for y in range(main.BOARD_SIZE):
			var piece = main._piece_at(Vector2i(x, y))
			if piece == null or piece.data.team != GameManager.Team.ENEMY:
				continue
			if piece.data.type == "Ward" or piece.data.type == "Relic":
				continue
			for target in main._calculate_valid_moves(piece):
				var score = _score_move(main, piece, target, relic_pos)
				if score > best_score:
					best_score = score
					best = {"piece": piece, "target": target}
	return best

func _score_move(main, piece, target: Vector2i, relic_pos: Vector2i) -> float:
	# Legendary shares hard's sharper heuristics, then adds 1-ply lookahead.
	var hard = GameManager.ai_difficulty != "easy"
	var score = randf() * (0.15 if hard else 0.4)  # noise so play isn't deterministic

	var defender = main._piece_at(target)
	if defender:
		if knows_rank(defender.data):
			match GameManager.resolve_combat(piece.data, defender.data):
				"game_over":
					score += 1000.0
				"attacker_wins":
					score += (12.0 if hard else 8.0) + _piece_value(defender.data)
				"defender_wins":
					score -= 10.0
				"draw":
					score += _piece_value(defender.data) - _piece_value(piece.data)
		else:
			# Unknown defender: probe with expendable pieces, never with leaders.
			# On hard, use the public has_moved fact: a piece that has moved can
			# never be a Ward or the Relic, so probing it risks less.
			var could_be_ward = not defender.data.has_moved
			if piece.data.type == "Runner":
				score += 2.0
			elif piece.data.type == "Assassin":
				score -= 4.0
			elif piece.data.type == "Rogue" and hard and could_be_ward:
				score += 1.6  # Rogues are exactly who should test suspected Wards
			elif piece.data.rank <= 4:
				score += 0.8
			elif piece.data.rank >= 8:
				if hard and not could_be_ward:
					score -= 1.0  # no Ward risk; a leader may bully a mover
				else:
					score -= 5.0 if hard else 3.0
	else:
		# Advance toward the player's side of the board
		if target.y > piece.current_grid_pos.y:
			score += 0.7
		elif target.y < piece.current_grid_pos.y:
			score -= 0.35
		if piece.data.type == "Runner":
			score += 0.2

	# Don't pull a bodyguard away from our Relic
	if relic_pos.x >= 0:
		if _adjacent(piece.current_grid_pos, relic_pos) and not _adjacent(target, relic_pos):
			score -= 6.0 if hard else 3.0

	# Legendary: 1-ply lookahead. Subtract the best capture the player could
	# make against us right after this move, so it avoids hanging pieces and
	# exposing the Relic in a way the greedy tiers cannot see.
	if GameManager.ai_difficulty == "legendary":
		score -= _retaliation_penalty(main, piece, target)

	return score

# Value of the player's best reply if we commit `piece` to `target`. Uses a
# reversible edit of main.grid (movegen and resolve_combat are read-only), so
# no visual state is touched. Only evaluated for moves where we actually end
# up occupying the target (empty tile or a capture we know we win).
func _retaliation_penalty(main, piece, target: Vector2i) -> float:
	var defender = main._piece_at(target)
	var will_occupy = defender == null
	if defender != null and knows_rank(defender.data):
		var r = GameManager.resolve_combat(piece.data, defender.data)
		will_occupy = r == "attacker_wins" or r == "game_over"
	if not will_occupy:
		return 0.0

	var from = piece.current_grid_pos
	var prev_target_cell = main.grid[target.x][target.y]
	main.grid[from.x][from.y] = null
	main.grid[target.x][target.y] = piece
	piece.current_grid_pos = target

	var gain = _best_player_capture_value(main)

	# Restore exactly.
	piece.current_grid_pos = from
	main.grid[from.x][from.y] = piece
	main.grid[target.x][target.y] = prev_target_cell
	return gain

# Assumes a full-information player (standard minimax pessimism): the largest
# value the player could take from us on their immediate next move.
func _best_player_capture_value(main) -> float:
	var best = 0.0
	for x in range(main.BOARD_SIZE):
		for y in range(main.BOARD_SIZE):
			var p = main._piece_at(Vector2i(x, y))
			if p == null or p.data.team != GameManager.Team.PLAYER:
				continue
			if p.data.type == "Ward" or p.data.type == "Relic":
				continue
			for t in main._calculate_valid_moves(p):
				var d = main._piece_at(t)
				if d == null or d.data.team != GameManager.Team.ENEMY:
					continue
				var v = 0.0
				match GameManager.resolve_combat(p.data, d.data):
					"game_over":
						v = 1000.0  # player reaching our Relic — never allow it
					"attacker_wins":
						v = _piece_value(d.data)
					"draw":
						v = _piece_value(d.data) - _piece_value(p.data)
				if v > best:
					best = v
	return best

func _piece_value(data) -> float:
	if data.type == "Assassin":
		return 7.0  # worth far more than its rank: it kills the Champion
	return float(data.rank)

func _find_own_relic(main) -> Vector2i:
	for x in range(main.BOARD_SIZE):
		for y in range(main.BOARD_SIZE):
			var piece = main._piece_at(Vector2i(x, y))
			if piece and piece.data.team == GameManager.Team.ENEMY and piece.data.type == "Relic":
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _adjacent(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1
