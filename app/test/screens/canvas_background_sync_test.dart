import 'package:app/models/lesson_item.dart';
import 'package:app/screens/canvas_practice_screen.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/widgets/handwriting_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widget_test.dart' show PracticeApiService;

LessonItem lesson(String id, String text) => LessonItem(
  id: id,
  language: 'en',
  category: 'it_workplace',
  targetText: text,
  phoneticOrKana: '',
  meaningVi: 'Meaning of $text',
  workplaceContext: '',
  workplaceContextVi: '',
  strokeOrderHints: [],
  difficultyLevel: 1,
);

class BackgroundSyncApi extends PracticeApiService {
  List<LessonItem> lessons = [lesson('private_active', 'deploy')];
  SyncResult result = SyncResult(success: true);

  @override
  Future<List<LessonItem>> getLessons({String? language}) async =>
      List.of(lessons);

  @override
  Future<SyncResult> sync() async => result;
}

Future<void> openCanvas(WidgetTester tester, BackgroundSyncApi api) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: CanvasPracticeScreen(
        apiService: api,
        digitalInkEngine: MockDigitalInkEngine(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> draw(WidgetTester tester) async {
  final canvas = find.byType(HandwritingCanvas);
  final gesture = await tester.startGesture(tester.getCenter(canvas));
  await gesture.moveBy(const Offset(30, 20));
  await gesture.up();
  await tester.pump();
  expect(tester.widget<HandwritingCanvas>(canvas).strokes, isNotEmpty);
}

Future<void> syncOnTimer(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 30));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'private-only pull refreshes metadata and preserves active drawing',
    (tester) async {
      final api = BackgroundSyncApi();
      await openCanvas(tester, api);
      await draw(tester);
      final strokes = tester
          .widget<HandwritingCanvas>(find.byType(HandwritingCanvas))
          .strokes;
      api.lessons = [
        lesson('private_new', 'release'),
        lesson('private_active', 'updated deploy'),
      ];
      await syncOnTimer(tester);
      expect(find.text('updated deploy'), findsWidgets);
      expect(find.text('Meaning of updated deploy'), findsOneWidget);
      expect(
        tester
            .widget<HandwritingCanvas>(find.byType(HandwritingCanvas))
            .strokes,
        same(strokes),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final cards in [0, 1]) {
    testWidgets('completion pull with $cards cards refreshes progress', (
      tester,
    ) async {
      final api = BackgroundSyncApi();
      await openCanvas(tester, api);
      expect(find.text('Đã luyện: 0'), findsOneWidget);
      api.completed = 1;
      api.result = SyncResult(success: true, pulledCards: cards);
      await syncOnTimer(tester);
      expect(find.text('Đã luyện: 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'private soft deletion removes selected lesson and clears drawing',
    (tester) async {
      final api = BackgroundSyncApi();
      await openCanvas(tester, api);
      await draw(tester);
      api.lessons = [lesson('remaining', 'release')];
      await syncOnTimer(tester);
      expect(find.text('deploy'), findsNothing);
      expect(find.text('release'), findsWidgets);
      expect(
        tester
            .widget<HandwritingCanvas>(find.byType(HandwritingCanvas))
            .strokes,
        isEmpty,
      );
      api.lessons = [];
      await syncOnTimer(tester);
      expect(find.byType(HandwritingCanvas), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
