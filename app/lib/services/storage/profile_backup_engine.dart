import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../models/profile_backup.dart';
import '../../models/private_lesson_state.dart';
import '../fsrs_engine.dart';
import 'local_models.dart';
import 'private_profile.dart';

class ProfileBackupEngine {
  static String fingerprint(dynamic data) {
    dynamic sorted(dynamic v) {
      if (v is Map) {
        final keys = v.keys.cast<String>().toList()..sort();
        return {for (final k in keys) k: sorted(v[k])};
      }
      if (v is List) return v.map(sorted).toList();
      return v;
    }

    return sha256.convert(utf8.encode(jsonEncode(sorted(data)))).toString();
  }

  static String revision(Map<String, dynamic> p) => fingerprint({
    for (final t in [
      'lessons',
      'private_lessons',
      'cards',
      'logs',
      'queue',
      'completions',
      'activity',
      'merge_receipts',
    ])
      t: p[t] ?? {},
  });
  static ProfileBackup export(
    Map<String, dynamic> p, {
    Set<String>? lessonIds,
  }) {
    final states =
        PrivateProfile.table(p, 'private_lessons').values
            .map((v) => PrivateLessonState.fromJson(v as Map<String, dynamic>))
            .where((s) => lessonIds == null || lessonIds.contains(s.lesson.id))
            .toList()
          ..sort((a, b) => a.lesson.id.compareTo(b.lesson.id));
    final ids = states.map((s) => s.lesson.id).toSet();
    bool selected(String id) => lessonIds == null || ids.contains(id);
    final cards =
        PrivateProfile.table(p, 'cards').values
            .map((r) => FSRSCard.fromJson(r as Map<String, dynamic>))
            .where((c) => selected(c.itemId))
            .toList()
          ..sort((a, b) => a.itemId.compareTo(b.itemId));
    final logs =
        PrivateProfile.table(p, 'logs').values
            .map((r) => LocalReviewLog.fromMap(r as Map<String, dynamic>))
            .where((r) => selected(r.itemId))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final completed =
        PrivateProfile.table(p, 'completions').values
            .map((r) => LocalCompletedLesson.fromMap(r as Map<String, dynamic>))
            .where((r) => selected(r.lessonId))
            .toList()
          ..sort((a, b) => a.lessonId.compareTo(b.lessonId));
    final activity = lessonIds == null
        ? Map<String, int>.from(PrivateProfile.table(p, 'activity'))
        : <String, int>{};
    if (lessonIds != null) {
      for (final log in logs) {
        final date = log.reviewTime.toLocal().toIso8601String().substring(
          0,
          10,
        );
        activity[date] = (activity[date] ?? 0) + 1;
      }
    }
    final initial = ProfileBackup(
      backupId: 'pending',
      createdAt: DateTime.now().toUtc(),
      privateLessons: states,
      cards: cards,
      reviewLogs: logs,
      completedLessons: completed,
      dailyActivity: activity,
    );
    final json = initial.toJson()
      ..remove('backup_id')
      ..remove('created_at');
    return ProfileBackup.fromJson({
      ...initial.toJson(),
      'backup_id': fingerprint(json),
    });
  }

  static ProfileMergePreview preview(
    Map<String, dynamic> p,
    ProfileBackup source,
    String binding,
  ) {
    // Revalidate even programmatically constructed DTOs before reading or writing.
    final backup = ProfileBackup.fromBytes(source.toBytes());
    final simulation = PrivateProfile.clone(p);
    final counts = merge(simulation, backup);
    return ProfileMergePreview(
      backup: backup,
      binding: binding,
      contentRevision: revision(p),
      backupRevision: fingerprint(backup.toJson()),
      additions: counts[0],
      updates: counts[1],
      skips: counts[2],
      conflicts: counts[3],
    );
  }

