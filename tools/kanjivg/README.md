# Offline KanjiVG preprocessing and validation

The Flutter app uses only the checked-in JSON assets; it does not execute Python,
fetch stroke data, parse SVG, or add a Dart dependency at runtime. KanjiVG is
attributed in app/assets/kanjivg/NOTICE.md and its unmodified COPYING is bundled.

Official sources:

- https://github.com/KanjiVG/kanjivg
- https://kanjivg.tagaini.net/svg-format.html (ordered StrokePaths)
- https://kanjivg.tagaini.net/files.html (109×109 cells and coverage)
- https://creativecommons.org/licenses/by-sa/3.0/

Reproduce using Python 3's standard library from the repository root:

```sh
curl -L --fail https://codeload.github.com/KanjiVG/kanjivg/zip/70a0b7ae0c18ceb5cb358274b029cce0234a43bc -o /tmp/kanjivg.zip
unzip -q /tmp/kanjivg.zip -d /tmp/kanjivg
python3 tools/kanjivg/preprocess.py /tmp/kanjivg/kanjivg-70a0b7ae0c18ceb5cb358274b029cce0234a43bc --archive /tmp/kanjivg.zip
python3 tools/kanjivg/validate.py --output app/assets/kanjivg/coverage.json
python3 -m unittest discover -s tools/kanjivg -v
```

The converter rejects source base-SVG digest changes, discontinuous pen paths,
unknown commands, invalid stroke order, and degenerate trajectories. All commands
in the pinned base dataset (M/m, C/c, S/s) are supported; implicit lines after M
are also supported. Cubics use adaptive De Casteljau subdivision; quantization
removes adjacent duplicates. No stroke is synthesized from hints or radicals.
Variants with filename suffixes are deliberately excluded. `manifest.json`
records the source digest, archive digest, output digest, normalization, and size.
The 6,984 base glyphs include kana, kanji, and some Latin/punctuation glyphs.

`validate.py` checks every bundled trajectory and scans current literal public
Japanese LessonItem records in server/src/data.rs and app/lib/services/*lessons*.dart.
It reports missing target characters and all 176 named Unicode kana letters in
the base hiragana/katakana blocks, including voiced and small forms. It does not
infer JLPT levels or silently treat a missing character as supported. Update the
coverage report after curriculum edits. Dynamically generated future targets
need an explicit export/extension to the validator rather than a coverage claim.

Flutter integration: register `assets/kanjivg/` in pubspec.yaml, await
`StrokeGuideService.initialize()` after WidgetsFlutterBinding initialization, and
use `coverageFor(text).isComplete` / `unsupportedCharacters` to explain missing
guides. Loading failure returns false and keeps unavailable state. Recognition
also lazily initializes; Japanese canonical counts override prose hint counts,
and reversed direction checks run only for complete data with aligned counts.
English and unavailable glyphs retain prior recognition scoring. No native iOS
integration is introduced.
