import 'dart:convert';
import 'dart:typed_data';
import '../services/fsrs_engine.dart';
import '../services/storage/local_models.dart';
import '../services/storage/private_profile.dart';
import 'private_lesson_state.dart';
import 'public_lesson_ids.dart';

class StaleProfileMergeException implements Exception {
  const StaleProfileMergeException();
  @override
  String toString() =>
      'Hồ sơ hoặc dữ liệu đã thay đổi. Vui lòng xem trước lại.';
}

Map<String, dynamic> backupCardJson(FSRSCard c) => {
  'item_id': c.itemId,
  'state': ['New', 'Learning', 'Review', 'Relearning'][c.state.index],
  'stability': c.stability,
  'difficulty': c.difficulty,
  'reps': c.reps,
  'lapses': c.lapses,
  'last_review': c.lastReview.toUtc().toIso8601String(),
  'next_review': c.nextReview.toUtc().toIso8601String(),
  'updated_at': c.lastReview.toUtc().toIso8601String(),
};

class ProfileBackup {
  static const maxBytes = 10 * 1024 * 1024;
  final String backupId;
  final DateTime createdAt;
  final List<PrivateLessonState> privateLessons;
  final List<FSRSCard> cards;
  final List<LocalReviewLog> reviewLogs;
  final List<LocalCompletedLesson> completedLessons;
  final Map<String, int> dailyActivity;
  const ProfileBackup({
    required this.backupId,
    required this.createdAt,
    required this.privateLessons,
    required this.cards,
    required this.reviewLogs,
    required this.completedLessons,
    required this.dailyActivity,
  });
  Map<String, dynamic> toJson() => {
    'format': 'lingua_canvas_backup',
    'version': 1,
    'backup_id': backupId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'private_lessons': privateLessons.map((s) => s.toJson()).toList(),
    'cards': cards.map(backupCardJson).toList(),
    'review_logs': reviewLogs.map((r) => r.toMap()..remove('synced')).toList(),
    'completed_lessons': completedLessons
        .map((r) => r.toMap()..remove('synced'))
        .toList(),
    'daily_activity': dailyActivity,
  };
  Uint8List toBytes() {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (bytes.length > maxBytes) {
      throw const FormatException('Tệp sao lưu vượt quá 10 MiB.');
    }
    return bytes;
  }

