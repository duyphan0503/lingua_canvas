import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'private_profile.dart';

/// Converts existing SQL profile rows to the shared transaction representation.
class SqlPrivateProfile {
  static const tables = [
    'local_lessons',
    'local_fsrs_cards',
    'local_review_logs',
    'local_sync_queue',
    'local_completed_lessons',
    'local_daily_activity',
    'local_private_profile',
  ];
  static Future<Map<String, dynamic>> read(DatabaseExecutor db) async {
    final rows = <String, dynamic>{};
    for (final t in tables) {
      rows[t] = await db.query(t);
    }
    rows['metadata'] = await db.query('local_sync_metadata');
    return decode(rows);
  }

  static Map<String, dynamic> decode(Map rows) {
    final p = <String, dynamic>{
      'metadata': <String, dynamic>{},
      'lessons': <String, dynamic>{},
      'cards': <String, dynamic>{},
      'logs': <String, dynamic>{},
      'queue': <String, dynamic>{},
      'completions': <String, dynamic>{},
      'activity': <String, dynamic>{},
    };
    for (final r in rows['metadata'] as List? ?? []) {
      (p['metadata'] as Map)[r['key']] = r['value'];
    }
    for (final raw in rows['local_lessons'] as List? ?? []) {
      final r = Map<String, dynamic>.from(raw as Map);
      r['stroke_order_hints'] = jsonDecode(r['stroke_order_hints'] as String);
      r.remove('cached_at');
      (p['lessons'] as Map)[r['id']] = r;
    }
    for (final r in rows['local_fsrs_cards'] as List? ?? []) {
      (p['cards'] as Map)[r['item_id']] = {
        'itemId': r['item_id'],
        'state': r['state'],
        'stability': r['stability'],
        'difficulty': r['difficulty'],
        'reps': r['reps'],
        'lapses': r['lapses'],
        'lastReview': r['last_review'],
        'nextReview': r['next_review'],
      };
    }
    for (final r in rows['local_review_logs'] as List? ?? []) {
      (p['logs'] as Map)[r['id']] = Map<String, dynamic>.from(r as Map);
    }
    for (final r in rows['local_sync_queue'] as List? ?? []) {
      (p['queue'] as Map)['${r['id']}'] = Map<String, dynamic>.from(r as Map);
    }
    for (final r in rows['local_completed_lessons'] as List? ?? []) {
      (p['completions'] as Map)[r['lesson_id']] = Map<String, dynamic>.from(
        r as Map,
      );
    }
    for (final r in rows['local_daily_activity'] as List? ?? []) {
      (p['activity'] as Map)[r['activity_date']] = r['items_count'];
    }
    for (final r in rows['local_private_profile'] as List? ?? []) {
      p.addAll(jsonDecode(r['payload'] as String) as Map<String, dynamic>);
    }
    return p;
  }

  static Map<String, List<Map<String, Object?>>> encode(
    Map<String, dynamic> p,
  ) {
    final rows = <String, List<Map<String, Object?>>>{
      for (final t in tables) t: [],
    };
    for (final r in PrivateProfile.table(p, 'lessons').values) {
      rows['local_lessons']!.add({
        ...Map<String, Object?>.from(r as Map),
        'stroke_order_hints': jsonEncode(r['stroke_order_hints']),
      });
    }
    for (final r in PrivateProfile.table(p, 'cards').values) {
      rows['local_fsrs_cards']!.add({
        'item_id': r['itemId'],
        'state': r['state'],
        'stability': r['stability'],
        'difficulty': r['difficulty'],
        'reps': r['reps'],
        'lapses': r['lapses'],
        'last_review': r['lastReview'],
        'next_review': r['nextReview'],
      });
    }
    rows['local_review_logs'] = PrivateProfile.table(
      p,
      'logs',
    ).values.map((r) => Map<String, Object?>.from(r as Map)).toList();
    rows['local_sync_queue'] = PrivateProfile.table(p, 'queue').values
        .map(
          (r) => {
            ...Map<String, Object?>.from(r as Map),
            'sent': r['sent'] == true || r['sent'] == 1 ? 1 : 0,
          },
        )
        .toList();
    rows['local_completed_lessons'] = PrivateProfile.table(
      p,
      'completions',
    ).values.map((r) => Map<String, Object?>.from(r as Map)).toList();
    rows['local_daily_activity'] = PrivateProfile.table(p, 'activity').entries
        .map(
          (e) => <String, Object?>{
            'activity_date': e.key,
            'items_count': e.value,
          },
        )
        .toList();
    rows['local_private_profile'] = [
      {
        'id': 1,
        'payload': jsonEncode({
          for (final t in ['private_lessons', 'aliases', 'merge_receipts'])
            t: PrivateProfile.table(p, t),
        }),
      },
    ];
    rows['metadata'] = PrivateProfile.table(p, 'metadata').entries
        .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
        .toList();
    return rows;
  }

  static Future<void> write(DatabaseExecutor db, Map<String, dynamic> p) async {
    final rows = encode(p);
    for (final t in tables) {
      await db.delete(t);
      for (final row in rows[t]!) {
        await db.insert(t, row);
      }
    }
    for (final row in rows['metadata']!) {
      await db.insert(
        'local_sync_metadata',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}
