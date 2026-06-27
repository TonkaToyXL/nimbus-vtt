import unittest
import sys
import os

# Add cli directory to sys.path to allow importing voice_to_text
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../cli")))

import voice_to_text


class TestVoiceToTextCLI(unittest.TestCase):

    def test_looks_like_abbrev(self):
        # Acronyms with periods
        self.assertTrue(voice_to_text._looks_like_abbrev("U.S. President", 1))
        self.assertTrue(voice_to_text._looks_like_abbrev("p.m. is late", 1))
        self.assertTrue(voice_to_text._looks_like_abbrev("e.g. this one", 1))

        # Normal sentence ends should not look like abbreviations
        self.assertFalse(voice_to_text._looks_like_abbrev("It is cold. Next sentence.", 10))
        self.assertFalse(voice_to_text._looks_like_abbrev("This is a test.", 14))

    def test_humanize_text_off(self):
        text = "this is um like a raw test... i guess."
        self.assertEqual(voice_to_text.humanize_text(text, "off"), text)

    def test_humanize_text_minimal(self):
        text = "multiple   spaces \n  and newlines"
        expected = "multiple spaces\nand newlines"
        self.assertEqual(voice_to_text.humanize_text(text, "minimal"), expected)

    def test_humanize_text_natural_prose_keeps_fillers(self):
        text = "um basically like I think it is ready."
        result = voice_to_text.humanize_text(text, "natural_prose")
        self.assertIn("um", result.lower())
        self.assertIn("basically", result.lower())
        self.assertNotEqual(result, voice_to_text.humanize_text(text, "agent_handoff"))

    def test_humanize_text_natural_prose_capitalizes(self):
        text = "hello. this is a sentence."
        expected = "Hello. This is a sentence."
        self.assertEqual(voice_to_text.humanize_text(text, "natural_prose"), expected)

    def test_humanize_text_code_aware_preserves_identifiers(self):
        text = "set the variable userName to getValue and call my_function"
        result = voice_to_text.humanize_text(text, "code_aware")
        self.assertIn("userName", result)
        self.assertIn("my_function", result)

    def test_humanize_text_code_aware_multiline(self):
        text = "def hello_world():\n    return 42"
        result = voice_to_text.humanize_text(text, "code_aware")
        self.assertIn("def hello_world", result)
        self.assertIn("return 42", result)

    def test_humanize_text_agent_handoff(self):
        # Test filler words removal
        text = "um basically like I literally think uh it is actually ready."
        expected = "I think it is ready."
        self.assertEqual(voice_to_text.humanize_text(text, "agent_handoff"), expected)

        # Test sentence capitalization
        text = "hello. this is a sentence! another one?"
        expected = "Hello. This is a sentence! Another one?"
        self.assertEqual(voice_to_text.humanize_text(text, "agent_handoff"), expected)

        # Test standalone 'i' capitalization
        text = "well i think i am ready."
        expected = "Well I think I am ready."
        self.assertEqual(voice_to_text.humanize_text(text, "agent_handoff"), expected)

        # Test abbreviations formatting (should not insert spaces after abbreviation periods)
        text = "we will meet at 5 p.m. at the U.S. embassy."
        expected = "We will meet at 5 p.m. at the U.S. embassy."
        self.assertEqual(voice_to_text.humanize_text(text, "agent_handoff"), expected)

    def test_postprocess_presets_include_code_aware(self):
        self.assertIn("code_aware", voice_to_text.POSTPROCESS_PRESETS)

    def test_is_blocked_device(self):
        self.assertTrue(voice_to_text.is_blocked_device("iPhone Microphone", ["iphone"]))
        self.assertTrue(voice_to_text.is_blocked_device("Continuity Camera Mic", ["continuity"]))
        self.assertFalse(voice_to_text.is_blocked_device("MacBook Air Microphone", ["iphone", "continuity"]))

    def test_is_phantom_transcription(self):
        # Silent phantom phrases
        self.assertTrue(voice_to_text.is_phantom_transcription("thank you.", 1.0, 0.01))
        self.assertTrue(voice_to_text.is_phantom_transcription("thanks for watching.", 1.2, 0.015))

        # Real short speech with higher RMS should not be filtered
        self.assertFalse(voice_to_text.is_phantom_transcription("thank you.", 1.0, 0.05))
        # Longer speech should not be filtered
        self.assertFalse(voice_to_text.is_phantom_transcription("thank you.", 5.0, 0.01))
        # Non-phantom phrases should not be filtered
        self.assertFalse(voice_to_text.is_phantom_transcription("hello there.", 1.0, 0.01))

    def test_build_transcribe_kwargs_default_prompt(self):
        kwargs = voice_to_text.build_transcribe_kwargs({})
        self.assertIn("initial_prompt", kwargs)
        self.assertEqual(kwargs["initial_prompt"], voice_to_text.DEFAULT_INITIAL_PROMPT)
        self.assertIn("without_timestamps", kwargs)
        self.assertEqual(kwargs["temperature"], 0.0)

    def test_build_transcribe_kwargs_custom_prompt(self):
        custom = "Transcribe every word literally."
        kwargs = voice_to_text.build_transcribe_kwargs({"initial_prompt": custom})
        self.assertEqual(kwargs["initial_prompt"], custom)

    def test_default_initial_prompt_is_tuned(self):
        prompt = voice_to_text.DEFAULT_INITIAL_PROMPT
        self.assertIn("macOS", prompt)
        self.assertIn("verbatim", prompt.lower())
        self.assertIn("um", prompt.lower())
        self.assertIn("thank you", prompt.lower())

    def test_humanize_text_preserves_url_path_code_aware(self):
        text = "open https://example.com/path and file /tmp/example-docs.txt"
        result = voice_to_text.humanize_text(text, "code_aware")
        self.assertIn("https://example.com/path", result)
        self.assertIn("/tmp/example-docs.txt", result)

    def test_humanize_text_code_aware_keeps_camel_and_snake_identifiers(self):
        text = "set userName to getValue and call my_function"
        result = voice_to_text.humanize_text(text, "code_aware")
        self.assertIn("userName", result)
        self.assertIn("getValue", result)
        self.assertIn("my_function", result)

    def test_humanize_text_no_fillers(self):
        text = "um the deployment is ready uh"
        result = voice_to_text.humanize_text(text, "agent_handoff")
        self.assertNotIn("um", result.lower())
        self.assertNotIn("uh", result.lower())


if __name__ == "__main__":
    unittest.main()
