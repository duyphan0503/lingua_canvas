import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';

void main() {
  group('LessonItem Model Tests', () {
    test('fromJson deserializes complete JSON object correctly', () {
      final json = {
        'id': 'ja_kata_bug',
        'language': 'ja',
        'category': 'it_workplace',
        'target_text': 'バグ',
        'phonetic_or_kana': 'bagu',
        'meaning_vi': 'Lỗi phần mềm (Bug)',
        'workplace_context': 'この機能に重大なバグが発生しました',
        'workplace_context_vi':
            'Chức năng này đã phát sinh một con bug nghiêm trọng.',
        'stroke_order_hints': [
          'Chữ バ (Ba): Viết nét ハ (Ha) rồi thêm 2 dấu phẩy đục âm ゛',
          'Chữ グ (Gu): Viết nét ク (Ku) rồi thêm 2 dấu phẩy ゛',
        ],
        'difficulty_level': 1,
      };

      final item = LessonItem.fromJson(json);

      expect(item.id, 'ja_kata_bug');
      expect(item.language, 'ja');
      expect(item.category, 'it_workplace');
      expect(item.targetText, 'バグ');
      expect(item.phoneticOrKana, 'bagu');
      expect(item.meaningVi, 'Lỗi phần mềm (Bug)');
      expect(item.workplaceContext, 'この機能に重大なバグが発生しました');
      expect(
        item.workplaceContextVi,
        'Chức năng này đã phát sinh một con bug nghiêm trọng.',
      );
      expect(item.strokeOrderHints.length, 2);
      expect(item.strokeOrderHints.first, contains('Chữ バ'));
      expect(item.difficultyLevel, 1);
    });

    test(
      'fromJson handles missing stroke_order_hints and difficulty_level defaults',
      () {
        final json = {
          'id': 'en_it_test',
          'language': 'en',
          'category': 'it_workplace',
          'target_text': 'test',
          'phonetic_or_kana': '/test/',
          'meaning_vi': 'Kiểm thử',
          'workplace_context':
              'Run the unit test suite before creating a pull request.',
          'workplace_context_vi': 'Chạy bộ kiểm thử trước khi tạo PR.',
        };

        final item = LessonItem.fromJson(json);

        expect(item.id, 'en_it_test');
        expect(item.strokeOrderHints, isEmpty);
        expect(item.difficultyLevel, 1);
      },
    );

    test('toJson serializes fields matching backend schema', () {
      final item = LessonItem(
        id: 'en_it_deploy',
        language: 'en',
        category: 'it_workplace',
        targetText: 'deploy',
        phoneticOrKana: '/dɪˈplɔɪ/',
        meaningVi: 'Triển khai phần mềm lên server',
        workplaceContext:
            'We are ready to deploy the release to production tonight.',
        workplaceContextVi: 'Chúng tôi đã sẵn sàng triển khai phiên bản mới.',
        strokeOrderHints: ['Viết thường d-e-p-l-o-y', 'Nét đuôi kéo dài'],
        difficultyLevel: 2,
      );

      final json = item.toJson();

      expect(json['id'], 'en_it_deploy');
      expect(json['language'], 'en');
      expect(json['category'], 'it_workplace');
      expect(json['target_text'], 'deploy');
      expect(json['phonetic_or_kana'], '/dɪˈplɔɪ/');
      expect(json['meaning_vi'], 'Triển khai phần mềm lên server');
      expect(
        json['workplace_context'],
        'We are ready to deploy the release to production tonight.',
      );
      expect(
        json['workplace_context_vi'],
        'Chúng tôi đã sẵn sàng triển khai phiên bản mới.',
      );
      expect(json['stroke_order_hints'], [
        'Viết thường d-e-p-l-o-y',
        'Nét đuôi kéo dài',
      ]);
      expect(json['difficulty_level'], 2);
    });

    test('round-trip JSON serialization preserves all data', () {
      final original = LessonItem(
        id: 'ja_it_kaihatsu',
        language: 'ja',
        category: 'it_workplace',
        targetText: '開発',
        phoneticOrKana: 'かいはつ',
        meaningVi: 'Phát triển phần mềm',
        workplaceContext: '新しいシステムの開発チームに参加します',
        workplaceContextVi: 'Tôi sẽ tham gia đội ngũ phát triển hệ thống mới.',
        strokeOrderHints: ['Nét 開 trước', 'Nét 発 sau'],
        difficultyLevel: 3,
      );

      final restored = LessonItem.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.language, original.language);
      expect(restored.category, original.category);
      expect(restored.targetText, original.targetText);
      expect(restored.phoneticOrKana, original.phoneticOrKana);
      expect(restored.meaningVi, original.meaningVi);
      expect(restored.workplaceContext, original.workplaceContext);
      expect(restored.workplaceContextVi, original.workplaceContextVi);
      expect(restored.strokeOrderHints, original.strokeOrderHints);
      expect(restored.difficultyLevel, original.difficultyLevel);
    });
  });
}
