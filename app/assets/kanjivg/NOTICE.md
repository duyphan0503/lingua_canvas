# KanjiVG stroke data attribution

KanjiVG © 2009–2026 Ulrich Apel. Source: https://kanjivg.tagaini.net/
Official source repository: https://github.com/KanjiVG/kanjivg
Pinned revision: 70a0b7ae0c18ceb5cb358274b029cce0234a43bc (2026-09-30).

The derived `strokes.json` data is distributed under the Creative Commons
Attribution–ShareAlike 3.0 Unported license, as is the upstream KanjiVG data:
https://creativecommons.org/licenses/by-sa/3.0/
The upstream license text is included in COPYING. Changes: non-variant Unicode
SVG glyphs only; ordered cubic curves sampled to polylines with 0.25 SVG-pixel
flatness tolerance; isotropically fitted to the union of the 109×109 viewBox and
sampled path bounds; coordinates rounded to 1/10000. Stroke order is preserved.
This data license applies to the derived stroke dataset, not a new license grant
for unrelated application code.

The bundle includes the entire upstream base-glyph collection, rather than an
unofficial JLPT classification. It does not claim exhaustive N5/N4/N3 coverage:
JLPT levels are not assigned by KanjiVG and no official level list was supplied.
`coverage.json` records exact checked curriculum/kana coverage and gaps. Unknown
characters, including unsupported variants, explicitly have no canonical guide.

See tools/kanjivg/README.md for reproduction and validation instructions.
