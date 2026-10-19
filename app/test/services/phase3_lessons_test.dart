import 'dart:convert';
import 'dart:io';

import 'package:app/services/phase3_lessons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const japanese = {
    'ja_n4_kaigi': '会議',
    'ja_n4_renraku': '連絡',
    'ja_n4_soudan': '相談',
    'ja_n4_houkoku': '報告',
    'ja_n4_shounin': '承認',
    'ja_n4_kigen': '期限',
    'ja_n4_sekinin': '責任',
    'ja_n4_kaizen': '改善',
    'ja_n4_shouchi': '承知いたしました',
    'ja_n4_irai': '依頼',
  };
  const english = {
    'en_biz_negotiate': 'negotiate',
    'en_biz_agenda': 'agenda',
    'en_biz_proposal': 'proposal',
    'en_biz_invoice': 'invoice',
    'en_biz_consensus': 'consensus',
    'en_biz_delegate': 'delegate',
    'en_biz_compliance': 'compliance',
    'en_biz_postpone': 'postpone',
    'en_biz_acknowledge': 'acknowledge',
    'en_biz_objective': 'objective',
  };

  test('offline phase 3 catalog supplies each required lesson once', () {
    expect(phase3Lessons, hasLength(220));
    expect(phase3Lessons.map((l) => l.id).toSet(), hasLength(220));
    final expansion =
        jsonDecode(
              File('../curriculum/workplace_expansion.json').readAsStringSync(),
            )
            as List<dynamic>;
    expect(expansion, hasLength(200));
    expect(expansion.where((row) => row['language'] == 'ja'), hasLength(100));
    expect(expansion.where((row) => row['language'] == 'en'), hasLength(100));
    expect(
      phase3Lessons.where((lesson) => lesson.id.contains('_work_')).length,
      200,
    );
    for (final entry in {...japanese, ...english}.entries) {
      final lesson = phase3Lessons.singleWhere((l) => l.id == entry.key);
      expect(lesson.targetText, entry.value);
      expect(lesson.language, japanese.containsKey(entry.key) ? 'ja' : 'en');
      expect(
        lesson.category,
        japanese.containsKey(entry.key) ? 'jlpt_n4' : 'toeic_business',
      );
      expect(lesson.phoneticOrKana.trim(), isNotEmpty);
      expect(lesson.meaningVi.trim(), isNotEmpty);
      expect(lesson.workplaceContext.trim(), isNotEmpty);
      expect(lesson.workplaceContextVi.trim(), isNotEmpty);
      expect(lesson.strokeOrderHints.length, greaterThanOrEqualTo(2));
      expect(lesson.strokeOrderHints.every((h) => h.trim().isNotEmpty), isTrue);
      expect(lesson.difficultyLevel, inInclusiveRange(1, 3));
    }
  });
  test('offline phase 3 fields match the backend seed catalog', () {
    final source = File('../server/src/data.rs').readAsStringSync();
    final blocks = RegExp(
      r'LessonItem \{(.*?)\n        \}',
      dotAll: true,
    ).allMatches(source).map((match) => match.group(1)!);
    final expansion =
        jsonDecode(
              File('../curriculum/workplace_expansion.json').readAsStringSync(),
            )
            as List<dynamic>;
    for (final lesson in phase3Lessons) {
      if (lesson.id.contains('_work_')) {
        final sourceRow =
            expansion.singleWhere((row) => row['id'] == lesson.id)
                as Map<String, dynamic>;
        expect(lesson.toJson(), sourceRow, reason: lesson.id);
        continue;
      }
      final block = blocks.singleWhere((b) => b.contains('id: "${lesson.id}"'));
      for (final entry in lesson.toJson().entries) {
        if (entry.key == 'stroke_order_hints') {
          final hints = RegExp(
            r'stroke_order_hints: vec!\[(.*?)\]',
            dotAll: true,
          ).firstMatch(block)!.group(1)!;
          final strings = RegExp(
            r'("(?:\\.|[^"\\])*")\.to_string\(\)',
          ).allMatches(hints).map((m) => jsonDecode(m.group(1)!)).toList();
          expect(strings, entry.value, reason: '${lesson.id}: ${entry.key}');
        } else if (entry.key == 'difficulty_level') {
          final value = RegExp(r'difficulty_level: (\d+)').firstMatch(block)!;
          expect(int.parse(value.group(1)!), entry.value);
        } else {
          final value = RegExp(
            '${entry.key}:\\s*("(?:\\\\.|[^"\\\\])*")\\.to_string\\(\\)',
          ).firstMatch(block)!;
          expect(
            jsonDecode(value.group(1)!),
            entry.value,
            reason: '${lesson.id}: ${entry.key}',
          );
        }
      }
    }
  });
}
