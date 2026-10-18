import 'dart:convert';
import 'dart:math';
import 'lesson_item.dart';

String privateMutationId([String prefix = 'mut_']) {
  final random = Random.secure();
  return '$prefix${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

String newPrivateLessonId(String language) {
  if (!['en', 'ja'].contains(language)) throw ArgumentError.value(language);
  return privateMutationId('custom_${language}_');
}

LessonItem privateLessonFromJson(Map<String, dynamic> json) {
  const strings = [
    'id',
    'language',
    'category',
    'target_text',
    'phonetic_or_kana',
    'meaning_vi',
    'workplace_context',
    'workplace_context_vi',
  ];
  if (strings.any((k) => json[k] is! String) ||
      json['difficulty_level'] is! int ||
      json['stroke_order_hints'] is! List ||
      (json['stroke_order_hints'] as List).any((h) => h is! String)) {
    throw const FormatException('Nội dung từ cá nhân không hợp lệ.');
  }
  return LessonItem.fromJson(json);
}

class PrivateLessonWireState {
  final LessonItem lesson;
  final int revision;
  final bool deleted;
  final DateTime updatedAt;
  const PrivateLessonWireState({
    required this.lesson,
    required this.revision,
    required this.deleted,
    required this.updatedAt,
  });
  factory PrivateLessonWireState.fromJson(Map<String, dynamic> json) =>
      PrivateLessonWireState(
        lesson: privateLessonFromJson(json['lesson'] as Map<String, dynamic>),
        revision: json['revision'] as int,
        deleted: json['deleted'] as bool,
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
      );
  Map<String, dynamic> toJson() => {
    'lesson': lesson.toJson(),
    'revision': revision,
    'deleted': deleted,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class PrivateLessonConflict {
  final PrivateLessonWireState local;
  final PrivateLessonWireState? remote;
  final bool fromBackup;
  const PrivateLessonConflict({
    required this.local,
    required this.remote,
    this.fromBackup = false,
  });
  factory PrivateLessonConflict.fromJson(Map<String, dynamic> json) =>
      PrivateLessonConflict(
        fromBackup: json['from_backup'] == true,
        local: PrivateLessonWireState.fromJson(
          json['local'] as Map<String, dynamic>,
        ),
        remote: json['remote'] == null
            ? null
            : PrivateLessonWireState.fromJson(
                json['remote'] as Map<String, dynamic>,
              ),
      );
  Map<String, dynamic> toJson() => {
    'local': local.toJson(),
    'remote': remote?.toJson(),
    'from_backup': fromBackup,
  };
}

class PrivateLessonState extends PrivateLessonWireState {
  final int localVersion;
  final bool pending;
  final PrivateLessonConflict? conflict;
  const PrivateLessonState({
    required super.lesson,
    required super.revision,
    required super.deleted,
    required super.updatedAt,
    required this.localVersion,
    required this.pending,
    this.conflict,
  });
  factory PrivateLessonState.fromJson(Map<String, dynamic> json) =>
      PrivateLessonState(
        lesson: privateLessonFromJson(json['lesson'] as Map<String, dynamic>),
        revision: json['revision'] as int,
        deleted: json['deleted'] as bool,
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
        localVersion: json['local_version'] as int? ?? 0,
        pending: json['pending'] as bool? ?? false,
        conflict: json['conflict'] == null
            ? null
            : PrivateLessonConflict.fromJson(
                json['conflict'] as Map<String, dynamic>,
              ),
      );
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'local_version': localVersion,
    'pending': pending,
    'conflict': conflict?.toJson(),
  };
}

class PrivateLessonAck {
  final String mutationId;
  final PrivateLessonWireState state;
  const PrivateLessonAck({required this.mutationId, required this.state});
  factory PrivateLessonAck.fromJson(Map<String, dynamic> json) =>
      PrivateLessonAck(
        mutationId: json['mutation_id'] as String,
        state: PrivateLessonWireState.fromJson(
          json['state'] as Map<String, dynamic>,
        ),
      );
}

class PrivateLessonSyncConflict {
  final String mutationId;
  final PrivateLessonWireState? server;
  const PrivateLessonSyncConflict({
    required this.mutationId,
    required this.server,
  });
  factory PrivateLessonSyncConflict.fromJson(Map<String, dynamic> json) =>
      PrivateLessonSyncConflict(
        mutationId: json['mutation_id'] as String,
        server: json['server'] == null
            ? null
            : PrivateLessonWireState.fromJson(
                json['server'] as Map<String, dynamic>,
              ),
      );
}

bool samePrivatePayload(PrivateLessonWireState a, PrivateLessonWireState b) =>
    a.deleted == b.deleted &&
    jsonEncode(a.lesson.toJson()) == jsonEncode(b.lesson.toJson());
