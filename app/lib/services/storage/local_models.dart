import 'dart:convert';

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

class StudyStreak {
  final int currentStreak;
  final int longestStreak;
  final Map<String, int>
  activityHistory; // last 30 days activity map {date: count}

  const StudyStreak({
    required this.currentStreak,
    required this.longestStreak,
    required this.activityHistory,
  });

  Map<String, int> get history => activityHistory;
  Map<String, int> get last30Days => activityHistory;

  Map<String, dynamic> toMap() {
    return {
      'current_streak': currentStreak,
      'longest_streak': longestStreak,
      'activity_history': activityHistory,
      'last_30_days': activityHistory,
    };
  }

  factory StudyStreak.fromMap(Map<String, dynamic> map) {
    final rawHistory =
        (map['activity_history'] ??
                map['history'] ??
                map['last_30_days'] ??
                map['activity_map'])
            as Map?;
    final Map<String, int> history = {};
    if (rawHistory != null) {
      rawHistory.forEach((k, v) {
        history[k.toString()] = (v as num).toInt();
      });
    }
    return StudyStreak(
      currentStreak:
          (map['current_streak'] ?? map['currentStreak'] as num?)?.toInt() ?? 0,
      longestStreak:
          (map['longest_streak'] ?? map['longestStreak'] as num?)?.toInt() ?? 0,
      activityHistory: history,
    );
  }

  dynamic operator [](String key) {
    switch (key) {
      case 'current_streak':
      case 'currentStreak':
        return currentStreak;
      case 'longest_streak':
      case 'longestStreak':
        return longestStreak;
      case 'activity_history':
      case 'history':
      case 'last_30_days':
      case 'activity_map':
        return activityHistory;
      default:
        return null;
    }
  }
}
