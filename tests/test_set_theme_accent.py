from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "set-theme-accent.py"
SPEC = importlib.util.spec_from_file_location("set_theme_accent", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ColorTests(unittest.TestCase):
    def test_parse_hex_and_rgb(self) -> None:
        self.assertEqual(MODULE.parse_color("#07C160"), (7, 193, 96))
        self.assertEqual(MODULE.parse_color("7,193,96"), (7, 193, 96))

    def test_contrast(self) -> None:
        self.assertGreater(MODULE.contrast((0, 0, 0), (255, 255, 255)), 20)

    def test_mid_gray_still_meets_text_contrast(self) -> None:
        palette = MODULE.render_palette(
            Path(__file__).resolve().parent.parent / "themes" / "local",
            (128, 128, 128),
        )[0]
        surface = MODULE.mix(
            MODULE.parse_color(palette.accent),
            MODULE.parse_color(palette.panel_color),
            0.88,
        )
        self.assertGreaterEqual(
            MODULE.contrast(MODULE.parse_color(palette.highlight_text), surface),
            4.5,
        )

    def test_render_updates_all_theme_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            theme = Path(directory) / "wechat-green"
            source = (
                Path(__file__).resolve().parent.parent
                / "themes"
                / "wechat-green"
            )
            shutil.copytree(source, theme)
            _, files = MODULE.render_palette(theme, (7, 193, 96))
            theme_text = files["theme.conf"].decode()
            self.assertIn("HighlightBackgroundColor=#07C160", theme_text)
            self.assertIn("[Menu]", theme_text)
            self.assertIn("Color=#07C16055", theme_text)
            self.assertIn('fill="#07C160"', files["highlight.svg"].decode())
            self.assertIn('stroke="', files["panel.svg"].decode())
            self.assertIn('fill="#000000"', files["panel.svg"].decode())
            self.assertIn('fill-opacity="0.20"', files["panel.svg"].decode())
            self.assertIn("NormalColor=#FCFCFC", files["theme.conf"].decode())


if __name__ == "__main__":
    unittest.main()
