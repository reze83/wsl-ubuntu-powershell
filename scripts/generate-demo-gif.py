#!/usr/bin/env python3
"""Generate a fake terminal demo GIF for the README.

Usage: uv run --with Pillow python3 scripts/generate-demo-gif.py
Output: docs/demo.gif
"""

from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# ── Layout ──────────────────────────────────────────────────────────────────
WIDTH = 920
PADDING = 22
LINE_HEIGHT = 22
FONT_SIZE = 16
TITLE_BAR_H = 36
CORNER_RADIUS = 10

# ── Catppuccin Mocha palette ───────────────────────────────────────────────
BG = (30, 30, 46)
SURFACE = (49, 50, 68)
TEXT = (205, 214, 244)
SUBTEXT = (147, 153, 178)
GREEN = (166, 227, 161)
CYAN = (137, 220, 235)
YELLOW = (249, 226, 175)
MAUVE = (203, 166, 247)
TITLE_DOTS = [(243, 139, 168), (249, 226, 175), (166, 227, 161)]

# ── Timing (ms) ────────────────────────────────────────────────────────────
TYPING_SPEED = 30
PAUSE_AFTER_CMD = 350
PAUSE_AFTER_GROUP = 700
PAUSE_END_SCENE = 2000
PAUSE_CLEAR = 500


def get_font(size: int = FONT_SIZE) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    ]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


FONT = get_font()

PROMPT = "c@ubuntu:~/wsl-ubuntu-powershell$ "

# ── Terminal content ───────────────────────────────────────────────────────

BANNER = [
    ("  _   _ _                 _          ____       _", CYAN),
    (" | | | | |__  _   _ _ __ | |_ _   _ / ___|  ___| |_ _   _ _ __", CYAN),
    (" | | | | '_ \\| | | | '_ \\| __| | | | \\___ \\ / _ \\ __| | | | '_ \\", CYAN),
    (" | |_| | |_) | |_| | | | | |_| |_| |  ___) |  __/ |_| |_| | |_) |", CYAN),
    ("  \\___/|_.__/ \\__,_|_| |_|\\__|\\__,_| |____/ \\___|\\__|\\__,_| .__/", CYAN),
    ("                                                           |_|", CYAN),
    ("", TEXT),
    ("  Mode: --full | Log: ~/.wsl-setup.log", SUBTEXT),
    ("  [DRY-RUN] Keine Aenderungen werden durchgefuehrt", YELLOW),
]

DRY_RUN_HEADER = [
    ("", TEXT),
    ("  >> Geplante Schritte (Dry-Run):", CYAN),
    ("", TEXT),
]

DRY_RUN_STEPS = [
    ("  Immer (--full):", TEXT),
    ("    1. System aktualisieren (apt-get update + full-upgrade)", TEXT),
    ("    2. Basis-Pakete installieren (curl, wget, git, ...)", TEXT),
    ("    3. Locale konfigurieren (en_US.UTF-8, de_DE.UTF-8)", TEXT),
    ("    4. /etc/wsl.conf (systemd=true, appendWindowsPath=false)", TEXT),
    ("    5. Kernel-Parameter optimieren (vm.swappiness=10)", TEXT),
    ("    6. Git konfigurieren (Delta-Pager, Windows GCM)", TEXT),
    ("    7. Shell optimieren (.bashrc)", TEXT),
    ("    8. Readline konfigurieren (~/.inputrc)", TEXT),
    ("    9. SSH einrichten (~/.ssh/config)", TEXT),
    ("", TEXT),
    ("  Full-Mode zusaetzlich:", TEXT),
    ("   10. CLI-Tools (ripgrep, fd, bat, fzf, tmux, delta)", GREEN),
    ("   11. eza (modernes ls)", GREEN),
    ("   12. zoxide (smarter cd)", GREEN),
    ("   13. gh (GitHub CLI)", GREEN),
    ("   14. Dev-Deps (gcc, clang, cmake, sqlite3, jq, ...)", GREEN),
    ("   15. Python 3 + uv", GREEN),
    ("   16. Node.js LTS (via nvm) + pnpm", GREEN),
    ("   17. pwsh, yq, lazygit", GREEN),
    ("   18. zsh + Oh-My-Zsh + Plugins", GREEN),
]

