#!/usr/bin/env python3
"""Generate the Flutter offline curriculum and its public-ID authority table."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = json.loads((ROOT / 'curriculum/workplace_expansion.json').read_text(encoding='utf-8'))
lines = [
    "import '../models/lesson_item.dart';",
    '',
    '/// Generated from curriculum/workplace_expansion.json. Do not edit by hand.',
    'final List<LessonItem> generatedWorkplaceLessons = List.unmodifiable([',
]
for item in source:
    lines.append('  LessonItem(')
    for key, dart_key in [
        ('id', 'id'), ('language', 'language'), ('category', 'category'),
        ('target_text', 'targetText'), ('phonetic_or_kana', 'phoneticOrKana'),
        ('meaning_vi', 'meaningVi'), ('workplace_context', 'workplaceContext'),
        ('workplace_context_vi', 'workplaceContextVi'),
    ]:
        lines.append(f'    {dart_key}: {json.dumps(item[key], ensure_ascii=False)},')
    lines.append('    strokeOrderHints: [')
    for hint in item['stroke_order_hints']:
        lines.append(f'      {json.dumps(hint, ensure_ascii=False)},')
    lines.extend(['    ],', f"    difficultyLevel: {item['difficulty_level']},", '  ),'])
lines.extend([']);', ''])
target = ROOT / 'app/lib/services/generated_workplace_lessons.dart'
target.write_text('\n'.join(lines), encoding='utf-8')

# The Rust literals are the authority for the original catalog; the JSON is
# the authority for the appended workplace expansion.
rust = (ROOT / 'server/src/data.rs').read_text(encoding='utf-8')
legacy_ids = set(re.findall(r'id: "([^"]+)"\.to_string\(\)', rust))
expansion_ids = {item['id'] for item in source}
if len(legacy_ids) != 155 or legacy_ids & expansion_ids:
    raise SystemExit('expected 155 distinct legacy IDs and no expansion collisions')
public_ids = sorted(legacy_ids | expansion_ids)
if len(public_ids) != 355:
    raise SystemExit(f'expected 355 public IDs, found {len(public_ids)}')
id_lines = [
    '// IDs of the built-in curriculum. Private words may never shadow these.',
    'const publicLessonIds = <String>{',
    *(f"  '{lesson_id}'," for lesson_id in public_ids),
    '};',
    '',
]
(ROOT / 'app/lib/models/public_lesson_ids.dart').write_text(
    '\n'.join(id_lines), encoding='utf-8'
)
