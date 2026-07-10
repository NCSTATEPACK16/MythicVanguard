# LMM Handoff Document: Project "Mythic Vanguard" (v2)
**Objective:** An open-source, web-hostable (HTML5) hidden-information strategy board game mechanically inspired by Stratego, built in Godot 4.3 (GDScript).
**Theme:** A colorful, highly animated fantasy setting.
**Target Deployment:** Netlify (Godot Web Export).

This is version 2 of the handoff document. The original seven build phases are **complete** — see "Current State" below for the existing code inventory. The remaining work is defined in **Phases A–E**, written as sequential prompts. Always reuse the existing functions listed in the inventory rather than rebuilding them.

---

## 📋 Game Rules Reference
* **Board:** 10x10 grid with two 2x2 impassable "Chasms" (columns 2–3 and 6–7, rows 4–5 in zero-indexed grid coordinates).
* **Ranks & Pieces (40 per side):**
    * 10 — *Champion* (Marshal) — x1
    * 9 — *Warlord* (General) — x1
    * 8 — *Commander* (Colonel) — x2
    * 7 — *Captain* (Major) — x3
    * 6 — *Knight* (Captain) — x4
    * 5 — *Guard* (Lieutenant) — x4
    * 4 — *Scout* (Sergeant) — x4
    * 3 — *Rogue* (Miner) — x5 (disarms Wards)
    * 2 — *Runner* (Scout) — x8 (moves any distance in a straight line)
    * 1 — *Assassin* (Spy) — x1 (defeats Champion only when attacking)
    * W — *Ward* (Bomb) — x6 (immobile, defeats any attacker except Rogue)
    * R — *Relic* (Flag) — x1 (immobile, capturing it wins)

---

## ✅ Current State (Original Phases 1–7: COMPLETE)

Architecture: plain 2D nodes (`Node2D`/`Area2D`), logical state in a 2D array — **not** physics-driven. Visual grid is drawn in `main.gd::_draw()`; logical grid is `main.gd::grid[x][y]` holding `null`, the string `"CHASM"`, or a piece node reference.

| File | Contents |
|---|---|
| `project.godot` | Godot 4.3, GL Compatibility renderer, 1920x1080, `stretch/mode=canvas_items`, `GameManager` autoload |
| `game_manager.gd` | Autoload. `enum Team`, `enum GameState {SETUP, PLAYER_TURN, AI_TURN, ANIMATING, GAME_OVER}`, `REQUIRED_PIECES` counts, `resolve_combat(attacker, defender) -> String` (full Stratego ruleset incl. Rogue/Ward, Assassin/Champion, Relic capture) |
| `piece_data.gd` | `PieceData` Resource: `team`, `type`, `rank`, `is_revealed`, `texture` |
| `piece.gd` / `piece.tscn` | `Area2D` token with drag (setup) and click (play) input, `_update_visuals()` for hidden/revealed display, idle-breathe tween |
| `main.gd` / `main.tscn` | Board drawing, camera centering, player pool + AI random deployment, move calculation (`_calculate_valid_moves`, incl. Runner line movement), `_execute_move()` with combat tweens/reveals/explosions and turn alternation, `_execute_ai_turn()` (random AI), victory/defeat screen with confetti |
| `explosion.gd` / `explosion.tscn` | Self-freeing `CPUParticles2D` burst |
| `netlify.toml` | COOP/COEP headers for Godot 4 web export |

**Key reusable functions:** `GameManager.resolve_combat()`, `main.gd::_calculate_valid_moves()`, `main.gd::_execute_move()`, `main.gd::_generate_ai_setup()` (placement logic reusable for player auto-deploy).

**Known weaknesses this document's phases fix:** no art (pieces are gray squares with numbers); the setup pool overflows the visible viewport; the turn flow works but is invisible to the player; random AI; no audio; no title screen.

---

