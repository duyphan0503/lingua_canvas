import 'package:app/models/lesson_item.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/phase3_lessons.dart';
import 'package:app/screens/curriculum_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Phase3Api extends ApiService {
  @override
  Future<List<PrivateLessonState>> getPrivateLessons({
    bool includeDeleted = false,
  }) async => [];

  @override
  Future<List<LessonItem>> getLessons({String? language}) async =>
      phase3Lessons;
  @override
  Future<List<FSRSCard>> getAllCards() async => [];
}

void main() {
  testWidgets('N4 workplace and TOEIC filters expose their own lessons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: CurriculumScreen(apiService: Phase3Api())),
    );
    await tester.pumpAndSettle();
    final n4 = find.widgetWithText(ChoiceChip, 'JLPT N4 (Công sở)');
    await tester.ensureVisible(n4);
    await tester.tap(n4);
    await tester.pumpAndSettle();
    expect(find.text('会議'), findsOneWidget);
    expect(find.text('negotiate'), findsNothing);
    final toeic = find.widgetWithText(ChoiceChip, 'TOEIC & Business');
    await tester.ensureVisible(toeic);
    await tester.tap(toeic);
    await tester.pumpAndSettle();
    expect(find.text('negotiate'), findsOneWidget);
    expect(find.text('会議'), findsNothing);
  });
}
