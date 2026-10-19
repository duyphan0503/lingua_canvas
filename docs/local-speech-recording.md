# Local speech practice recordings

Roleplay has optional microphone recording, playback, and deletion beside its
TTS control. The clip is kept in a temporary location on the current device;
the app does not upload it or add it to account sync. The user can delete the
clip from the same controls, and the operating system may clear temporary
files at any time. On the web, microphone permission and recording are subject
to browser support and the browser's secure-context rules.

The implementation uses the BSD-3-Clause [`record` package](https://pub.dev/packages/record)
for capture and [`audioplayers`](https://pub.dev/packages/audioplayers) for
local replay. Linux recording requires `parecord`, `pactl`, and `ffmpeg` to be
installed separately; see the package's Linux setup instructions. Playback
availability depends on the host's audio stack.