VALIDATE_HEADER = [
    ("  Ubuntu WSL2 Setup - Validierung", CYAN),
    ("  Modus: --full", SUBTEXT),
    ("", TEXT),
]

VALIDATE_CHECKS = [
    ("--- WSL-Umgebung", CYAN),
    ("  [PASS] WSL2-Umgebung erkannt", GREEN),
    ("  [PASS] sudo verfuegbar", GREEN),
    ("--- Basis-Pakete (14/14)", CYAN),
    ("  [PASS] curl, wget, git, build-essential, ...", GREEN),
    ("--- Locale & wsl.conf", CYAN),
    ("  [PASS] en_US.UTF-8 + de_DE.UTF-8", GREEN),
    ("  [PASS] systemd=true", GREEN),
    ("--- Git-Konfiguration", CYAN),
    ("  [PASS] delta als Pager konfiguriert", GREEN),
    ("  [PASS] Windows Credential Manager", GREEN),
    ("--- CLI-Tools", CYAN),
    ("  [PASS] ripgrep 14.1  | fd 10.2    | bat 0.25", GREEN),
    ("  [PASS] fzf 0.60      | eza 0.20   | zoxide 0.9", GREEN),
    ("  [PASS] delta 0.18    | lazygit    | yq | jq", GREEN),
    ("  [PASS] gh 2.71       | tmux 3.5a  | pwsh 7.5", GREEN),
    ("--- Python / Node.js", CYAN),
    ("  [PASS] python3 3.12 + uv 0.6", GREEN),
    ("  [PASS] node v22.14 + pnpm 10.6", GREEN),
    ("--- zsh + Oh-My-Zsh", CYAN),
    ("  [PASS] zsh ist Default-Shell", GREEN),
    ("  [PASS] autosuggestions + syntax-highlighting", GREEN),
]

VALIDATE_RESULT = [
    ("", TEXT),
    ("=" * 62, TEXT),
    ("  Validierungs-Ergebnis", TEXT),
    ("=" * 62, TEXT),
    ("", TEXT),
    ("  [PASS] 136 von 136 Checks bestanden", GREEN),
    ("", TEXT),
    ("=" * 62, TEXT),
]

# ── Scene definitions ──────────────────────────────────────────────────────
# Each scene: (command, [line_groups]) — screen is cleared between scenes
SCENES = [
    (
        "bash ubuntu-wsl-setup.sh --full --dry-run",
        [BANNER, DRY_RUN_HEADER, DRY_RUN_STEPS],
    ),
    (
        "bash ubuntu-wsl-validate.sh",
        [VALIDATE_HEADER, VALIDATE_CHECKS, VALIDATE_RESULT],
    ),
]


def draw_rounded_rect(draw: ImageDraw.Draw, xy: tuple, radius: int, fill: tuple):
    x0, y0, x1, y1 = xy
    draw.rectangle([x0 + radius, y0, x1 - radius, y1], fill=fill)
    draw.rectangle([x0, y0 + radius, x1, y1 - radius], fill=fill)
    draw.pieslice([x0, y0, x0 + 2 * radius, y0 + 2 * radius], 180, 270, fill=fill)
    draw.pieslice([x1 - 2 * radius, y0, x1, y0 + 2 * radius], 270, 360, fill=fill)
    draw.pieslice([x0, y1 - 2 * radius, x0 + 2 * radius, y1], 90, 180, fill=fill)
    draw.pieslice([x1 - 2 * radius, y1 - 2 * radius, x1, y1], 0, 90, fill=fill)


