import 'package:flutter/material.dart';
import '../services/speech_practice_service.dart';
import '../services/tts_service.dart';

class WebCapabilityCard extends StatefulWidget {
  final SpeechPracticeService? speechService;
  final TtsService? ttsService;
  const WebCapabilityCard({super.key, this.speechService, this.ttsService});
  @override
  State<WebCapabilityCard> createState() => _WebCapabilityCardState();
}

class _WebCapabilityCardState extends State<WebCapabilityCard> {
  late Future<List<bool>> _available;
  Future<bool> _safe(Future<bool> check) =>
      check.then((value) => value, onError: (Object _) => false);
  @override
  void initState() {
    super.initState();
    final tts = widget.ttsService ?? TtsService.defaultInstance;
    _available = Future.wait([
      _safe((widget.speechService ?? SpeechPracticeService()).isAvailable()),
      _safe(tts.isLanguageAvailable('ja')),
      _safe(tts.isLanguageAvailable('en')),
    ]);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<List<bool>>(
        future: _available,
        builder: (context, snapshot) {
          final data = snapshot.data ?? [false, false, false];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Khả năng trên trình duyệt',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Bộ nhớ trình duyệt: IndexedDB • một tab ghi dữ liệu tại một thời điểm.',
              ),
              const Text(
                'Luyện viết: đánh giá hình học gần đúng; không xác nhận chính xác ký tự.',
              ),
              Text(
                data[0]
                    ? 'Giọng nói: có hỗ trợ nhận diện; cần cấp quyền khi dùng.'
                    : 'Giọng nói: Nhập phiên âm khi trình duyệt không hỗ trợ hoặc không cấp quyền.',
              ),
              Text(
                data[1] || data[2]
                    ? 'Phát âm: ${[if (data[1]) "Tiếng Nhật", if (data[2]) "Tiếng Anh"].join(" • ")}'
                    : 'Phát âm: Chưa có giọng đọc phù hợp trên trình duyệt.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Nhận diện giọng nói có thể dùng dịch vụ mạng của trình duyệt. Điểm nói so sánh văn bản đã nhận.',
              ),
            ],
          );
        },
      ),
    ),
  );
}
