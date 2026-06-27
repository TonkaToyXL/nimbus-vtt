import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../cli")))

import voice_to_text


def test_humanize_text_unknown_mode_falls_back_to_raw():
    text = "leave this unknown mode output alone"
    assert voice_to_text.humanize_text(text, "bad_mode") == text
