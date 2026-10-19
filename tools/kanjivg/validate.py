#!/usr/bin/env python3
"""Validate the derived KanjiVG data and report exact current public-target gaps."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import unicodedata

ROOT = Path(__file__).resolve().parents[2]


def public_targets(root):
    result = set()
    # These files contain literal public LessonItem records. Require ja language,
    # rather than claiming that every Japanese string in source is a lesson.
    for path in [root / 'server/src/data.rs', *sorted((root / 'app/lib/services').glob('*lessons*.dart'))]:
        if not path.exists():
            continue
        for block in re.split(r'LessonItem\s*[({]', path.read_text()):
            language = re.search(r'language\s*:\s*["\']([^"\']+)', block)
            target = re.search(r'(?:target_text|targetText)\s*:\s*["\']([^"\']+)', block)
            if language and target and language.group(1) == 'ja':
                result.add(target.group(1))
    return sorted(result)


def report(asset_dir, root=ROOT):
    raw = (asset_dir / 'strokes.json').read_bytes()
    data = json.loads(raw)
    manifest = json.loads((asset_dir / 'manifest.json').read_text())
    assert data['version'] == 1 and data['quantization'] == 10000
    assert hashlib.sha256(raw).hexdigest() == manifest['data_sha256'], 'data digest mismatch'
    assert data['source']['commit'] == '70a0b7ae0c18ceb5cb358274b029cce0234a43bc'
    assert data['source']['license'] == 'CC-BY-SA-3.0'
    glyphs = data['characters']
    assert len(glyphs) == manifest['glyphs']
    for char, strokes in glyphs.items():
        assert len(char) == 1 and strokes, repr(char)
        for stroke in strokes:
            assert len(stroke) >= 4 and len(stroke) % 2 == 0, repr(char)
            assert all(type(value) is int and 0 <= value <= 10000 for value in stroke), repr(char)
    targets = public_targets(root)
    assert targets, 'no public Japanese targets extracted'
    missing = {target: sorted({char for char in target if not char.isspace() and char not in glyphs}) for target in targets}
    missing = {target: chars for target, chars in missing.items() if chars}
    target_chars = sorted({char for target in targets for char in target if not char.isspace()})
    # Named Unicode letters, including voiced/small forms, in the two base kana
    # blocks. Punctuation/combining marks/repetition signs are reported separately.
    kana = [chr(code) for code in [*range(0x3041, 0x3097), *range(0x30a1, 0x30fb)] if 'LETTER' in unicodedata.name(chr(code), '')]
    return {'scope': 'upstream non-variant base glyphs; current literal public Japanese targets; Unicode hiragana/katakana letters',
            'jlpt_level_coverage': 'unverified: no official N5–N3 character list supplied',
            'glyphs': len(glyphs), 'strokes': sum(map(len, glyphs.values())),
            'public_target_count': len(targets), 'public_unique_characters': len(target_chars),
            'public_supported_characters': sum(char in glyphs for char in target_chars),
            'public_targets_with_gaps': missing,
            'kana_letter_count': len(kana), 'kana_supported': sum(char in glyphs for char in kana),
            'kana_gaps': [char for char in kana if char not in glyphs]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=ROOT / 'app/assets/kanjivg')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = report(args.assets)
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')
