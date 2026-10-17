import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../models/lesson_item.dart';
import '../../models/public_lesson_ids.dart';
import '../../models/private_lesson_state.dart';

/// Pure state transitions shared by the SQLite transaction and browser snapshot.
class PrivateProfile {
  static Map<String, dynamic> table(Map<String, dynamic> p, String name) =>
      (p.putIfAbsent(name, () => <String, dynamic>{}) as Map<String, dynamic>);
  static Map<String, dynamic> clone(Map<String, dynamic> p) =>
      jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
  static Map<String, dynamic> payload(dynamic row) =>
      jsonDecode((row as Map)['payload'] as String) as Map<String, dynamic>;
  static bool linked(Map<String, dynamic> p) =>
      table(p, 'metadata')['account'] != null;
  static int enqueue(
    Map<String, dynamic> p,
    String kind,
    Map<String, dynamic> data,
  ) {
    final queue = table(p, 'queue');
    final id =
        p['next_queue_id'] as int? ??
        (queue.keys.map(int.parse).fold(0, (a, b) => a > b ? a : b) + 1);
    p['next_queue_id'] = id + 1;
    queue['$id'] = {
      'id': id,
      'mutation_type': kind,
      'payload': jsonEncode(data),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'retry_count': 0,
      'status': 'pending',
    };
    return id;
  }

  static void validateLesson(LessonItem lesson) {
    if (publicLessonIds.contains(lesson.id) ||
        lesson.category != 'custom' ||
        !['en', 'ja'].contains(lesson.language) ||
        !RegExp(r'^[\x01-\x7f]{1,64}$').hasMatch(lesson.id) ||
        lesson.targetText.trim().isEmpty ||
        lesson.meaningVi.trim().isEmpty ||
        lesson.difficultyLevel < 1 ||
        lesson.difficultyLevel > 5) {
      throw const FormatException('Từ cá nhân không hợp lệ.');
    }
    for (final s in [
      lesson.targetText,
      lesson.phoneticOrKana,
      lesson.meaningVi,
      lesson.workplaceContext,
      lesson.workplaceContextVi,
      ...lesson.strokeOrderHints,
    ]) {
      if (s.contains('\u0000') || utf8.encode(s).length > 16384) {
        throw const FormatException('Nội dung từ vượt giới hạn.');
      }
    }
    if (lesson.strokeOrderHints.length > 64) {
      throw const FormatException('Quá nhiều hướng dẫn.');
    }
  }

  static void migrate(Map<String, dynamic> p, {required bool account}) {
    final lessons = table(p, 'lessons');
    final aliases = table(p, 'aliases');
    for (final row in lessons.values.toList()) {
      final lesson = LessonItem.fromJson(Map<String, dynamic>.from(row as Map));
      if (publicLessonIds.contains(lesson.id) ||
          lesson.category != 'custom' ||
          !['en', 'ja'].contains(lesson.language)) {
        continue;
      }
      var id = lesson.id;
      if (id.length > 64) {
        final canonical =
            'custom_${lesson.language}_${sha256.convert(utf8.encode(id)).toString().substring(0, 32)}';
        if (lessons.containsKey(canonical)) {
          throw const FormatException('Xung đột mã từ khi nâng cấp.');
        }
        aliases[id] = canonical;
        final copy = {...lesson.toJson(), 'id': canonical};
        lessons.remove(id);
        lessons[canonical] = copy;
        for (final name in ['cards', 'completions']) {
          final t = table(p, name);
          final r = t.remove(id);
          if (r != null) {
            if (t.containsKey(canonical)) {
              throw const FormatException('Xung đột tiến độ khi nâng cấp.');
            }
            (r as Map)[name == 'cards' ? 'itemId' : 'lesson_id'] = canonical;
            t[canonical] = r;
          }
        }
        for (final log in table(p, 'logs').values) {
          if ((log as Map)['item_id'] == id) log['item_id'] = canonical;
        }
        for (final q in table(p, 'queue').values) {
          final data = payload(q);
          _remap(data, id, canonical);
          (q as Map)['payload'] = jsonEncode(data);
        }
        id = canonical;
      }
      final states = table(p, 'private_lessons');
      if (states.containsKey(id)) continue;
      final state = PrivateLessonState(
        lesson: LessonItem.fromJson(
          Map<String, dynamic>.from(lessons[id] as Map),
        ),
        revision: 0,
        deleted: false,
        updatedAt: DateTime.now().toUtc(),
        localVersion: 1,
        pending: account,
      );
      states[id] = state.toJson();
      if (account) _queueWord(p, state);
    }
    table(p, 'private_lessons');
    table(p, 'merge_receipts');
  }