## 🛠️ Phase A: Foundations & Turn Clarity — ✅ COMPLETE
**Prompt for LMM:**
> "Fix the blockers that make the game feel broken, without adding art yet.
> 1. **Refactor:** Move the piece-rank table into `game_manager.gd` as `const RANKS = {\"Champion\": 10, ...}` and add `GameManager.create_piece_data(team, type) -> PieceData`. Delete the two duplicated if/elif rank chains in `main.gd`. Remove the duplicate `Team` enum from `piece_data.gd` — use `GameManager.Team` everywhere.
> 2. **Deploy tray:** Replace the free-floating piece pool with a side-panel tray (CanvasLayer UI): one row per piece type showing an icon/rank and a remaining-count badge. Click a tray row to arm it, then click any empty tile in the bottom 4 rows to place one. Placed pieces can still be dragged to rearrange. Add three buttons: **Auto-Deploy** (fills all remaining pieces using the same back-row-priority logic as `_generate_ai_setup`), **Randomize** (clears and re-deploys everything), and **Start Battle** (enabled only when all 40 are placed).
> 3. **Turn clarity:** Add an animated banner that slides in on every turn change ('Your Turn' / 'Enemy Turn'). Draw a persistent last-move marker outlining the from- and to-tiles of the most recent move (especially the AI's). Add a captured-pieces tray listing what each side has lost — AI pieces are revealed when captured.
> 4. **Project settings:** set `window/stretch/aspect = \"keep\"`."

## 🎨 Phase B: Visual Overhaul (Sprites, Board, Title) — ✅ COMPLETE
**Prompt for LMM:**
> "Give every piece real art and theme the board.
> 1. Source CC0/CC-BY icons (e.g. game-icons.net — CC BY 3.0, or a Kenney CC0 pack): one distinct icon per piece type (crown, sword, dagger, bomb, banner, etc.) plus a 'card back' icon for hidden enemy pieces. Store under `assets/pieces/` and add attribution in `CREDITS.md`.
> 2. Rework `piece.tscn` into a rounded token: team-colored base + border, centered icon `Sprite2D` (wired to the existing `PieceData.texture` export), small rank numeral in a corner. Hidden enemy pieces show the themed back. Update `piece.gd::_update_visuals()`.
> 3. Theme the board in `main.gd::_draw()`: tinted grass/stone checkering, chasms rendered darker with an animated shimmer (shader or particles). Valid-move highlights become soft pulsing markers instead of flat green fills.
> 4. Add `title.tscn` as the new main scene: logo, 'Play' button that loads `main.tscn`. (This click also satisfies the browser audio-unlock requirement used in Phase D.)"

## 🧠 Phase C: Smarter AI — ✅ COMPLETE
**Prompt for LMM:**
> "Replace the random AI with a fair heuristic AI in a new `ai_controller.gd`.
> 1. The AI may only use information a human would have: piece positions, plus ranks of *revealed* player pieces. Maintain a memory dictionary of player pieces revealed in combat.
> 2. Score every legal move: attack a revealed piece it beats (use `GameManager.resolve_combat` on known data) = high score; attacking a revealed stronger piece = heavy penalty; advancing toward the player's side = small bonus; Runners probing unknown pieces = moderate bonus; moving defenders away from its own Relic = penalty.
> 3. Add small random noise to scores so play isn't deterministic. Keep `await`-based pacing so the AI move animates visibly after the player's."

## 🔊 Phase D: Sound & Music — ✅ COMPLETE
**Prompt for LMM:**
> "Add audio, respecting browser autoplay rules.
> 1. Source CC0 audio (e.g. Kenney Interface/Impact packs): piece select, move slide, combat clash, piece destroyed, victory fanfare, defeat sting, and one looping ambient battle track. Store under `assets/audio/`, credit in `CREDITS.md`.
> 2. Create 'Music' and 'SFX' audio buses. Play music only after the title-screen 'Play' click — never in `_ready()`. Add a mute toggle to the HUD (mutes the Master bus via `AudioServer`)."

## 🚀 Phase E: Polish & Deploy — ✅ COMPLETE
**Prompt for LMM:**
> "Final polish and web deployment.
> 1. Add a 'Play Again' button to the victory/defeat overlay that resets `GameManager.current_state = SETUP` and reloads the scene.
> 2. Create `export_presets.cfg` with a Web preset (gl_compatibility is already set). Document the headless build command: `godot --headless --export-release Web build/index.html`.
> 3. Verify `netlify.toml` still serves COOP (`same-origin`) / COEP (`require-corp`) headers and that `build/` is the publish directory."

---

## 🧪 Dev Testing Flags
Run the game with user args (after `--`) for automated checks:
- `godot --path . -- --screenshot` — boots to the deploy screen, saves `user://screenshot.png`, quits.
- `--screenshot --autodeploy` — also auto-deploys and starts the battle first.
- `--screenshot --autodeploy --aitest` — plays 25 random player turns with AI responses, logging each move.
- `--screenshot --autodeploy --victory` — forces the victory screen (confetti + Play Again).
- `--screenshot-title` — screenshots the title screen instead.

## ⚙️ Architectural Guardrails (carried over from v1)
* **State vs. visuals:** the logical grid (`grid[x][y]`) is the source of truth; never read game state from pixel positions. When a piece is `queue_free()`d, always null its grid cell.
* **State machine:** block player input whenever `GameManager.current_state != PLAYER_TURN` (and setup input unless `SETUP`).
* **Async flow:** use `await tween.finished` / `await get_tree().create_timer(...).timeout` before handing the turn over; set state to `ANIMATING` during moves.
* **Tweens:** use Godot 4 `create_tween()` chaining; looping effects use `.set_loops()`, not `_process`.
* **Web:** Godot 4 web exports require Cross-Origin Isolation (COOP/COEP). No audio before the first user interaction.
