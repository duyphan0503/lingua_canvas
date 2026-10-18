import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../../models/lesson_item.dart';
import '../fsrs_engine.dart';
import 'local_models.dart';
import 'local_store.dart';
import 'snapshot_persistence.dart';
import 'private_store.dart';
import 'private_profile.dart';

/// Domain operations over JSON-safe state. A durable commit precedes publication.
class BrowserLocalStore with PrivateStore implements LocalStore {
  final SnapshotPersistence persistence;
  final String initialBackend;
  Map<String, dynamic>? _state;
  Future<void>? _opening;
  Future<void>? _mutations;
  Future<void>? _profiles;
  BrowserLocalStore({
    required this.persistence,
    this.initialBackend = 'http://127.0.0.1:8080/api/v1',
  });

  static String _id(String prefix) {
    final r = Random.secure();
    return '$prefix${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> map) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(map)) as Map);
  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  Map<String, dynamic> _newRoot() => {
    'version': 2,
    'generation': 0,
    'client_id': _id('client_'),
    'active_backend': initialBackend,
    'active_profiles': <String, dynamic>{},
    'profiles': <String, dynamic>{},
  };
  static Map<String, dynamic> _emptyProfile() => {
    'metadata': <String, dynamic>{},
    'lessons': <String, dynamic>{},
    'cards': <String, dynamic>{},
    'logs': <String, dynamic>{},
    'queue': <String, dynamic>{},
    'completions': <String, dynamic>{},
    'activity': <String, dynamic>{},
    'next_queue_id': 1,
    'private_lessons': <String, dynamic>{},
    'aliases': <String, dynamic>{},
    'merge_receipts': <String, dynamic>{},
  };
  static Map<String, dynamic> _profile(Map<String, dynamic> root) {
    final backend = root['active_backend'] as String;
    final active = root['active_profiles'] as Map<String, dynamic>;
    final user = active[backend] as String? ?? 'default_user';
    final key = jsonEncode([backend, user]);
    final profiles = root['profiles'] as Map<String, dynamic>;
    return profiles.putIfAbsent(key, _emptyProfile) as Map<String, dynamic>;
  }

  static Map<String, dynamic> _table(Map<String, dynamic> root, String table) =>
      _profile(root)[table] as Map<String, dynamic>;
  @override
  Future<void> initialize() => _opening ??= _open();
  Future<void> _open() async {
    try {
      final loaded = await persistence.load();
      if (loaded == null) {
        final fresh = _newRoot();
        _profile(fresh);
        await persistence.save(fresh);
        _state = fresh;
        return;
      }
      if (![1, 2].contains(loaded['version']) ||
          loaded['client_id'] is! String ||
          loaded['active_backend'] is! String ||
          loaded['active_profiles'] is! Map ||
          loaded['profiles'] is! Map) {
        throw const BrowserStorageException(
          'corrupt',
          'Dữ liệu trình duyệt không đúng phiên bản. Chưa thay đổi dữ liệu.',
        );
      }
      for (final profile in (loaded['profiles'] as Map).values) {
        if (profile is! Map ||
            profile['next_queue_id'] is! int ||
            [
              'metadata',
              'lessons',
              'cards',
              'logs',
              'queue',
              'completions',
              'activity',
            ].any((t) => profile[t] is! Map) ||
            (loaded['version'] == 2 &&
                [
                  'private_lessons',
                  'aliases',
                  'merge_receipts',
                ].any((t) => profile[t] is! Map))) {
          throw const BrowserStorageException(
            'corrupt',
            'Hồ sơ trình duyệt bị lỗi. Chưa thay đổi dữ liệu.',
          );
        }
      }
      final candidate = _copy(loaded);
      if (candidate['version'] == 1) {
        for (final entry in (candidate['profiles'] as Map).entries) {
          final identity = jsonDecode(entry.key as String) as List;
          PrivateProfile.migrate(
            entry.value as Map<String, dynamic>,
            account: identity[1] != 'default_user',
          );
        }
        candidate['version'] = 2;
        candidate['generation'] = 0;
        await persistence.save(candidate);
      }
      _state = candidate;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<T> _edit<T>(T Function(Map<String, dynamic>) change) async {
    await initialize();
    final next = (_mutations ?? Future<void>.value()).then((_) async {
      final candidate = _copy(_state!);
      final result = change(candidate);
      await persistence.save(candidate);
      _state = candidate;
      return result;
    });
    _mutations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Map<String, dynamic>> _read(String table) async {
    await initialize();
    await _mutations;
    return _copy(_table(_state!, table));
  }

  @override
  Future<T> withProfileLock<T>(Future<T> Function() operation) {
    final next = (_profiles ?? Future<void>.value()).then((_) => operation());
    _profiles = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<String> getActiveBackend() async {
    await initialize();
    await _mutations;
    return _state!['active_backend'] as String;
  }

  @override
  Future<T> editPrivateProfile<T>(T Function(Map<String, dynamic>) change) =>
      _edit((root) {
        final p = _profile(root);
        p['_binding'] = jsonEncode([
          root['active_backend'],
          (root['active_profiles'] as Map)[root['active_backend']] ??
              'default_user',
          root['generation'] ?? 0,
        ]);
        final result = change(p);
        p.remove('_binding');
        return result;
      });
  @override
  Future<Map<String, dynamic>> readPrivateProfile() async {
    await initialize();
    await _mutations;
    final p = _copy(_profile(_state!));
    p['_binding'] = jsonEncode([
      _state!['active_backend'],
      (_state!['active_profiles'] as Map)[_state!['active_backend']] ??
          'default_user',
      _state!['generation'] ?? 0,
    ]);
    return p;
  }

  @override
  Future<Map<String, dynamic>> readGuestProfile() async {
    await initialize();
    await _mutations;
    final key = jsonEncode([_state!['active_backend'], 'default_user']);
    return _copy(
      (_state!['profiles'] as Map)[key] as Map<String, dynamic>? ??
          _emptyProfile(),
    );
  }

  @override
  Future<void> selectBackend(String baseUrl) => _edit((root) {
    root['generation'] = (root['generation'] as int? ?? 0) + 1;
    root['active_backend'] = baseUrl;
    _profile(root);
  });
  @override
  Future<void> saveLessons(List<LessonItem> lessons) => _edit((root) {
    final table = _table(root, 'lessons');
    for (final lesson in lessons) {
      if (_table(root, 'private_lessons').containsKey(lesson.id)) continue;
      final old = table[lesson.id] as Map?;
      if (lesson.language == 'custom' &&
          old != null &&
          ['ja', 'en'].contains(old['language'])) {
        continue;
      }
      table[lesson.id] = lesson.toJson();
    }
  });
  @override
  Future<void> saveLesson(LessonItem lesson) => saveLessons([lesson]);
  @override
  Future<List<LessonItem>> getLessons({
    String? language,
    String? category,
  }) async {
    final rows = await _read('lessons');
    final keys = rows.keys.toList()..sort();
    return [
          for (final k in keys)
            LessonItem.fromJson(rows[k] as Map<String, dynamic>),
        ]
        .where(
          (l) =>
              (language == null || l.language == language) &&
              (category == null || l.category == category) &&
              !(PrivateProfile.table(
                    _profile(_state!),
                    'private_lessons',
                  )[l.id]?['deleted'] ==
                  true),
        )
        .toList();
  }

  @override
  Future<LessonItem?> getLesson(String id) async {
    final row = (await _read('lessons'))[id];
    if ((await _read('private_lessons'))[id]?['deleted'] == true) return null;
    return row == null
        ? null
        : LessonItem.fromJson(row as Map<String, dynamic>);
  }

  @override
  Future<void> saveCard(FSRSCard card) => _edit((root) {
    _table(root, 'cards')[card.itemId] = card.toJson();
  });
  @override
  Future<FSRSCard?> getCard(String itemId) async {
    final row = (await _read('cards'))[itemId];
    return row == null ? null : FSRSCard.fromJson(row as Map<String, dynamic>);
  }

  @override
  Future<List<FSRSCard>> getAllCards() async {
    final rows = await _read('cards');
    final keys = rows.keys.toList()..sort();
    return [
      for (final k in keys) FSRSCard.fromJson(rows[k] as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<String>> getDueCardIds(DateTime asOf) async {
    final cards =
        (await getAllCards()).where((c) => !c.nextReview.isAfter(asOf)).toList()
          ..sort((a, b) => a.nextReview.compareTo(b.nextReview));
    final states = await _read('private_lessons');
    return cards
        .where((c) => states[c.itemId]?['deleted'] != true)
        .map((c) => c.itemId)
        .toList();
  }

  @override
  Future<void> insertReviewLog(LocalReviewLog log) => _edit((root) {
    _table(root, 'logs')[log.id] = log.toMap();
  });
  @override
  Future<List<LocalReviewLog>> getReviewLogs({int? synced, int? limit}) async {
    final rows =
        (await _read('logs')).values
            .map((r) => LocalReviewLog.fromMap(r as Map<String, dynamic>))
            .where((r) => synced == null || r.synced == synced)
            .toList()
          ..sort((a, b) => b.reviewTime.compareTo(a.reviewTime));
    return limit != null && limit >= 0 ? rows.take(limit).toList() : rows;
  }

  @override
  Future<void> markReviewLogsSynced(List<String> ids) => _edit((root) {
    final rows = _table(root, 'logs');
    for (final id in ids) {
      if (rows[id] != null) {
        (rows[id] as Map)['synced'] = 1;
      }
    }
  });
  static int _enqueue(
    Map<String, dynamic> root, {
    required String mutationType,
    required Map<String, dynamic> payload,
    required DateTime createdAt,
  }) {
    final profile = _profile(root);
    final id = profile['next_queue_id'] as int;
    profile['next_queue_id'] = id + 1;
    _table(root, 'queue')['$id'] = {
      'id': id,
      'mutation_type': mutationType,
      'payload': jsonEncode(payload),
      'created_at': createdAt.toIso8601String(),
      'retry_count': 0,
      'status': 'pending',
    };
    return id;
  }

  @override
  Future<int> enqueueMutation({
    required String mutationType,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
  }) => _edit(
    (root) => _enqueue(
      root,
      mutationType: mutationType,
      payload: payload,
      createdAt: createdAt ?? DateTime.now().toUtc(),
    ),
  );
  @override
  Future<List<SyncQueueItem>> getPendingMutations({int? limit}) async {
    final rows =
        (await _read('queue')).values
            .map((r) => SyncQueueItem.fromMap(r as Map<String, dynamic>))
            .where((r) => r.status == 'pending')
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return limit != null && limit >= 0 ? rows.take(limit).toList() : rows;
  }

  @override
  Future<void> recoverInterruptedMutations() => _edit((root) {
    for (final row in _table(root, 'queue').values) {
      if ((row as Map)['status'] == 'in_progress') {
        row['status'] = 'pending';
      }
    }
  });
  @override
  Future<String?> getMetadata(String key) async =>
      (await _read('metadata'))[key] as String?;
  @override
  Future<void> setMetadata(String key, String value) => _edit((root) {
    _table(root, 'metadata')[key] = value;
  });
  @override
  Future<Map<String, dynamic>?> getAccount() async {
    final raw = await getMetadata('account');
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  @override
  Future<int?> getSyncSequence() async =>
      int.tryParse(await getMetadata('latest_sync_seq') ?? '');
  @override
  Future<void> setSyncSequence(int sequence) async {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    await setMetadata('latest_sync_seq', '$sequence');
  }

  @override
  Future<void> switchAccount(Map<String, dynamic>? account) => _edit((root) {
    final backend = root['active_backend'] as String;
    if (account != null &&
        (account['server_url'] != backend ||
            account['user_id'] is! String ||
            account.containsKey('pin'))) {
      throw const BrowserStorageException(
        'identity',
        'Hồ sơ thuộc máy chủ khác. Hãy liên kết lại tài khoản.',
      );
    }
    root['generation'] = (root['generation'] as int? ?? 0) + 1;
    (root['active_profiles'] as Map)[backend] =
        account?['user_id'] ?? 'default_user';
    final metadata = _table(root, 'metadata');
    if (account == null) {
      metadata.remove('account');
    } else {
      metadata['account'] = jsonEncode(account);
    }
  });
  @override
  Future<DateTime?> getLastPullTime() async {
    final raw = await getMetadata('last_pull_time');
    return raw == null ? null : DateTime.parse(raw);
  }

  @override
  Future<String> getOrCreateClientId() async {
    await initialize();
    return _state!['client_id'] as String;
  }

  @override
  Future<void> setLastPullTime(DateTime time) =>
      setMetadata('last_pull_time', time.toUtc().toIso8601String());
  @override
  Future<void> markMutationsInProgress(List<int> ids) => _edit((root) {
    final rows = _table(root, 'queue');
    for (final id in ids) {
      if (rows['$id'] != null) {
        (rows['$id'] as Map)['status'] = 'in_progress';
        // A retried mutation keeps its identity and payload forever.
        (rows['$id'] as Map)['sent'] = true;
      }
    }
  });
  @override
  Future<void> deleteMutations(List<int> ids) => _edit((root) {
    final rows = _table(root, 'queue');
    for (final id in ids) {
      rows.remove('$id');
    }
  });
  @override
  Future<void> resetFailedMutations(List<int> ids) => _edit((root) {
    final rows = _table(root, 'queue');
    for (final id in ids) {
      final row = rows['$id'] as Map?;
      if (row != null) {
        row['status'] = 'pending';
        row['retry_count'] = (row['retry_count'] as int) + 1;
      }
    }
  });
  @override
  Future<void> saveCompletedLesson(
    String lessonId, {
    DateTime? completedAt,
    double score = 1,
    int synced = 0,
  }) => _edit((root) {
    _table(root, 'completions')[lessonId] = {
      'lesson_id': lessonId,
      'completed_at': (completedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'score': score,
      'synced': synced,
    };
  });
  @override
  Future<List<LocalCompletedLesson>> getCompletedLessons({int? synced}) async {
    final rows =
        (await _read('completions')).values
            .map((r) => LocalCompletedLesson.fromMap(r as Map<String, dynamic>))
            .where((r) => synced == null || r.synced == synced)
            .toList()
          ..sort((a, b) => a.completedAt.compareTo(b.completedAt));
    return rows;
  }

  @override
  Future<int> getCompletedCount() async => (await _read('completions')).length;
  @override
  Future<void> markCompletedLessonsSynced(List<String> lessonIds) =>
      _edit((root) {
        final rows = _table(root, 'completions');
        for (final id in lessonIds) {
          if (rows[id] != null) {
            (rows[id] as Map)['synced'] = 1;
          }
        }
      });
  @override
  Future<String> recordReviewTransaction({
    required FSRSCard updatedCard,
    required FSRSRating rating,
    required DateTime reviewTime,
    required double elapsedDays,
    required int scheduledDays,
    double completionScore = 1,
  }) => _edit((root) {
    final id = _id('rev_');
    _table(root, 'cards')[updatedCard.itemId] = updatedCard.toJson();
    _table(root, 'logs')[id] = LocalReviewLog(
      id: id,
      itemId: updatedCard.itemId,
      rating: rating.index + 1,
      state: updatedCard.state.index,
      reviewTime: reviewTime,
      elapsedDays: elapsedDays,
      scheduledDays: scheduledDays,
    ).toMap();
    _table(root, 'completions')[updatedCard.itemId] = {
      'lesson_id': updatedCard.itemId,
      'completed_at': reviewTime.toIso8601String(),
      'score': completionScore,
      'synced': 0,
    };
    _enqueue(
      root,
      mutationType: 'review',
      createdAt: reviewTime,
      payload: {
        'review_id': id,
        'item_id': updatedCard.itemId,
        'rating': rating.index + 1,
        'state': updatedCard.state.index,
        'review_time': reviewTime.toIso8601String(),
        'elapsed_days': elapsedDays,
        'scheduled_days': scheduledDays,
        'completion_score': completionScore,
        'client_card_snapshot': {
          'stability': updatedCard.stability,
          'difficulty': updatedCard.difficulty,
          'reps': updatedCard.reps,
          'lapses': updatedCard.lapses,
          'last_review': updatedCard.lastReview.toIso8601String(),
          'next_review': updatedCard.nextReview.toIso8601String(),
        },
      },
    );
    final key = _date(reviewTime.toLocal());
    final activity = _table(root, 'activity');
    activity[key] = (activity[key] as int? ?? 0) + 1;
    return id;
  });
  @override
  Future<void> logDailyActivity(DateTime date, int itemsCount) => _edit((root) {
    final key = _date(date.toLocal());
    final rows = _table(root, 'activity');
    rows[key] = (rows[key] as int? ?? 0) + itemsCount;
  });
  @override
  Future<StudyStreak> getStudyStreak({DateTime? asOf}) async {
    final all = Map<String, int>.from(await _read('activity'));
    final counts = <String, int>{};
    for (final log in await getReviewLogs()) {
      final day = _date(log.reviewTime.toLocal());
      counts[day] = (counts[day] ?? 0) + 1;
    }
    for (final entry in counts.entries) {
      all[entry.key] = max(all[entry.key] ?? 0, entry.value);
    }
    final active = all.entries
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .toSet();
    final ref = (asOf ?? DateTime.now()).toLocal();
    final today = DateTime(ref.year, ref.month, ref.day);
    var offset = active.contains(_date(today)) ? 0 : 1;
    var current = 0;
    while (active.contains(
      _date(DateTime(today.year, today.month, today.day - offset)),
    )) {
      current++;
      offset++;
    }
    final dates = active.map(DateTime.parse).toList()..sort();
    var longest = 0;
    var run = 0;
    DateTime? previous;
    for (final d in dates) {
      run =
          previous != null &&
              DateTime(previous.year, previous.month, previous.day + 1) == d
          ? run + 1
          : 1;
      longest = max(longest, run);
      previous = d;
    }
    return StudyStreak(
      currentStreak: current,
      longestStreak: longest,
      activityHistory: {
        for (var i = 29; i >= 0; i--)
          _date(DateTime(today.year, today.month, today.day - i)):
              all[_date(DateTime(today.year, today.month, today.day - i))] ?? 0,
      },
    );
  }

  @override
  Future<void> clearCurrentProfile() => withProfileLock(
    () => _edit((root) {
      root['generation'] = (root['generation'] as int? ?? 0) + 1;
      final account = _table(root, 'metadata')['account'];
      final backend = root['active_backend'] as String;
      final user = (root['active_profiles'] as Map)[backend] ?? 'default_user';
      final fresh = _emptyProfile();
      if (account != null) {
        (fresh['metadata'] as Map)['account'] = account;
      }
      (root['profiles'] as Map)[jsonEncode([backend, user])] = fresh;
    }),
  );
  @override
  Future<void> clearAll() => withProfileLock(
    () => _edit((root) {
      final fresh = _newRoot();
      fresh['generation'] = (root['generation'] as int? ?? 0) + 1;
      root
        ..clear()
        ..addAll(fresh);
      _profile(root);
    }),
  );
  @override
  Future<void> close() async {
    await _profiles;
    await _mutations;
    await persistence.close();
    _state = null;
    _opening = null;
  }
}
