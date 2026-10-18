import 'package:flutter/material.dart';
import '../services/speech_practice_service.dart';

Future<String?> captureSpeechTranscript(
  BuildContext context,
  SpeechPracticeService service,
  String language, {
  required bool Function() isCurrent,
}) async {
  final available = await service.isAvailable();
  if (!context.mounted || !isCurrent()) return null;
  if (available) {
    try {
      return await service.listen(language: language);
    } on SpeechPracticeException catch (error) {
      if (!['permission_denied', 'unavailable'].contains(error.code)) rethrow;
    }
  }
  if (!context.mounted || !isCurrent()) return null;
  return showDialog<String>(
    context: context,
    builder: (_) => const _TranscriptDialog(),
  );
}

class _TranscriptDialog extends StatefulWidget {
  const _TranscriptDialog();
  @override
  State<_TranscriptDialog> createState() => _TranscriptDialogState();
}

class _TranscriptDialogState extends State<_TranscriptDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nhập bản phiên âm'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Không thể dùng nhận diện giọng nói hoặc chưa có quyền microphone. Nhập nội dung để đối chiếu văn bản; ứng dụng không thu âm.',
        ),
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nội dung đã nói'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Đối chiếu'),
      ),
    ],
  );
}
