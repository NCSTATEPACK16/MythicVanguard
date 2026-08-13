#!/usr/bin/env python3
"""Composite LPC layer PNGs into Mythic Vanguard's per-rank/team character sheets."""

import argparse
import json
import re
import sys
from pathlib import Path

from PIL import Image

FRAME = 64
WALK_COLS, WALK_ROWS = 9, 4
IDLE_COLS = 2
ROWS = {"up": 0, "left": 1, "down": 2, "right": 3}
WALK_SHEET_SIZE = (FRAME * WALK_COLS, FRAME * WALK_ROWS)
IDLE_SHEET_SIZE = (FRAME * IDLE_COLS, FRAME * WALK_ROWS)
OUT_COLS = 1 + WALK_COLS  # idle frame (col 0) + 9 walk frames
FPS = 10

# Used only when a layer_N dict omits zPos (shouldn't happen with this generator's
# data, but the pipeline must fail loud rather than silently misorder a composite).
FALLBACK_ZPOS_ORDER = [
    "body", "head", "hair", "legs", "feet", "torso", "waist",
    "headwear", "weapon", "shield", "cape_base", "cape_trim", "cape",
]


class ComposeError(RuntimeError):
    pass


def load_json(path: Path) -> dict:
    if not path.exists():
        raise ComposeError(f"missing sheet definition: {path}")
    return json.loads(path.read_text())


def load_palette(lpc_root: Path, material: str, color_name: str) -> list[str]:
    meta = load_json(lpc_root / "palette_definitions" / material / f"meta_{material}.json")
    palette_file = lpc_root / "palette_definitions" / material / f"{material}_{meta['default']}.json"
    palette = load_json(palette_file)
    if color_name not in palette:
        raise ComposeError(f"color '{color_name}' not found in {palette_file}")
    return palette[color_name]


def material_base_color(lpc_root: Path, recolors: dict) -> str:
    if "base" in recolors:
        return recolors["base"]
    meta = load_json(lpc_root / "palette_definitions" / recolors["material"] / f"meta_{recolors['material']}.json")
    return meta["base"]


def build_recolor_map(lpc_root: Path, recolors: dict, target_color: str) -> dict:
    material = recolors["material"]
    base_hexes = load_palette(lpc_root, material, material_base_color(lpc_root, recolors))
    target_hexes = load_palette(lpc_root, material, target_color)
    if len(base_hexes) != len(target_hexes):
        raise ComposeError(f"palette length mismatch for material '{material}' (base vs '{target_color}')")

    def to_rgb(h: str) -> tuple[int, int, int]:
        h = h.lstrip("#")
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

    return {to_rgb(b): to_rgb(t) for b, t in zip(base_hexes, target_hexes)}


def apply_recolor(im: Image.Image, recolor_map: dict) -> Image.Image:
    """Nearest-color match against the base palette, not exact lookup -- some shipped
    LPC assets drift a few units off their documented palette hex (confirmed on
    cape/trim: one of its 6 shades is off by +3 in the green channel), so an exact
    dict lookup silently leaves those pixels unrecolored."""
    base_colors = list(recolor_map.keys())
    im = im.convert("RGBA")
    pixels = im.load()
    w, h = im.size
    cache: dict = {}
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            key = (r, g, b)
            new_rgb = cache.get(key)
            if new_rgb is None:
                nearest = min(base_colors, key=lambda c: (c[0] - r) ** 2 + (c[1] - g) ** 2 + (c[2] - b) ** 2)
                new_rgb = recolor_map[nearest]
                cache[key] = new_rgb
            pixels[x, y] = (*new_rgb, a)
    return im


def variant_filename(name: str) -> str:
    """Variant names in sheet_definitions JSON use spaces (e.g. 'kite blue blue');
    the actual PNG filenames on disk use underscores."""
    return name.replace(" ", "_")


def pick_default_variant(def_json: dict) -> str | None:
    """LPC's 'variants' list sometimes names colors (sash: blue/red/...) and sometimes
    names item sub-types with no color meaning at all (dagger: just 'dagger'). When no
    team color applies, prefer a variant matching the item's own type_name, else the
    first listed variant."""
    variants = def_json.get("variants", [])
    type_name = def_json.get("type_name")
    if type_name in variants:
        return type_name
    return variants[0] if variants else None