  static void _remap(dynamic value, String old, String next) {
    if (value is Map) {
      for (final key in value.keys.toList()) {
        if (key == 'lesson' && value[key] is Map && value[key]['id'] == old) {
          value[key]['id'] = next;
        }
        if (['item_id', 'itemId', 'lesson_id'].contains(key) &&
            value[key] == old) {
          value[key] = next;
        } else {
          _remap(value[key], old, next);
        }
      }
    } else if (value is List) {
      for (final v in value) {
        _remap(v, old, next);
      }
    }
  }

  static void _queueWord(Map<String, dynamic> p, PrivateLessonState state) {
    final queue = table(p, 'queue');
    queue.removeWhere(
      (_, r) =>
          r['mutation_type'] == 'custom_lesson' &&
          r['status'] == 'pending' &&
          r['retry_count'] == 0 &&
          r['sent'] != true &&
          r['sent'] != 1 &&
          (payload(r)['lesson'] as Map)['id'] == state.lesson.id,
    );
    enqueue(p, 'custom_lesson', {
      'mutation_id': privateMutationId(),
      'base_revision': state.revision,
      'lesson': state.lesson.toJson(),
      'deleted': state.deleted,
      'local_version': state.localVersion,
    });
  }

  static PrivateLessonState save(
    Map<String, dynamic> p,
    LessonItem lesson, {
    bool deleted = false,
  }) {
    validateLesson(lesson);
    final existing = table(p, 'lessons')[lesson.id];
    if (existing != null && existing['category'] != 'custom') {
      throw const FormatException('Giáo trình có sẵn chỉ được đọc.');
    }
    final raw = table(p, 'private_lessons')[lesson.id];
    final old = raw == null
        ? null
        : PrivateLessonState.fromJson(raw as Map<String, dynamic>);
    final state = PrivateLessonState(
      lesson: lesson,
      revision: old?.revision ?? 0,
      deleted: deleted,
      updatedAt: DateTime.now().toUtc(),
      localVersion: (old?.localVersion ?? 0) + 1,
      pending: linked(p),
      conflict: old?.conflict == null
          ? null
          : PrivateLessonConflict(
              local: PrivateLessonWireState(
                lesson: lesson,
                revision: old!.revision,
                deleted: deleted,
                updatedAt: DateTime.now().toUtc(),
              ),
              remote: old.conflict!.remote,
              fromBackup: old.conflict!.fromBackup,
            ),
    );
    table(p, 'private_lessons')[lesson.id] = state.toJson();
    table(p, 'lessons')[lesson.id] = lesson.toJson();
    if (linked(p) && state.conflict == null) _queueWord(p, state);
    return state;
  }

  static void resolve(Map<String, dynamic> p, String id, bool keepLocal) {
    final raw = table(p, 'private_lessons')[id];
    if (raw == null) throw StateError('Không tìm thấy từ.');
    final old = PrivateLessonState.fromJson(raw as Map<String, dynamic>);
    final conflict = old.conflict;
    if (conflict == null) return;
    final queue = table(p, 'queue');
    queue.removeWhere(
      (_, q) =>
          q['mutation_type'] == 'custom_lesson' &&
          (payload(q)['lesson'] as Map)['id'] == id,
    );
    final remote = conflict.remote;
    if (keepLocal) {
      table(p, 'private_lessons')[id] = PrivateLessonState(
        lesson: old.lesson,
        revision: conflict.fromBackup ? old.revision : remote?.revision ?? 0,
        deleted: old.deleted,
        updatedAt: old.updatedAt,
        localVersion: old.localVersion,
        pending: linked(p),
      ).toJson();
      save(p, old.lesson, deleted: old.deleted);
    } else if (remote != null) {
      if (conflict.fromBackup) {
        table(p, 'private_lessons')[id] = PrivateLessonState(
          lesson: old.lesson,
          revision: old.revision,
          deleted: old.deleted,
          updatedAt: old.updatedAt,
          localVersion: old.localVersion,
          pending: linked(p),
        ).toJson();
        save(p, remote.lesson, deleted: remote.deleted);
      } else {
        _apply(p, remote, old.localVersion + 1);
      }
    } else {
      table(p, 'private_lessons')[id] = PrivateLessonState(
        lesson: old.lesson,
        revision: 0,
        deleted: true,
        updatedAt: DateTime.now().toUtc(),
        localVersion: old.localVersion + 1,
        pending: false,
      ).toJson();
    }
  }

