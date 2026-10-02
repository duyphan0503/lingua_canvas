import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/lesson_item.dart';
import 'fsrs_engine.dart';

String _randomId(String prefix) {
  final random = Random.secure();
  return '$prefix${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

class LocalReviewLog {
  final String id;
  final String itemId;
  final int rating;
  final int state;
  final DateTime reviewTime;
  final double elapsedDays;
  final int scheduledDays;
  final int synced;

  LocalReviewLog({
    required this.id,
    required this.itemId,
    required this.rating,
    required this.state,
    required this.reviewTime,
    required this.elapsedDays,
    required this.scheduledDays,
    this.synced = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'item_id': itemId,
      'rating': rating,
      'state': state,
      'review_time': reviewTime.toIso8601String(),
      'elapsed_days': elapsedDays,
      'scheduled_days': scheduledDays,
      'synced': synced,
    };
  }

  factory LocalReviewLog.fromMap(Map<String, dynamic> map) {
    return LocalReviewLog(
      id: map['id'] as String,
      itemId: map['item_id'] as String,
      rating: (map['rating'] as num).toInt(),
      state: (map['state'] as num).toInt(),
      reviewTime: DateTime.parse(map['review_time'] as String),
      elapsedDays: (map['elapsed_days'] as num?)?.toDouble() ?? 0.0,
      scheduledDays: (map['scheduled_days'] as num?)?.toInt() ?? 0,
      synced: (map['synced'] as num?)?.toInt() ?? 0,
    );
  }
}

class SyncQueueItem {
  final int id;
  final String mutationType;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int retryCount;
  final String status;

  SyncQueueItem({
    required this.id,
    required this.mutationType,
    required this.payload,
    required this.createdAt,
    this.retryCount = 0,
    this.status = 'pending',
  });

  factory SyncQueueItem.fromMap(Map<String, dynamic> map) {
    final payloadRaw = map['payload'] as String;
    Map<String, dynamic> parsedPayload;
    try {
      parsedPayload = jsonDecode(payloadRaw) as Map<String, dynamic>;
    } catch (_) {
      parsedPayload = {'raw': payloadRaw};
    }

    return SyncQueueItem(
      id: (map['id'] as num).toInt(),
      mutationType: map['mutation_type'] as String,
      payload: parsedPayload,
      createdAt: DateTime.parse(map['created_at'] as String),
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      status: map['status'] as String? ?? 'pending',
    );
  }
}

class LocalCompletedLesson {
  final String lessonId;
  final DateTime completedAt;
  final double score;
  final int synced;

  LocalCompletedLesson({
    required this.lessonId,
    required this.completedAt,
    this.score = 1.0,
    this.synced = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'lesson_id': lessonId,
      'completed_at': completedAt.toIso8601String(),
      'score': score,
      'synced': synced,
    };
  }

  factory LocalCompletedLesson.fromMap(Map<String, dynamic> map) {
    return LocalCompletedLesson(
      lessonId: map['lesson_id'] as String,
      completedAt: DateTime.parse(map['completed_at'] as String),
      score: (map['score'] as num?)?.toDouble() ?? 1.0,
      synced: (map['synced'] as num?)?.toInt() ?? 0,
    );
  }
}

class LocalDatabase {
  static LocalDatabase? _instance;
  static Database? _database;

  LocalDatabase._();

  static LocalDatabase get instance => _instance ??= LocalDatabase._();

  /// Initialize FFI factory for Linux / desktop and test environments
  static void initFfiIfNeeded() {
    if (!kIsWeb &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// Explicitly set or reset the database (useful for testing)
  static void setDatabaseForTesting(Database? db) {
    _database = db;
  }

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase({String? customPath}) async {
    initFfiIfNeeded();

    String path;
    if (customPath != null) {
      path = customPath;
    } else if (Platform.environment.containsKey('FLUTTER_TEST')) {
      path = inMemoryDatabasePath;
    } else {
      final dbPath = await getDatabasesPath();
      path = p.join(dbPath, 'lingua_canvas_local.db');
    }

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS local_sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        }
      },
    );
  }

  /// Initialize with a custom file or in-memory path (e.g. inMemoryDatabasePath)
  Future<void> initCustom({String? customPath, Database? customDb}) async {
    if (customDb != null) {
      _database = customDb;
      await _createTables(customDb);
      return;
    }
    _database = await _initDatabase(customPath: customPath);
  }

  Future<void> _createTables(Database db) async {
    final batch = db.batch();

    batch.execute(
      'CREATE TABLE IF NOT EXISTS local_sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );

    // 1. local_lessons
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_lessons (
        id TEXT PRIMARY KEY,
        language TEXT NOT NULL,
        category TEXT NOT NULL,
        target_text TEXT NOT NULL,
        phonetic_or_kana TEXT NOT NULL,
        meaning_vi TEXT NOT NULL,
        workplace_context TEXT NOT NULL,
        workplace_context_vi TEXT NOT NULL,
        stroke_order_hints TEXT NOT NULL,
        difficulty_level INTEGER NOT NULL DEFAULT 1,
        cached_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_lessons_lang_cat ON local_lessons(language, category);',
    );

    // 2. local_fsrs_cards
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_fsrs_cards (
        item_id TEXT PRIMARY KEY,
        state INTEGER NOT NULL DEFAULT 0,
        stability REAL NOT NULL DEFAULT 0.0,
        difficulty REAL NOT NULL DEFAULT 0.0,
        reps INTEGER NOT NULL DEFAULT 0,
        lapses INTEGER NOT NULL DEFAULT 0,
        last_review TEXT NOT NULL,
        next_review TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_fsrs_next_review ON local_fsrs_cards(next_review);',
    );

    // 3. local_review_logs
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_review_logs (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        rating INTEGER NOT NULL,
        state INTEGER NOT NULL,
        review_time TEXT NOT NULL,
        elapsed_days REAL NOT NULL DEFAULT 0.0,
        scheduled_days INTEGER NOT NULL DEFAULT 0,
        synced INTEGER NOT NULL DEFAULT 0
      );
    ''');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_review_logs_item ON local_review_logs(item_id);',
    );
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_review_logs_synced ON local_review_logs(synced);',
    );

    // 4. local_sync_queue
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mutation_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending'
      );
    ''');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_sync_queue_status ON local_sync_queue(status);',
    );

    // 5. local_completed_lessons
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_completed_lessons (
        lesson_id TEXT PRIMARY KEY,
        completed_at TEXT NOT NULL,
        score REAL NOT NULL DEFAULT 1.0,
        synced INTEGER NOT NULL DEFAULT 0
      );
    ''');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_completed_lessons_synced ON local_completed_lessons(synced);',
    );

    await batch.commit(noResult: true);
  }

  // ==========================================
  // Lessons Management
  // ==========================================

  Future<void> saveLessons(List<LessonItem> lessons) async {
    final db = await database;
    final batch = db.batch();
    for (final lesson in lessons) {
      batch.insert('local_lessons', {
        'id': lesson.id,
        'language': lesson.language,
        'category': lesson.category,
        'target_text': lesson.targetText,
        'phonetic_or_kana': lesson.phoneticOrKana,
        'meaning_vi': lesson.meaningVi,
        'workplace_context': lesson.workplaceContext,
        'workplace_context_vi': lesson.workplaceContextVi,
        'stroke_order_hints': jsonEncode(lesson.strokeOrderHints),
        'difficulty_level': lesson.difficultyLevel,
        'cached_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> saveLesson(LessonItem lesson) async {
    await saveLessons([lesson]);
  }

  Future<List<LessonItem>> getLessons({
    String? language,
    String? category,
  }) async {
    final db = await database;
    String? whereClause;
    List<dynamic>? whereArgs;

    if (language != null && category != null) {
      whereClause = 'language = ? AND category = ?';
      whereArgs = [language, category];
    } else if (language != null) {
      whereClause = 'language = ?';
      whereArgs = [language];
    } else if (category != null) {
      whereClause = 'category = ?';
      whereArgs = [category];
    }

    final rows = await db.query(
      'local_lessons',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'id ASC',
    );

    return rows.map((r) {
      List<String> hints = [];
      try {
        final decoded = jsonDecode(r['stroke_order_hints'] as String);
        if (decoded is List) {
          hints = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}

      return LessonItem(
        id: r['id'] as String,
        language: r['language'] as String,
        category: r['category'] as String,
        targetText: r['target_text'] as String,
        phoneticOrKana: r['phonetic_or_kana'] as String,
        meaningVi: r['meaning_vi'] as String,
        workplaceContext: r['workplace_context'] as String,
        workplaceContextVi: r['workplace_context_vi'] as String,
        strokeOrderHints: hints,
        difficultyLevel: (r['difficulty_level'] as num?)?.toInt() ?? 1,
      );
    }).toList();
  }

  Future<LessonItem?> getLesson(String id) async {
    final db = await database;
    final rows = await db.query(
      'local_lessons',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    List<String> hints = [];
    try {
      final decoded = jsonDecode(r['stroke_order_hints'] as String);
      if (decoded is List) {
        hints = decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}

    return LessonItem(
      id: r['id'] as String,
      language: r['language'] as String,
      category: r['category'] as String,
      targetText: r['target_text'] as String,
      phoneticOrKana: r['phonetic_or_kana'] as String,
      meaningVi: r['meaning_vi'] as String,
      workplaceContext: r['workplace_context'] as String,
      workplaceContextVi: r['workplace_context_vi'] as String,
      strokeOrderHints: hints,
      difficultyLevel: (r['difficulty_level'] as num?)?.toInt() ?? 1,
    );
  }

  // ==========================================
  // FSRS Cards Management
  // ==========================================

  Future<void> saveCard(FSRSCard card) async {
    final db = await database;
    await db.insert('local_fsrs_cards', {
      'item_id': card.itemId,
      'state': card.state.index,
      'stability': card.stability,
      'difficulty': card.difficulty,
      'reps': card.reps,
      'lapses': card.lapses,
      'last_review': card.lastReview.toIso8601String(),
      'next_review': card.nextReview.toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<FSRSCard?> getCard(String itemId) async {
    final db = await database;
    final rows = await db.query(
      'local_fsrs_cards',
      where: 'item_id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return FSRSCard(
      itemId: r['item_id'] as String,
      state: FSRSState.values[(r['state'] as num).toInt()],
      stability: (r['stability'] as num).toDouble(),
      difficulty: (r['difficulty'] as num).toDouble(),
      reps: (r['reps'] as num).toInt(),
      lapses: (r['lapses'] as num).toInt(),
      lastReview: DateTime.parse(r['last_review'] as String),
      nextReview: DateTime.parse(r['next_review'] as String),
    );
  }

  Future<List<FSRSCard>> getAllCards() async {
    final db = await database;
    final rows = await db.query('local_fsrs_cards', orderBy: 'item_id ASC');
    return rows
        .map(
          (r) => FSRSCard(
            itemId: r['item_id'] as String,
            state: FSRSState.values[(r['state'] as num).toInt()],
            stability: (r['stability'] as num).toDouble(),
            difficulty: (r['difficulty'] as num).toDouble(),
            reps: (r['reps'] as num).toInt(),
            lapses: (r['lapses'] as num).toInt(),
            lastReview: DateTime.parse(r['last_review'] as String),
            nextReview: DateTime.parse(r['next_review'] as String),
          ),
        )
        .toList();
  }

  Future<List<String>> getDueCardIds(DateTime asOf) async {
    final db = await database;
    final rows = await db.query(
      'local_fsrs_cards',
      columns: ['item_id'],
      where: 'next_review <= ?',
      whereArgs: [asOf.toIso8601String()],
      orderBy: 'next_review ASC',
    );
    return rows.map((r) => r['item_id'] as String).toList();
  }

  // ==========================================
  // Review Logs Management
  // ==========================================

  Future<void> insertReviewLog(LocalReviewLog log) async {
    final db = await database;
    await db.insert(
      'local_review_logs',
      log.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<LocalReviewLog>> getReviewLogs({int? synced, int? limit}) async {
    final db = await database;
    final rows = await db.query(
      'local_review_logs',
      where: synced != null ? 'synced = ?' : null,
      whereArgs: synced != null ? [synced] : null,
      orderBy: 'review_time ASC',
      limit: limit,
    );
    return rows.map(LocalReviewLog.fromMap).toList();
  }

  Future<void> markReviewLogsSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'local_review_logs',
      {'synced': 1},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  // ==========================================
  // Sync Queue Management
  // ==========================================

  Future<int> enqueueMutation({
    required String mutationType,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
  }) async {
    final db = await database;
    final time = createdAt ?? DateTime.now().toUtc();
    return await db.insert('local_sync_queue', {
      'mutation_type': mutationType,
      'payload': jsonEncode(payload),
      'created_at': time.toIso8601String(),
      'retry_count': 0,
      'status': 'pending',
    });
  }

  Future<List<SyncQueueItem>> getPendingMutations({int? limit}) async {
    final db = await database;
    final rows = await db.query(
      'local_sync_queue',
      where: "status = 'pending'",
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(SyncQueueItem.fromMap).toList();
  }

  Future<void> recoverInterruptedMutations() async {
    final db = await database;
    await db.rawUpdate(
      "UPDATE local_sync_queue SET status = 'pending' WHERE status = 'in_progress'",
    );
  }

  Future<DateTime?> getLastPullTime() async {
    final db = await database;
    final rows = await db.query(
      'local_sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['last_pull_time'],
      limit: 1,
    );
    return rows.isEmpty ? null : DateTime.parse(rows.first['value'] as String);
  }

  Future<String> getOrCreateClientId() async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'local_sync_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['client_id'],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first['value'] as String;
      final id = _randomId('client_');
      await txn.insert('local_sync_metadata', {
        'key': 'client_id',
        'value': id,
      });
      return id;
    });
  }

  Future<void> setLastPullTime(DateTime time) async {
    final db = await database;
    await db.insert('local_sync_metadata', {
      'key': 'last_pull_time',
      'value': time.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markMutationsInProgress(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'local_sync_queue',
      {'status': 'in_progress'},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<void> deleteMutations(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      'local_sync_queue',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<void> resetFailedMutations(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate('''
      UPDATE local_sync_queue
      SET status = 'pending', retry_count = retry_count + 1
      WHERE id IN ($placeholders)
    ''', ids);
  }

  // ==========================================
  // Completed Lessons Management
  // ==========================================

  Future<void> saveCompletedLesson(
    String lessonId, {
    DateTime? completedAt,
    double score = 1.0,
    int synced = 0,
  }) async {
    final db = await database;
    final time = completedAt ?? DateTime.now().toUtc();
    await db.insert('local_completed_lessons', {
      'lesson_id': lessonId,
      'completed_at': time.toIso8601String(),
      'score': score,
      'synced': synced,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LocalCompletedLesson>> getCompletedLessons({int? synced}) async {
    final db = await database;
    final rows = await db.query(
      'local_completed_lessons',
      where: synced != null ? 'synced = ?' : null,
      whereArgs: synced != null ? [synced] : null,
      orderBy: 'completed_at ASC',
    );
    return rows.map(LocalCompletedLesson.fromMap).toList();
  }

  Future<int> getCompletedCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM local_completed_lessons',
    );
    if (result.isEmpty) return 0;
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> markCompletedLessonsSynced(List<String> lessonIds) async {
    if (lessonIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(lessonIds.length, '?').join(',');
    await db.update(
      'local_completed_lessons',
      {'synced': 1},
      where: 'lesson_id IN ($placeholders)',
      whereArgs: lessonIds,
    );
  }

  // ==========================================
  // Atomic Review Transaction
  // ==========================================

  /// Atomically updates local FSRS card, logs the review event,
  /// updates completed lesson tracker, and enqueues sync mutation.
  Future<String> recordReviewTransaction({
    required FSRSCard updatedCard,
    required FSRSRating rating,
    required DateTime reviewTime,
    required double elapsedDays,
    required int scheduledDays,
    double completionScore = 1.0,
  }) async {
    final db = await database;
    final logId = _randomId('rev_');

    await db.transaction((txn) async {
      // 1. Upsert local card
      await txn.insert('local_fsrs_cards', {
        'item_id': updatedCard.itemId,
        'state': updatedCard.state.index,
        'stability': updatedCard.stability,
        'difficulty': updatedCard.difficulty,
        'reps': updatedCard.reps,
        'lapses': updatedCard.lapses,
        'last_review': updatedCard.lastReview.toIso8601String(),
        'next_review': updatedCard.nextReview.toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // 2. Append review log
      await txn.insert('local_review_logs', {
        'id': logId,
        'item_id': updatedCard.itemId,
        'rating': rating.index + 1,
        'state': updatedCard.state.index,
        'review_time': reviewTime.toIso8601String(),
        'elapsed_days': elapsedDays,
        'scheduled_days': scheduledDays,
        'synced': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // 3. Mark completed lesson
      await txn.insert('local_completed_lessons', {
        'lesson_id': updatedCard.itemId,
        'completed_at': reviewTime.toIso8601String(),
        'score': completionScore,
        'synced': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // 4. Enqueue sync task
      final payload = jsonEncode({
        'review_id': logId,
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
      });

      await txn.insert('local_sync_queue', {
        'mutation_type': 'review',
        'payload': payload,
        'created_at': reviewTime.toIso8601String(),
        'retry_count': 0,
        'status': 'pending',
      });
    });

    return logId;
  }

  // ==========================================
  // Maintenance & Teardown
  // ==========================================

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('local_sync_queue');
      await txn.delete('local_review_logs');
      await txn.delete('local_completed_lessons');
      await txn.delete('local_fsrs_cards');
      await txn.delete('local_lessons');
      await txn.delete('local_sync_metadata');
    });
  }

  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
    }
  }
}