  factory ProfileBackup.fromBytes(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Tệp sao lưu vượt quá 10 MiB.');
    }
    try {
      return ProfileBackup.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Tệp sao lưu không hợp lệ.');
    }
  }
  factory ProfileBackup.fromJson(Map<String, dynamic> j, {DateTime? now}) {
    try {
      if (j['format'] != 'lingua_canvas_backup' || j['version'] != 1) {
        throw const FormatException('Phiên bản sao lưu chưa được hỗ trợ.');
      }
      const allowed = {
        'format',
        'version',
        'backup_id',
        'created_at',
        'private_lessons',
        'cards',
        'review_logs',
        'completed_lessons',
        'daily_activity',
      };
      if (j.keys.any((k) => !allowed.contains(k))) {
        throw const FormatException('Sao lưu có trường không được hỗ trợ.');
      }
      final latestAllowed = (now ?? DateTime.now()).toUtc().add(
        const Duration(minutes: 5),
      );
      DateTime date(dynamic value, {bool future = false}) {
        if (value is! String ||
            !RegExp(
              r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[.]\d{1,9})?(?:Z|[+]00:00)$',
            ).hasMatch(value)) {
          throw const FormatException('Thời gian sao lưu không hợp lệ.');
        }
        final t = DateTime.parse(value).toUtc();
        if (t.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
          throw const FormatException('Ngày giờ sao lưu không hợp lệ.');
        }
        if (t.isBefore(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)) ||
            (!future && t.isAfter(latestAllowed))) {
          throw const FormatException(
            'Thời gian sao lưu vượt quá đồng hồ hiện tại.',
          );
        }
        return t;
      }

      final id = j['backup_id'] as String;
      if (id.isEmpty || id.length > 128 || id.contains('\u0000')) {
        throw const FormatException('Mã sao lưu không hợp lệ.');
      }
      final created = date(j['created_at']);
      final private = (j['private_lessons'] as List).map((v) {
        final state = PrivateLessonState.fromJson(v as Map<String, dynamic>);
        PrivateProfile.validateLesson(state.lesson);
        if (state.revision < 0 || state.localVersion < 0) {
          throw const FormatException('Phiên bản từ không hợp lệ.');
        }
        date(v['updated_at']);
        if (state.conflict != null) {
          PrivateProfile.validateLesson(state.conflict!.local.lesson);
          final remote = state.conflict!.remote;
          if (remote != null) PrivateProfile.validateLesson(remote.lesson);
        }
        return state;
      }).toList();
      final ids = private.map((s) => s.lesson.id).toSet();
      if (ids.length != private.length) {
        throw const FormatException('Trùng mã từ trong sao lưu.');
      }
      bool referenced(dynamic value) =>
          value is String &&
          (ids.contains(value) || publicLessonIds.contains(value));
      void range(dynamic v, num min, num max) {
        if (v is! num || !v.isFinite || v < min || v > max) {
          throw const FormatException('Giá trị tiến độ không hợp lệ.');
        }
      }

      int integer(dynamic v, int min, int max) {
        if (v is! int) {
          throw const FormatException('Giá trị số nguyên không hợp lệ.');
        }
        range(v, min, max);
        return v;
      }

      final cards = (j['cards'] as List).map((v) {
        final r = v as Map<String, dynamic>;
        if (!referenced(r['item_id'])) {
          throw const FormatException('Thẻ tham chiếu từ không tồn tại.');
        }
        final state = [
          'New',
          'Learning',
          'Review',
          'Relearning',
        ].indexOf(r['state'] as String);
        if (state < 0) {
          throw const FormatException('Trạng thái thẻ không hợp lệ.');
        }
        range(r['stability'], 0, 36500);
        range(r['difficulty'], 0, 10);
        final reps = integer(r['reps'], 0, 2147483647);
        final lapses = integer(r['lapses'], 0, 2147483647);
        if (lapses > reps) {
          throw const FormatException('Số lần học lại không hợp lệ.');
        }
        date(r['updated_at']);
        final last = date(r['last_review']);
        final next = date(r['next_review'], future: true);
        if (next.isBefore(last) ||
            next.isAfter(latestAllowed.add(const Duration(days: 36500)))) {
          throw const FormatException('Ngày ôn tiếp theo không hợp lệ.');
        }
        return FSRSCard(
          itemId: r['item_id'] as String,
          state: FSRSState.values[state],
          stability: (r['stability'] as num).toDouble(),
          difficulty: (r['difficulty'] as num).toDouble(),
          reps: reps,
          lapses: lapses,
          lastReview: date(r['last_review']),
          nextReview: date(r['next_review'], future: true),
        );
      }).toList();
      final logs = (j['review_logs'] as List).map((v) {
        final r = v as Map<String, dynamic>;
        if (!referenced(r['item_id']) ||
            r['id'] is! String ||
            (r['id'] as String).isEmpty ||
            (r['id'] as String).length > 128) {
          throw const FormatException('Lịch sử ôn không hợp lệ.');
        }
        integer(r['rating'], 1, 4);
        integer(r['state'], 0, 3);
        range(r['elapsed_days'], 0, 365000);
        integer(r['scheduled_days'], 0, 36500);
        date(r['review_time']);
        return LocalReviewLog.fromMap({...r, 'synced': 1});
      }).toList();
      final completed = (j['completed_lessons'] as List).map((v) {
        final r = v as Map<String, dynamic>;
        if (!referenced(r['lesson_id'])) {
          throw const FormatException('Tiến độ tham chiếu bài không tồn tại.');
        }
        date(r['completed_at']);
        range(r['score'], 0, 1);
        return LocalCompletedLesson.fromMap({...r, 'synced': 1});
      }).toList();
      for (final list in [
        cards.map((c) => c.itemId).toList(),
        logs.map((r) => r.id).toList(),
        completed.map((r) => r.lessonId).toList(),
      ]) {
        if (list.toSet().length != list.length) {
          throw const FormatException('Trùng mã mục trong sao lưu.');
        }
      }
      final activity = Map<String, int>.from(j['daily_activity'] as Map);
      for (final e in activity.entries) {
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(e.key) ||
            DateTime.parse(
                  '${e.key}T00:00:00Z',
                ).toIso8601String().substring(0, 10) !=
                e.key) {
          throw const FormatException('Ngày học không hợp lệ.');
        }
        integer(e.value, 0, 2147483647);
      }
      return ProfileBackup(
        backupId: id,
        createdAt: created,
        privateLessons: List.unmodifiable(private),
        cards: List.unmodifiable(cards),
        reviewLogs: List.unmodifiable(logs),
        completedLessons: List.unmodifiable(completed),
        dailyActivity: Map.unmodifiable(activity),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Nội dung sao lưu không hợp lệ.');
    }
  }
}

class ProfileMergePreview {
  final ProfileBackup backup;
  final String binding;
  final String contentRevision;
  final String backupRevision;
  final int additions, updates, skips, conflicts;
  const ProfileMergePreview({
    required this.backup,
    required this.binding,
    required this.contentRevision,
    required this.backupRevision,
    required this.additions,
    required this.updates,
    required this.skips,
    required this.conflicts,
  });
}