def render_frame(
    lines: list[tuple[str, tuple]],
    height: int,
    cursor_pos: tuple[int, int] | None = None,
) -> Image.Image:
    img = Image.new("RGBA", (WIDTH, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Window chrome
    draw_rounded_rect(draw, (0, 0, WIDTH - 1, height - 1), CORNER_RADIUS, BG)
    draw_rounded_rect(draw, (0, 0, WIDTH - 1, TITLE_BAR_H), CORNER_RADIUS, SURFACE)
    draw.rectangle([0, TITLE_BAR_H - CORNER_RADIUS, WIDTH - 1, TITLE_BAR_H], fill=SURFACE)

    # Traffic light dots
    for i, color in enumerate(TITLE_DOTS):
        cx = 20 + i * 24
        cy = TITLE_BAR_H // 2
        draw.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], fill=color)

    # Title text
    title = "ubuntu -- bash"
    bbox = draw.textbbox((0, 0), title, font=FONT)
    tw = bbox[2] - bbox[0]
    draw.text(((WIDTH - tw) // 2, (TITLE_BAR_H - FONT_SIZE) // 2), title, fill=SUBTEXT, font=FONT)

    # Content
    y = TITLE_BAR_H + 10
    for text, color in lines:
        if y + LINE_HEIGHT > height - 10:
            break
        draw.text((PADDING, y), text, fill=color, font=FONT)
        y += LINE_HEIGHT

    # Cursor block
    if cursor_pos:
        cx, cy_line = cursor_pos
        cy = TITLE_BAR_H + 10 + cy_line * LINE_HEIGHT
        draw.rectangle([PADDING + cx, cy + 2, PADDING + cx + 9, cy + LINE_HEIGHT - 2], fill=TEXT)

    return img


def cursor_x_for(text: str) -> int:
    bbox = FONT.getbbox(text)
    return bbox[2] - bbox[0]


def main():
    # Determine max scene height (largest scene drives window height)
    max_lines = 0
    for _, groups in SCENES:
        n = 1  # prompt
        for g in groups:
            n += len(g)
        max_lines = max(max_lines, n)

    height = TITLE_BAR_H + 20 + (max_lines + 2) * LINE_HEIGHT + 20

    frames: list[tuple[Image.Image, int]] = []

    for scene_idx, (cmd, groups) in enumerate(SCENES):
        lines: list[tuple[str, tuple]] = []

        # Show prompt with blinking cursor
        prompt_line = 0
        lines_with_prompt = [(PROMPT, YELLOW)]
        cx = cursor_x_for(PROMPT)
        frames.append((render_frame(lines_with_prompt, height, (cx, prompt_line)), 600))

        # Type command char by char
        typed = ""
        for ch in cmd:
            typed += ch
            cx = cursor_x_for(PROMPT + typed)
            speed = TYPING_SPEED + (8 if ch == " " else 0)
            frames.append((
                render_frame([(PROMPT + typed, YELLOW)], height, (cx, prompt_line)),
                speed,
            ))

        # Pause after command
        frames.append((
            render_frame([(PROMPT + cmd, YELLOW)], height, (cx, prompt_line)),
            PAUSE_AFTER_CMD,
        ))

        # Reveal output group by group
        all_lines: list[tuple[str, tuple]] = [(PROMPT + cmd, YELLOW)]
        for group in groups:
            all_lines.extend(group)
            frames.append((render_frame(all_lines, height), PAUSE_AFTER_GROUP))

        # End-of-scene pause
        frames.append((render_frame(all_lines, height), PAUSE_END_SCENE))

        # Clear screen between scenes (not after last)
        if scene_idx < len(SCENES) - 1:
            frames.append((render_frame([], height), PAUSE_CLEAR))

    # Final frame: prompt with cursor
    final_lines = list(all_lines) + [("", TEXT), (PROMPT, YELLOW)]
    prompt_idx = len(final_lines) - 1
    cx = cursor_x_for(PROMPT)
    frames.append((render_frame(final_lines, height, (cx, prompt_idx)), 3000))

    # Save GIF
    output_path = Path(__file__).resolve().parent.parent / "docs" / "demo.gif"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    images = [f[0].convert("RGB") for f in frames]
    durations = [f[1] for f in frames]

    images[0].save(
        output_path,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=True,
    )

    size_kb = output_path.stat().st_size // 1024
    total_s = sum(durations) / 1000
    print(f"Generated {output_path} ({size_kb}KB, {len(images)} frames, {total_s:.1f}s)")


if __name__ == "__main__":
    main()
