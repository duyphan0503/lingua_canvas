import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/canvas_practice_screen.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import '../widget_test.dart' show PracticeApiService;

class QuotaPracticeApi extends PracticeApiService {
  bool full = true;
  int saved = 0;
  @override
  Future<void> submitReview({
    required String itemId,
    required FSRSRating rating,
  }) async {
    if (full) {
      throw const BrowserStorageException('quota', 'full');
    }
    saved++;
  }

  @override
  Future<int> getCompletedCount() async => saved;
}

void main() {
  testWidgets('failed durable review stays unsaved and retries exactly once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = QuotaPracticeApi();
    await tester.pumpWidget(
      MaterialApp(home: CanvasPracticeScreen(apiService: api)),
    );
    await tester.pumpAndSettle();
    final good = find.text('Good');
    await tester.ensureVisible(good);
    await tester.tap(good);
    await tester.pump();
    expect(find.textContaining('Chưa lưu đánh giá'), findsWidgets);
    expect(find.textContaining('Đã lưu đánh giá'), findsNothing);
    expect(api.saved, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('あ'), findsWidgets);
    api.full = false;
    await tester.tap(good);
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.saved, 1);
    expect(find.textContaining('Đã lưu đánh giá'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });
}
