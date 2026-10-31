#!/usr/bin/env python3
"""Set a custom accent color in a self-contained Fcitx5 wallpaper theme."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

TEXT_LIGHT = (252, 252, 252)
TEXT_DARK = (0, 0, 0)
MIN_CONTRAST = 4.5
PANEL_COLOR = (0, 0, 0)
PANEL_OPACITY = 0.20
BORDER_ALPHA = "CC"


class ColorError(RuntimeError):
    """A user-facing input or theme error."""


@dataclass(frozen=True)
class Palette:
    accent: str
    panel_color: str
    panel_opacity: float
    border: str
    text: str
    highlight_text: str


def parse_color(value: str) -> tuple[int, int, int]:
    value = value.strip()
    if value.startswith("#"):
        digits = value[1:]
        if len(digits) not in (6, 8):
            raise ColorError(f"不支持的十六进制颜色：{value}")
        try:
            return tuple(int(digits[index : index + 2], 16) for index in (0, 2, 4))
        except ValueError as error:
            raise ColorError(f"无效的十六进制颜色：{value}") from error

    parts = [part.strip() for part in value.split(",")]
    if len(parts) != 3:
        raise ColorError(f"不支持的颜色：{value}")
    try:
        channels = tuple(int(part) for part in parts)
    except ValueError as error:
        raise ColorError(f"无效的 RGB 颜色：{value}") from error
    if any(channel < 0 or channel > 255 for channel in channels):
        raise ColorError(f"RGB 通道超出范围：{value}")
    return channels


def color_hex(color: tuple[int, int, int]) -> str:
    return "#" + "".join(f"{max(0, min(255, channel)):02X}" for channel in color)


def mix(
    foreground: tuple[int, int, int],
    background: tuple[int, int, int],
    amount: float,
) -> tuple[int, int, int]:
    return tuple(
        round(source * amount + target * (1.0 - amount))
        for source, target in zip(foreground, background)
    )


def luminance(color: tuple[int, int, int]) -> float:
    linear = []
    for channel in color:
        value = channel / 255.0
        linear.append(
            value / 12.92
            if value <= 0.04045
            else ((value + 0.055) / 1.055) ** 2.4
        )
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(
    foreground: tuple[int, int, int],
    background: tuple[int, int, int],
) -> float:
    first = luminance(foreground)
    second = luminance(background)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)


def preferred_text(background: tuple[int, int, int]) -> tuple[int, int, int]:
    light = contrast(TEXT_LIGHT, background)
    dark = contrast(TEXT_DARK, background)
    best = TEXT_LIGHT if light >= dark else TEXT_DARK
    best_contrast = max(light, dark)
    if best_contrast < MIN_CONTRAST:
        raise ColorError(f"无法生成符合对比度要求的文字颜色：{best_contrast:.2f}:1")
    return best


def update_ini_section(
    text: str,
    section_name: str,
    updates: dict[str, str],
) -> str:
    lines = text.splitlines()
    output: list[str] = []
    current: str | None = None
    pending = dict(updates)

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if current == section_name:
                output.extend(f"{key}={value}" for key, value in pending.items())
                pending.clear()
            current = stripped[1:-1]
            output.append(line)
            continue

        if current == section_name and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in pending:
                output.append(f"{key}={pending.pop(key)}")
                continue
        output.append(line)

    if current == section_name:
        output.extend(f"{key}={value}" for key, value in pending.items())
        pending.clear()
    if pending:
        raise ColorError(f"theme.conf 缺少配置段：[{section_name}]")
    return "\n".join(output) + "\n"


def replace_svg_paint(text: str, attribute: str, color: str) -> str:
    pattern = rf'\b{attribute}="#[0-9A-Fa-f]{{6,8}}"'
    updated, count = re.subn(pattern, f'{attribute}="{color}"', text, count=1)
    if count != 1:
        raise ColorError(f"无法更新 SVG 属性：{attribute}")
    return updated


def replace_svg_opacity(text: str, opacity: float) -> str:
    pattern = r'\bfill-opacity="[0-9.]+"'
    updated, count = re.subn(
        pattern, f'fill-opacity="{opacity:.2f}"', text, count=1
    )
    if count != 1:
        raise ColorError("无法更新 SVG 面板透明度")
    return updated


def atomic_write(path: Path, content: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def resolve_theme(argument: str) -> Path:
    requested = Path(argument).expanduser()
    candidates = [requested]
    if not requested.is_absolute():
        candidates.append(Path(__file__).resolve().parent.parent / requested)
    for candidate in candidates:
        if (candidate / "theme.conf").is_file():
            return candidate.resolve()
    raise ColorError(f"找不到主题目录：{argument}")


def render_palette(
    theme_dir: Path,
    accent: tuple[int, int, int],
) -> tuple[Palette, dict[str, bytes]]:
    highlight_surface = mix(accent, PANEL_COLOR, 0.88)
    palette = Palette(
        accent=color_hex(accent),
        panel_color=color_hex(PANEL_COLOR),
        panel_opacity=PANEL_OPACITY,
        border=color_hex(accent) + BORDER_ALPHA,
        text=color_hex(TEXT_LIGHT),
        highlight_text=color_hex(preferred_text(highlight_surface)),
    )

    theme_path = theme_dir / "theme.conf"
    panel_path = theme_dir / "panel.svg"
    highlight_path = theme_dir / "highlight.svg"
    for path in (theme_path, panel_path, highlight_path):
        if not path.is_file():
            raise ColorError(f"主题缺少文件：{path}")

    theme_conf = theme_path.read_text(encoding="utf-8")
    theme_conf = update_ini_section(
        theme_conf,
        "InputPanel",
        {
            "NormalColor": palette.text,
            "HighlightCandidateColor": palette.highlight_text,
            "HighlightColor": palette.highlight_text,
            "HighlightBackgroundColor": palette.accent,
        },
    )
    theme_conf = update_ini_section(
        theme_conf,
        "InputPanel/Background",
        {
            "Color": palette.panel_color,
            "BorderColor": palette.border,
        },
    )
    theme_conf = update_ini_section(
        theme_conf,
        "InputPanel/Highlight",
        {"Color": palette.accent},
    )
    theme_conf = update_ini_section(
        theme_conf,
        "Menu",
        {
            "NormalColor": palette.text,
            "HighlightCandidateColor": palette.highlight_text,
        },
    )
    theme_conf = update_ini_section(
        theme_conf,
        "Menu/Background",
        {
            "Color": palette.panel_color,
            "BorderColor": palette.border,
        },
    )
    theme_conf = update_ini_section(
        theme_conf,
        "Menu/Highlight",
        {"Color": palette.accent},
    )
    theme_conf = update_ini_section(
        theme_conf,
        "Menu/Separator",
        {"Color": palette.accent + "55"},
    )

    panel_svg = replace_svg_paint(
        panel_path.read_text(encoding="utf-8"), "fill", palette.panel_color
    )
    panel_svg = replace_svg_opacity(panel_svg, palette.panel_opacity)
    panel_svg = replace_svg_paint(panel_svg, "stroke", palette.border)
    highlight_svg = replace_svg_paint(
        highlight_path.read_text(encoding="utf-8"), "fill", palette.accent
    )
    return palette, {
        "theme.conf": theme_conf.encode(),
        "panel.svg": panel_svg.encode(),
        "highlight.svg": highlight_svg.encode(),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="填写自定义 Fcitx5 主题强调色")
    parser.add_argument("--theme", required=True, help="主题目录或主题名")
    parser.add_argument("--color", required=True, help="#RRGGBB、#RRGGBBAA 或 R,G,B")
    parser.add_argument("--dry-run", action="store_true", help="只显示结果不写文件")
    parser.add_argument("--quiet", action="store_true", help="成功时不输出")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        theme_dir = resolve_theme(args.theme)
        accent = parse_color(args.color)
        palette, files = render_palette(theme_dir, accent)
        report = {
            "theme": str(theme_dir),
            "palette": asdict(palette),
            "highlight_contrast": round(
                contrast(
                    parse_color(palette.highlight_text),
                    mix(
                        parse_color(palette.accent),
                        parse_color(palette.panel_color),
                        0.88,
                    ),
                ),
                2,
            ),
        }
        if args.dry_run:
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0
        for name, content in files.items():
            atomic_write(theme_dir / name, content)
        if not args.quiet:
            print(
                f"已写入 {theme_dir}：强调色 {palette.accent}，"
                f"选中文字对比度 {report['highlight_contrast']}:1"
            )
        return 0
    except ColorError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
