# Browser handwriting recognition evaluation

**Decision (2026-10-19): no browser model is bundled.** The available
web-path fallback remains explicitly labeled as approximate geometric
assessment; it does not claim to recognize Japanese handwriting.

Google ML Kit Digital Ink is not a Web option: its official documentation lists
Android and iOS support, and its language models are downloaded dynamically
(about 20 MB per language). That model is unsuitable for a small, offline
browser shell. See [ML Kit Digital Ink](https://developers.google.com/ml-kit/vision/digital-ink-recognition)
and [model downloads](https://developers.google.com/ml-kit/vision/digital-ink-recognition/android).

The official [TensorFlow.js pretrained-model catalog](https://github.com/tensorflow/tfjs-models)
does not list a digital-ink or Japanese handwriting recognizer. Its listed hand
pose model detects hand joints, which does not recognize the learner's drawn
strokes. No candidate was found that simultaneously provides a redistributable
model license, a small browser package, verified Japanese character coverage,
and support for ordered vector strokes.

The current browser UI therefore identifies its score as “Đánh giá hình học
(gần đúng)” and hides native model-download controls. Existing Android ML Kit
behavior remains separate. Revisit this decision only when a candidate's model
license, training-data rights, package size, Japanese coverage, browser
runtime, and held-out accuracy are documented and tested. No accuracy claim is
made from the present geometric heuristic.
