import importlib.util
import unittest
from pathlib import Path


MODULE = Path(__file__).with_name('generate_pitch_accent.py')
SPEC = importlib.util.spec_from_file_location('generate_pitch_accent', MODULE)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class PitchAccentGenerationTest(unittest.TestCase):
    def test_selects_exact_surface_and_reading_and_preserves_variants(self):
        lines = [
            '会議\tかいぎ\t1,3',
            '会議\tけんぎ\t0',
            '会議\tかいぎ\t1,3',
            '相談\tそうだん\t0',
            'invalid\treading\tn/a',
        ]
        self.assertEqual(
            GENERATOR.select_entries(lines, {('会議', 'かいぎ')}),
            [('会議', 'かいぎ', 1), ('会議', 'かいぎ', 3)],
        )

    def test_output_is_stable_and_contains_only_selected_patterns(self):
        generated = GENERATOR.render_dart([('進捗', 'しんちょく', 0)])
        self.assertIn('"word": "進捗"', generated)
        self.assertIn('"reading": "しんちょく"', generated)
        self.assertIn('"downstep": 0', generated)
        self.assertEqual(generated, GENERATOR.render_dart([('進捗', 'しんちょく', 0)]))


if __name__ == '__main__':
    unittest.main()
