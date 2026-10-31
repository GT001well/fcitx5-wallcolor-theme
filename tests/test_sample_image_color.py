from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "sample-image-color.py"
SPEC = importlib.util.spec_from_file_location("sample_image_color", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SampleTests(unittest.TestCase):
    def test_histogram_16_bit_channels(self) -> None:
        self.assertEqual(MODULE.histogram_color("15F136C276B2"), (22, 55, 118))

    @unittest.skipUnless(subprocess.run(
        ["sh", "-c", "command -v magick"], capture_output=True
    ).returncode == 0, "ImageMagick not installed")
    def test_blue_gradient(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "blue.png"
            subprocess.run(
                ["magick", "-size", "256x256", "gradient:#12306F-#4A8FD8", str(image)],
                check=True,
            )
            color = MODULE.sample(image)
            red = int(color[1:3], 16)
            green = int(color[3:5], 16)
            blue = int(color[5:7], 16)
            self.assertGreater(blue, red)
            self.assertGreater(blue, green)

    @unittest.skipUnless(subprocess.run(
        ["sh", "-c", "command -v magick"], capture_output=True
    ).returncode == 0, "ImageMagick not installed")
    def test_white_image_is_not_used_as_glaring_accent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "white.png"
            subprocess.run(
                ["magick", "-size", "128x128", "xc:#F5F5F5", str(image)],
                check=True,
            )
            color = MODULE.sample(image)
            self.assertLess(max(int(color[index : index + 2], 16) for index in (1, 3, 5)), 180)


if __name__ == "__main__":
    unittest.main()
