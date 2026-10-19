# Japanese pitch-accent coverage

The app bundles a source-pinned subset from Kanjium, licensed CC BY-SA 4.0.
The subset contains **60 pitch patterns across 56 exact Japanese
surface-reading pairs** found among the 346 unique surface-reading pairs in the
355 public lesson records. Matching uses
both the written form and lesson reading; it does not guess a reading from
kanji or combine data for words whose surface forms happen to match.

Source, license, required attribution, SHA-256, and regeneration scope are in
[`tools/kanjium/NOTICE.md`](../tools/kanjium/NOTICE.md). The source license is
included beside the vendored upstream text. The application renders each
source-provided downstep as a mora-level contour. Multiple source patterns for
one word and reading stay visible as separate alternatives.

Run `python3 tools/kanjium/generate_pitch_accent.py --check` to verify that
[`generated_pitch_accent.dart`](../app/lib/services/generated_pitch_accent.dart)
matches the pinned source and current public lesson readings. The generator is
deterministic and does no accent prediction. Words or readings outside the
exact subset remain explicitly unavailable and have no contour marker.

No accent data is inferred from TTS audio, speech-recognition transcripts,
romaji, or spelling. The listed patterns are dictionary data, not a diagnosis
of the learner's pronunciation.