  static List<int> merge(Map<String, dynamic> p, ProfileBackup source) {
    final backup = ProfileBackup.fromBytes(source.toBytes());
    final receipts = PrivateProfile.table(p, 'merge_receipts');
    final digestPayload = backup.toJson()..remove('created_at');
    final digest = fingerprint(digestPayload);
    final receiptKey = 'backup|${backup.backupId}';
    if (receipts[receiptKey] != null && receipts[receiptKey] != digest) {
      throw const FormatException('Mã sao lưu đã được dùng với nội dung khác.');
    }
    receipts[receiptKey] = digest;
    final counts = [0, 0, 0, 0];
    bool seen(String kind, String id) =>
        receipts.containsKey('${backup.backupId}|$kind|$id');
    void done(String kind, String id) =>
        receipts['${backup.backupId}|$kind|$id'] = true;
    for (final incoming in backup.privateLessons) {
      final id = incoming.lesson.id;
      if (seen('word', id)) {
        counts[2]++;
        continue;
      }
      final raw = PrivateProfile.table(p, 'private_lessons')[id];
      if (raw == null) {
        PrivateProfile.save(p, incoming.lesson, deleted: incoming.deleted);
        counts[0]++;
      } else {
        final old = PrivateLessonState.fromJson(raw as Map<String, dynamic>);
        if (samePrivatePayload(old, incoming)) {
          counts[2]++;
        } else {
          final next = old.toJson();
          next['conflict'] = PrivateLessonConflict(
            fromBackup: true,
            local: old,
            remote: PrivateLessonWireState(
              lesson: incoming.lesson,
              revision: old.revision,
              deleted: incoming.deleted,
              updatedAt: incoming.updatedAt,
            ),
          ).toJson();
          PrivateProfile.table(p, 'private_lessons')[id] = next;
          counts[3]++;
        }
      }
      done('word', id);
    }
    final pendingIds = PrivateProfile.table(p, 'queue').values
        .where((r) => r['mutation_type'] == 'review')
        .map((r) => PrivateProfile.payload(r)['item_id'] as String)
        .toSet();
    final importCards = <Map<String, dynamic>>[];
    final importCompleted = <Map<String, dynamic>>[];
    for (final card in backup.cards) {
      if (seen('card', card.itemId)) {
        counts[2]++;
        continue;
      }
      final raw = PrivateProfile.table(p, 'cards')[card.itemId];
      final old = raw == null
          ? null
          : FSRSCard.fromJson(raw as Map<String, dynamic>);
      if (!pendingIds.contains(card.itemId) &&
          (old == null || card.lastReview.isAfter(old.lastReview))) {
        PrivateProfile.table(p, 'cards')[card.itemId] = card.toJson();
        importCards.add(backupCardJson(card));
        counts[old == null ? 0 : 1]++;
      } else {
        counts[2]++;
      }
      done('card', card.itemId);
    }
    for (final completion in backup.completedLessons) {
      final id = completion.lessonId;
      if (seen('completion', id)) {
        counts[2]++;
        continue;
      }
      final raw = PrivateProfile.table(p, 'completions')[id];
      final old = raw == null
          ? null
          : LocalCompletedLesson.fromMap(raw as Map<String, dynamic>);
      if (!pendingIds.contains(id) &&
          (old == null || completion.completedAt.isAfter(old.completedAt))) {
        PrivateProfile.table(p, 'completions')[id] = {
          ...completion.toMap(),
          'synced': 1,
        };
        importCompleted.add(completion.toMap()..remove('synced'));
        counts[old == null ? 0 : 1]++;
      } else {
        counts[2]++;
      }
      done('completion', id);
    }
    for (final log in backup.reviewLogs) {
      final raw = PrivateProfile.table(p, 'logs')[log.id];
      if (raw != null) {
        final old = Map<String, dynamic>.from(raw as Map)..remove('synced');
        final next = log.toMap()..remove('synced');
        if (fingerprint(old) != fingerprint(next)) {
          throw const FormatException(
            'Mã lịch sử ôn trùng nhưng nội dung khác nhau.',
          );
        }
        counts[2]++;
      } else {
        PrivateProfile.table(p, 'logs')[log.id] = {...log.toMap(), 'synced': 1};
        counts[0]++;
      }
      done('log', log.id);
    }
    // Daily counts are snapshots, not deltas. Max is idempotent across overlapping backups.
    for (final e in backup.dailyActivity.entries) {
      final activity = PrivateProfile.table(p, 'activity');
      activity[e.key] = max(activity[e.key] as int? ?? 0, e.value);
      done('activity', e.key);
    }
    if (PrivateProfile.linked(p)) {
      // One entity per chunk bounds imports and gives each a destination-scoped identity.
      for (final c in importCards) {
        PrivateProfile.enqueue(p, 'progress_import', {
          'mutation_id': privateMutationId('import_'),
          'cards': [c],
          'completed_lessons': <dynamic>[],
        });
      }
      for (final c in importCompleted) {
        PrivateProfile.enqueue(p, 'progress_import', {
          'mutation_id': privateMutationId('import_'),
          'cards': <dynamic>[],
          'completed_lessons': [c],
        });
      }
    }
    return counts;
  }
}
