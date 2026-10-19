"""Canonical raw-path and derived-data regressions; no external Python packages."""
import json
import unittest
from preprocess import sample_path
from validate import report, ROOT


class CanonicalRegression(unittest.TestCase):
    def test_real_hatsu_stroke_four_keeps_direction_and_endpoints(self):
        # Exact upstream 0767a-s4 (the stroke the old fabricated guide reversed).
        points = sample_path('M49.25,20.26C57.5,26.25,81,48.75,89.96,53.82c2.4,1.36,4.09,2.38,6.29,2.86')
        self.assertEqual(points[0], (49.25, 20.26))
        self.assertAlmostEqual(points[-1][0], 96.25)
        self.assertAlmostEqual(points[-1][1], 56.68)
        self.assertGreater(len(points), 3)

    def test_relative_smooth_curve_reflects_previous_control(self):
        self.assertEqual(sample_path('M10,10c0,10,10,10,10,0s10,-10,10,0')[-1], (30, 10))
        self.assertEqual(sample_path('M10,10C10,20,20,20,20,10S30,0,30,10')[-1], (30, 10))

    def test_unsupported_commands_and_subpaths_fail_closed(self):
        for path in ('M1,2Q3,4,5,6', 'M1,2c0,1,1,1,1,0M3,4c0,1,1,1,1,0', 'M1,2C3,4'):
            with self.assertRaises(ValueError):
                sample_path(path)

    def test_all_bundled_public_targets_and_kana_have_coverage(self):
        result = report(ROOT / 'app/assets/kanjivg')
        self.assertEqual(result['public_targets_with_gaps'], {})
        self.assertEqual(result['kana_gaps'], [])
        self.assertEqual(result['glyphs'], 6984)
        self.assertGreater(result['public_target_count'], 100)

    def test_canonical_count_and_first_endpoint_are_not_hint_count(self):
        data = json.loads((ROOT / 'app/assets/kanjivg/strokes.json').read_text())['characters']
        self.assertEqual(len(data['開']) + len(data['発']), 21)
        self.assertEqual(data['発'][3][:2], [4518, 1859])
        self.assertEqual(data['発'][3][-2:], [8830, 5200])


if __name__ == '__main__':
    unittest.main()
