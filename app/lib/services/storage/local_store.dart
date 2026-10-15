import '../../models/lesson_item.dart';
import '../fsrs_engine.dart';
import 'local_models.dart';

abstract interface class LocalStore {
  Future<void> initialize();
  Future<void> selectBackend(String baseUrl);
  Future<void> clearCurrentProfile();
  Future<void> saveLessons(List<LessonItem> lessons);
  Future<void> saveLesson(LessonItem lesson);
  Future<List<LessonItem>> getLessons({String? language, String? category});
  Future<LessonItem?> getLesson(String id);
  Future<void> saveCard(FSRSCard card);
  Future<FSRSCard?> getCard(String itemId);
  Future<List<FSRSCard>> getAllCards();
  Future<List<String>> getDueCardIds(DateTime asOf);
  Future<void> insertReviewLog(LocalReviewLog log);
  Future<List<LocalReviewLog>> getReviewLogs({int? synced, int? limit});
  Future<void> markReviewLogsSynced(List<String> ids);
  Future<int> enqueueMutation({
    required String mutationType,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
  });
  Future<List<SyncQueueItem>> getPendingMutations({int? limit});
  Future<void> recoverInterruptedMutations();
  Future<T> withProfileLock<T>(Future<T> Function() operation);
  Future<String?> getMetadata(String key);
  Future<void> setMetadata(String key, String value);
  Future<Map<String, dynamic>?> getAccount();
  Future<int?> getSyncSequence();
  Future<void> setSyncSequence(int sequence);
  Future<void> switchAccount(Map<String, dynamic>? account);
  Future<DateTime?> getLastPullTime();
  Future<String> getOrCreateClientId();
  Future<void> setLastPullTime(DateTime time);
  Future<void> markMutationsInProgress(List<int> ids);
  Future<void> deleteMutations(List<int> ids);
  Future<void> resetFailedMutations(List<int> ids);
  Future<void> saveCompletedLesson(
    String lessonId, {
    DateTime? completedAt,
    double score = 1.0,
    int synced = 0,
  });
  Future<List<LocalCompletedLesson>> getCompletedLessons({int? synced});
  Future<int> getCompletedCount();
  Future<void> markCompletedLessonsSynced(List<String> lessonIds);
  Future<String> recordReviewTransaction({
    required FSRSCard updatedCard,
    required FSRSRating rating,
    required DateTime reviewTime,
    required double elapsedDays,
    required int scheduledDays,
    double completionScore = 1.0,
  });
  Future<void> logDailyActivity(DateTime date, int itemsCount);
  Future<StudyStreak> getStudyStreak({DateTime? asOf});
  Future<void> clearAll();
  Future<void> close();
}