def load_layer_frames(lpc_root: Path, def_json: dict, prefix: str, color_name: str | None, forced_variant: str | None = None):
    """Returns (walk_image, idle_image_or_None) for one resolved sub-layer, recolored if requested."""
    base_dir = lpc_root / "spritesheets" / prefix
    flat_walk = base_dir / "walk.png"

    if flat_walk.exists():
        walk_variant = base_dir / "walk" / f"{variant_filename(color_name)}.png" if color_name else None
        if walk_variant is not None and walk_variant.exists():
            idle_variant = base_dir / "idle" / f"{variant_filename(color_name)}.png"
            idle_path = idle_variant if idle_variant.exists() else base_dir / "idle.png"
            return _open(walk_variant), _open_optional(idle_path)

        walk_img, idle_img = _open(flat_walk), _open_optional(base_dir / "idle.png")
        if color_name is not None:
            if "recolors" not in def_json:
                raise ComposeError(f"layer at {base_dir} has no matching color variant or 'recolors' -- cannot apply team color '{color_name}'")
            recolor_map = build_recolor_map(lpc_root, def_json["recolors"], color_name)
            walk_img = apply_recolor(walk_img, recolor_map)
            if idle_img is not None:
                idle_img = apply_recolor(idle_img, recolor_map)
        return walk_img, idle_img

    # No flat walk.png -- this layer only ships variant sub-files (walk/<name>.png).
    variant = None
    if color_name is not None and (base_dir / "walk" / f"{variant_filename(color_name)}.png").exists():
        variant = color_name
    elif forced_variant is not None:
        variant = forced_variant
    else:
        variant = pick_default_variant(def_json)
    if variant is None:
        raise ComposeError(f"{base_dir}: no flat walk.png and no resolvable variant in 'variants'")
    fname = variant_filename(variant)
    walk_path = base_dir / "walk" / f"{fname}.png"
    if not walk_path.exists():
        raise ComposeError(f"missing spritesheet frame: {walk_path}")
    idle_path = base_dir / "idle" / f"{fname}.png"
    if not idle_path.exists():
        idle_path = base_dir / "idle.png"
    return _open(walk_path), _open_optional(idle_path)


def _open(path: Path) -> Image.Image:
    if not path.exists():
        raise ComposeError(f"missing spritesheet frame: {path}")
    return Image.open(path).convert("RGBA")


def _open_optional(path: Path) -> Image.Image | None:
    """Not every layer ships idle art (e.g. some weapons only animate for thrust/slash) --
    absence there just means the item doesn't render in the standing pose, not an error."""
    return Image.open(path).convert("RGBA") if path.exists() else None


def zpos_of(layer_key: str, sub_layer_name: str, sub_layer: dict, warned: set) -> int:
    if "zPos" in sub_layer:
        return sub_layer["zPos"]
    fallback_index = FALLBACK_ZPOS_ORDER.index(layer_key) if layer_key in FALLBACK_ZPOS_ORDER else len(FALLBACK_ZPOS_ORDER)
    if layer_key not in warned:
        print(f"  WARNING: {sub_layer_name} has no zPos, falling back to default order position {fallback_index}", file=sys.stderr)
        warned.add(layer_key)
    return fallback_index * 1000


