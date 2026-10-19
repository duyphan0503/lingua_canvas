import 'package:app/services/storage/credential_vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/screens/analytics_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/sync_coordinator.dart';

final testCredentialVault = InMemoryCredentialVault();

class MockAnalyticsApiService extends ApiService {
  @override
  Future<Map<String, dynamic>> getFSRSStats() async => {
    'total_cards': 25,
    'total_completed': 18,
    'due_today': 1,
    'pending_sync_mutations': 2,
    'avg_stability': 6.2,
    'estimated_retention': 92,
    'state_breakdown': {'new': 5, 'learning': 8, 'review': 10, 'relearning': 2},
  };

  @override
  Future<List<LessonItem>> getDueLessons() async => [
    LessonItem(
      id: 'ja_kata_bug',
      language: 'ja',
      category: 'it_workplace',
      targetText: 'バグ',
      phoneticOrKana: 'bagu',
      meaningVi: 'Lỗi phần mềm (Bug)',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
  ];

  @override
  Future<SyncResult> sync() async =>
      SyncResult(success: true, syncedReviews: 2, pulledCards: 1);

  @override
  Future<StudyStreak> getStudyStreak({DateTime? asOf}) async {
    final now = asOf ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final history = <String, int>{};
    for (int i = 29; i >= 0; i--) {
      final d = DateTime(today.year, today.month, today.day - i);
      final key =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      history[key] = (i < 7) ? (i + 1) * 2 : 0;
    }
    return StudyStreak(
      currentStreak: 7,
      longestStreak: 14,
      activityHistory: history,
    );
  }
}

void main() {
  group('AnalyticsScreen Widget Tests', () {
    testWidgets('renders FSRS metrics and triggers manual sync', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = MockAnalyticsApiService();
      LessonItem? practicedDue;

      await tester.pumpWidget(
        MaterialApp(
          home: AnalyticsScreen(
            apiService: service,
            onPracticeDueLesson: (l) => practicedDue = l,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Metrics
      expect(find.text('92%'), findsOneWidget);
      expect(find.text('25'), findsOneWidget); // total cards
      expect(find.text('18'), findsOneWidget); // completed
      expect(find.text('バグ'), findsOneWidget); // due lesson

      // Verify Quiet Streak card & Heatmap
      expect(
        find.text('Chuỗi ngày học tập: 7 ngày liên tục 🔥'),
        findsOneWidget,
      );
      expect(find.textContaining('Kỷ lục: 14 ngày'), findsOneWidget);
      expect(find.text('Lịch sử ôn tập (14 ngày)'), findsOneWidget);

      // Trigger manual sync
      final syncBtn = find.text('Đồng bộ ngay');
      expect(syncBtn, findsOneWidget);
      await tester.tap(syncBtn);
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify sync result notification
      expect(find.textContaining('Đồng bộ hoàn tất!'), findsOneWidget);

      // Tap 'Ôn ngay' on due card
      final reviewDueBtn = find.text('Ôn ngay');
      await tester.tap(reviewDueBtn);
      expect(practicedDue?.id, 'ja_kata_bug');
    });
  });

  group('Study Streak Calculation and Tracking Tests', () {
    late LocalDatabase localDb;

    setUp(() async {
      LocalDatabase.initFfiIfNeeded();
      localDb = LocalDatabase.instance;
      await localDb.initCustom(
        credentialVault: testCredentialVault,
        customPath: inMemoryDatabasePath,
      );
      await localDb.clearAll();
    });

    tearDown(() async {
      await localDb.close();
    });

    test('returns 0 streak when database has no activity', () async {
      final now = DateTime(2026, 10, 2, 12, 0);
      final streak = await localDb.getStudyStreak(asOf: now);
      expect(streak.currentStreak, 0);
      expect(streak.longestStreak, 0);
      expect(streak.activityHistory.length, 30);
      expect(streak.activityHistory.values.every((v) => v == 0), isTrue);
    });

    test(
      'maintains quiet streak when user studied yesterday but not yet today',
      () async {
        final today = DateTime(2026, 10, 2);
        final yesterday = DateTime(2026, 10, 1);

        await localDb.logDailyActivity(yesterday, 5);

        final streak = await localDb.getStudyStreak(asOf: today);
        expect(streak.currentStreak, 1);
        expect(streak.longestStreak, 1);
        expect(streak.activityHistory['2026-10-01'], 5);
        expect(streak.activityHistory['2026-10-02'], 0);
      },
    );

    test(
      'accumulates multiple logs on same date and extends streak today',
      () async {
        final today = DateTime(2026, 10, 2);
        final yesterday = DateTime(2026, 10, 1);

        await localDb.logDailyActivity(yesterday, 3);
        await localDb.logDailyActivity(today, 2);
        await localDb.logDailyActivity(today, 4); // accumulates to 6

        final streak = await localDb.getStudyStreak(asOf: today);
        expect(streak.currentStreak, 2);
        expect(streak.longestStreak, 2);
        expect(streak.activityHistory['2026-10-02'], 6);
      },
    );

    test(
      'calculates multi-day streak, gaps, and preserves historical longest streak',
      () async {
        final ref = DateTime(2026, 10, 15);

        // Period 1: 5 consecutive days (Oct 1 to Oct 5)
        for (int day = 1; day <= 5; day++) {
          await localDb.logDailyActivity(DateTime(2026, 10, day), 10);
        }

        // Gap: Oct 6 to Oct 12 (7 days break)

        // Period 2: 3 consecutive days (Oct 13 to Oct 15)
        for (int day = 13; day <= 15; day++) {
          await localDb.logDailyActivity(DateTime(2026, 10, day), 5);
        }

        final streak = await localDb.getStudyStreak(asOf: ref);
        expect(streak.currentStreak, 3);
        expect(streak.longestStreak, 5);
      },
    );

    test(
      'ApiService exposes getStudyStreak and delegates to local database',
      () async {
        final today = DateTime(2026, 10, 2);
        final api = ApiService(localDb: localDb);

        await api.logDailyActivity(today, 8);
        final streak = await api.getStudyStreak(asOf: today);

        expect(streak.currentStreak, 1);
        expect(streak.longestStreak, 1);
        expect(streak['current_streak'], 1);
        expect(streak['longest_streak'], 1);
        expect(streak['last_30_days']['2026-10-02'], 8);
      },
    );
  });
}
