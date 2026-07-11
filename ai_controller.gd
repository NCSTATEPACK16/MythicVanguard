extends RefCounted

# Heuristic AI. Plays fair: it only acts on ranks of player pieces whose
# is_revealed flag is set (revealed in a past combat, which is exactly the
# information a human opponent would remember).

# Returns {"piece": ..., "target": Vector2i} or {} if no move exists.
func choose_move(main) -> Dictionary:
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
	var hard = GameManager.ai_difficulty == "hard"
	var score = randf() * (0.15 if hard else 0.4)  # noise so play isn't deterministic

	var defender = main._piece_at(target)
	if defender:
		if defender.data.is_revealed:
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

	return score

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