def composite_rank_team(lpc_root: Path, rank_cfg: dict, team: str, warned_zpos: set):
    body_variant = rank_cfg["body_variant"]
    accent = rank_cfg.get("team_accent")
    accent_layer = accent["layer"] if accent else None
    accent_color = None
    if accent:
        accent_color = accent["player_color"] if team == "player" else accent["enemy_color"]

    sub_layers = []  # (zpos, walk_img, idle_img)
    credits = []

    for layer_key, layer_cfg in rank_cfg["lpc_layers"].items():
        # A layer entry is either a plain "sheet_definitions/..." path, or
        # {"def": "...", "variant": "..."} to pin a specific non-color variant
        # (e.g. a shield's heraldry pattern) instead of the arbitrary first-listed one.
        if isinstance(layer_cfg, dict):
            def_relpath, forced_variant = layer_cfg["def"], layer_cfg.get("variant")
        else:
            def_relpath, forced_variant = layer_cfg, None

        def_path = lpc_root / "sheet_definitions" / def_relpath
        def_json = load_json(def_path)
        credits.extend(def_json.get("credits", []))
        color_name = accent_color if layer_key == accent_layer else None

        for sub_name, sub_layer in def_json.items():
            if not sub_name.startswith("layer"):
                continue
            if body_variant not in sub_layer:
                raise ComposeError(f"{def_path} sub-layer '{sub_name}' has no '{body_variant}' variant")
            prefix = sub_layer[body_variant]
            sub_base = lpc_root / "spritesheets" / prefix
            if not (sub_base / "walk.png").exists() and not (sub_base / "walk").exists():
                # Some sub-layers are attack-animation-only parts (e.g. a sword's
                # attack_slash/attack_thrust overlays) with no walk/idle art at all --
                # not applicable to a walk-cycle composite, not a missing-asset error.
                continue
            walk_img, idle_img = load_layer_frames(lpc_root, def_json, prefix, color_name, forced_variant)
            zpos = zpos_of(layer_key, f"{def_relpath}:{sub_name}", sub_layer, warned_zpos)
            sub_layers.append((zpos, walk_img, idle_img))

    sub_layers.sort(key=lambda t: t[0])

    walk_canvas = Image.new("RGBA", WALK_SHEET_SIZE, (0, 0, 0, 0))
    idle_canvas = Image.new("RGBA", IDLE_SHEET_SIZE, (0, 0, 0, 0))
    for _, walk_img, idle_img in sub_layers:
        walk_canvas.alpha_composite(walk_img)
        if idle_img is not None:
            idle_canvas.alpha_composite(idle_img)

    out = Image.new("RGBA", (FRAME * OUT_COLS, FRAME * WALK_ROWS), (0, 0, 0, 0))
    for row in range(WALK_ROWS):
        idle_frame = idle_canvas.crop((0, row * FRAME, FRAME, (row + 1) * FRAME))
        out.paste(idle_frame, (0, row * FRAME))
        for col in range(WALK_COLS):
            walk_frame = walk_canvas.crop((col * FRAME, row * FRAME, (col + 1) * FRAME, (row + 1) * FRAME))
            out.paste(walk_frame, ((1 + col) * FRAME, row * FRAME))

    return out, credits


