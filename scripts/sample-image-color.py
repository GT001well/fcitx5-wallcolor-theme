#!/usr/bin/env python3
"""Extract one stable accent color from a local image."""

from __future__ import annotations

import argparse
import colorsys
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path


class SampleError(RuntimeError):
    """A user-facing image sampling error."""


def histogram_color(digits: str) -> tuple[int, int, int] | None:
    if len(digits) == 12:
        return tuple(
            round(int(digits[index : index + 4], 16) / 257)
            for index in (0, 4, 8)
        )
    if len(digits) in (6, 8):
        return tuple(int(digits[index : index + 2], 16) for index in (0, 2, 4))
    return None


def color_hex(color: tuple[int, int, int]) -> str:
    return "#" + "".join(f"{max(0, min(255, channel)):02X}" for channel in color)


def normalize_accent(color: tuple[int, int, int]) -> tuple[int, int, int]:
    hue, lightness, saturation = colorsys.rgb_to_hls(*(value / 255 for value in color))
    if saturation < 0.12:
        lightness = 0.42
    else:
        lightness = max(0.32, min(0.60, lightness))
        saturation = min(0.72, saturation)
    normalized = colorsys.hls_to_rgb(hue, lightness, saturation)
    return tuple(round(value * 255) for value in normalized)


def sample(image: Path) -> str:
    if not image.is_file():
        raise SampleError(f"图片不存在：{image}")
    magick = shutil.which("magick")
    if not magick:
        raise SampleError("找不到 magick")

    command = [
        magick,
        str(image),
        "-auto-orient",
        "-resize",
        "128x128^",
        "-gravity",
        "center",
        "-extent",
        "128x128",
        "-colors",
        "16",
        "-format",
        "%c",
        "histogram:info:-",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        message = result.stderr.strip() or "ImageMagick 无法读取图片"
        raise SampleError(message)

    candidates: list[tuple[float, int, tuple[int, int, int]]] = []
    fallback: tuple[int, tuple[int, int, int]] | None = None
    pattern = re.compile(r"^\s*(\d+):.*?#([0-9A-Fa-f]{6,16})")
    for line in result.stdout.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        count = int(match.group(1))
        color = histogram_color(match.group(2))
        if color is None:
            continue
        if fallback is None or count > fallback[0]:
            fallback = (count, color)
        _, lightness, saturation = colorsys.rgb_to_hls(
            *(value / 255 for value in color)
        )
        if saturation < 0.16 or lightness < 0.12 or lightness > 0.86:
            continue
        lightness_weight = math.exp(-((lightness - 0.48) / 0.28) ** 2)
        score = math.sqrt(count) * (0.35 + saturation) * lightness_weight
        candidates.append((score, count, color))

    if candidates:
        color = max(candidates, key=lambda item: item[0])[2]
    elif fallback is not None:
        color = fallback[1]
    else:
        raise SampleError("无法从图片中提取颜色")
    return color_hex(normalize_accent(color))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="从图片提取主题强调色")
    parser.add_argument("image", type=Path)
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        print(sample(args.image.resolve()))
        return 0
    except SampleError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