  static void _apply(
    Map<String, dynamic> p,
    PrivateLessonWireState wire,
    int localVersion,
  ) {
    table(p, 'private_lessons')[wire.lesson.id] = PrivateLessonState(
      lesson: wire.lesson,
      revision: wire.revision,
      deleted: wire.deleted,
      updatedAt: wire.updatedAt,
      localVersion: localVersion,
      pending: false,
    ).toJson();
    table(p, 'lessons')[wire.lesson.id] = wire.lesson.toJson();
  }

  static void sync(
    Map<String, dynamic> p, {
    List<PrivateLessonAck> acks = const [],
    List<PrivateLessonSyncConflict> conflicts = const [],
    List<PrivateLessonWireState> deltas = const [],
    List<String> progressImportAcks = const [],
  }) {
    final queue = table(p, 'queue');
    final states = table(p, 'private_lessons');
    for (final ack in acks) {
      final matches = queue.entries
          .where(
            (e) =>
                e.value['mutation_type'] == 'custom_lesson' &&
                payload(e.value)['mutation_id'] == ack.mutationId,
          )
          .toList();
      if (matches.isEmpty) continue;
      final q = matches.single;
      final sent = payload(q.value);
      final id = ack.state.lesson.id;
      if ((sent['lesson'] as Map)['id'] != id) {
        throw const FormatException('Phản hồi từ không đúng.');
      }
      validateLesson(ack.state.lesson);
      if (ack.state.revision < 1) {
        throw const FormatException('Phản hồi phiên bản từ không hợp lệ.');
      }
      final old = PrivateLessonState.fromJson(
        states[id] as Map<String, dynamic>,
      );
      queue.remove(q.key);
      if (old.localVersion == sent['local_version'] &&
          old.conflict == null &&
          ack.state.revision >= old.revision) {
        _apply(p, ack.state, old.localVersion);
      } else {
        final updated = old.toJson();
        updated['revision'] = ack.state.revision > old.revision
            ? ack.state.revision
            : old.revision;
        states[id] = updated;
        for (final r in queue.values) {
          if (r['mutation_type'] == 'custom_lesson') {
            final data = payload(r);
            if ((data['lesson'] as Map)['id'] == id &&
                r['sent'] != true &&
                r['sent'] != 1) {
              data['base_revision'] = updated['revision'];
              r['payload'] = jsonEncode(data);
            }
          }
        }
      }
    }
    for (final c in conflicts) {
      final matches = queue.values
          .where(
            (r) =>
                r['mutation_type'] == 'custom_lesson' &&
                payload(r)['mutation_id'] == c.mutationId,
          )
          .toList();
      if (matches.isEmpty) continue;
      final id = (payload(matches.first)['lesson'] as Map)['id'] as String;
      if (c.server != null) {
        validateLesson(c.server!.lesson);
        if (c.server!.lesson.id != id || c.server!.revision < 1) {
          throw const FormatException('Phản hồi xung đột từ không hợp lệ.');
        }
      }
      final old = PrivateLessonState.fromJson(
        states[id] as Map<String, dynamic>,
      );
      final next = old.toJson();
      next['conflict'] = PrivateLessonConflict(
        local: old,
        remote: c.server,
      ).toJson();
      states[id] = next;
    }
    for (final wire in deltas) {
      validateLesson(wire.lesson);
      if (wire.revision < 1) {
        throw const FormatException('Phiên bản từ không hợp lệ.');
      }
      final raw = states[wire.lesson.id];
      final old = raw == null
          ? null
          : PrivateLessonState.fromJson(raw as Map<String, dynamic>);
      if (old == null) {
        _apply(p, wire, 0);
        continue;
      }
      if (wire.revision < old.revision) continue;
      if (old.conflict?.fromBackup == true) {
        final next = old.toJson();
        next['revision'] = wire.revision > old.revision
            ? wire.revision
            : old.revision;
        states[wire.lesson.id] = next;
      } else if (old.conflict != null) {
        if (wire.revision >= (old.conflict!.remote?.revision ?? 0)) {
          final next = old.toJson();
          next['conflict'] = PrivateLessonConflict(
            local: old.conflict!.local,
            remote: wire,
          ).toJson();
          states[wire.lesson.id] = next;
        }
      } else if (!old.pending) {
        _apply(p, wire, old.localVersion);
      } else if (wire.revision > old.revision &&
          !samePrivatePayload(old, wire)) {
        final next = old.toJson();
        next['conflict'] = PrivateLessonConflict(
          local: old,
          remote: wire,
        ).toJson();
        states[wire.lesson.id] = next;
      }
    }
    queue.removeWhere(
      (_, r) =>
          r['mutation_type'] == 'progress_import' &&
          progressImportAcks.contains(payload(r)['mutation_id']),
    );
  }
}