def composite_static_prop(rank: str, rank_cfg: dict):
    src_path = rank_cfg.get("prop_source_path")
    if not src_path:
        print(f"  skipping {rank}: prop_source_path not set yet (see docs/asset-plan.md open decisions)")
        return None, None
    src = Path(src_path)
    if not src.exists():
        raise ComposeError(f"{rank}: prop_source_path does not exist: {src}")
    im = Image.open(src).convert("RGBA")
    im.thumbnail((FRAME, FRAME), Image.LANCZOS)
    out = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    out.paste(im, ((FRAME - im.width) // 2, (FRAME - im.height) // 2), im)
    credit = rank_cfg.get("prop_credit")
    return out, [credit] if credit and credit.get("author") else []


def dedupe_credits(credits: list[dict]) -> list[dict]:
    seen, result = set(), []
    for c in credits:
        key = json.dumps(c, sort_keys=True)
        if key not in seen:
            seen.add(key)
            result.append(c)
    return result


def format_credits_block(credits: list[dict], prop_credits: list[dict]) -> str:
    lines = [
        "<!-- LPC-CREDITS:BEGIN -->",
        "## Character Art (LPC)",
        "Character sprites composited by `tools/compose.py` from the "
        "[Universal LPC Spritesheet Character Generator](https://github.com/LiberatedPixelCup/Universal-LPC-Spritesheet-Character-Generator) "
        "layered assets (GPL-3.0 / CC-BY-SA 3.0 / CC0 / OGA-BY 3.0), aggregated from each layer's own credit metadata:",
        "",
    ]
    for c in sorted(credits, key=lambda c: c.get("file", "")):
        authors = ", ".join(c.get("authors", []))
        licenses = ", ".join(c.get("licenses", []))
        urls = " ".join(f"<{u}>" for u in c.get("urls", []))
        lines.append(f"- **{c.get('file', '?')}** — {authors} ({licenses}) {urls}".rstrip())
    if prop_credits:
        lines += ["", "## Static Props (Ward, Relic)"]
        for c in prop_credits:
            lines.append(f"- **{c.get('author', '?')}** ({c.get('license', '?')}) <{c.get('url', '')}>")
    lines.append("<!-- LPC-CREDITS:END -->")
    return "\n".join(lines) + "\n"


def update_credits_md(credits_path: Path, block: str):
    text = credits_path.read_text() if credits_path.exists() else ""
    pattern = re.compile(r"<!-- LPC-CREDITS:BEGIN -->.*?<!-- LPC-CREDITS:END -->\n?", re.DOTALL)
    if pattern.search(text):
        text = pattern.sub(block, text)
    else:
        if text and not text.endswith("\n\n"):
            text = text.rstrip("\n") + "\n\n"
        text += block
    credits_path.write_text(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lpc-root", required=True, type=Path)
    ap.add_argument("--roster", default=Path("tools/roster.json"), type=Path)
    ap.add_argument("--out-characters", default=Path("assets/characters"), type=Path)
    ap.add_argument("--out-props", default=Path("assets/props"), type=Path)
    ap.add_argument("--out-manifest", default=Path("assets/manifest.json"), type=Path)
    ap.add_argument("--credits", default=Path("CREDITS.md"), type=Path)
    ap.add_argument("--rank", action="append", help="Limit to this rank (repeatable). Default: all ranks.")
    args = ap.parse_args()

    lpc_root = args.lpc_root.expanduser().resolve()
    if not (lpc_root / "sheet_definitions").exists():
        raise ComposeError(f"--lpc-root does not look like an LPC generator checkout: {lpc_root}")

    roster = json.loads(args.roster.read_text())
    ranks = {k: v for k, v in roster.items() if not k.startswith("_")}
    if args.rank:
        missing = set(args.rank) - set(ranks)
        if missing:
            raise ComposeError(f"unknown rank(s) requested: {sorted(missing)}")
        ranks = {k: v for k, v in ranks.items() if k in args.rank}

    args.out_characters.mkdir(parents=True, exist_ok=True)
    args.out_props.mkdir(parents=True, exist_ok=True)

    manifest = {"frame_size": [FRAME, FRAME], "ranks": {}}
    all_credits: list[dict] = []
    warned_zpos: set = set()

    for rank, cfg in ranks.items():
        rank_lower = rank.lower()
        if cfg.get("source") == "static_prop":
            print(f"Compositing {rank} (static prop)...")
            img, prop_credits = composite_static_prop(rank, cfg)
            if img is None:
                continue
            out_path = args.out_props / f"{rank_lower}.png"
            img.save(out_path, optimize=True)
            manifest["ranks"][rank] = {
                "walkable": False,
                "shared": {
                    "sheet": f"res://assets/props/{rank_lower}.png",
                    "rows": {"down": 0}, "idle_col": 0, "walk_cols": [], "fps": 0,
                },
            }
            all_credits.extend(prop_credits)
            continue

        print(f"Compositing {rank} (player, enemy)...")
        entry = {"walkable": True}
        for team in ("player", "enemy"):
            img, credits = composite_rank_team(lpc_root, cfg, team, warned_zpos)
            out_path = args.out_characters / f"{rank_lower}_{team}.png"
            img.save(out_path, optimize=True)
            entry[team] = {
                "sheet": f"res://assets/characters/{rank_lower}_{team}.png",
                "rows": ROWS, "idle_col": 0, "walk_cols": list(range(1, 1 + WALK_COLS)), "fps": FPS,
            }
            all_credits.extend(credits)
        manifest["ranks"][rank] = entry

    args.out_manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    prop_credits = [c for r in ranks.values() if r.get("source") == "static_prop"
                    for c in [r.get("prop_credit")] if c and c.get("author")]
    block = format_credits_block(dedupe_credits(all_credits), dedupe_credits(prop_credits))
    update_credits_md(args.credits, block)

    print(f"\nWrote {len(manifest['ranks'])} rank(s) to {args.out_manifest}")
    print(f"CREDITS.md updated with {len(dedupe_credits(all_credits))} unique credit entries")


if __name__ == "__main__":
    try:
        main()
    except ComposeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
