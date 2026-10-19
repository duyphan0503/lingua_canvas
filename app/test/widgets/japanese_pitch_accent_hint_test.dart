import 'package:app/services/japanese_pitch_accent.dart';
import 'package:app/widgets/japanese_pitch_accent_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pitch lookup uses sourced reading-specific Kanjium patterns', () {
    const repository = JapanesePitchAccentRepository();
    final progress = repository.lookup('進捗', reading: 'しんちょく');
    expect(progress?.downstep, 0);
    expect(progress?.reading, 'しんちょく');
    expect(
      repository
          .lookupAll('会議', reading: 'かいぎ')
          .map((entry) => entry.downstep),
      [1, 3],
    );
    expect(repository.lookup('会議', reading: 'けんぎ'), isNull);
    expect(JapanesePitchAccentRepository.coveredPairs, 56);
    expect(JapanesePitchAccentRepository.coveredPatterns, 60);
    expect(JapanesePitchAccentRepository.provenance, contains('Kanjium'));
  });

  testWidgets('known pitch data shows its reading and contour', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(
        body: JapanesePitchAccentHint(word: '進捗', reading: 'しんちょく'),
      )),
    );
    expect(find.textContaining('Heiban'), findsOneWidget);
    expect(find.textContaining('Kanjium'), findsOneWidget);
    expect(find.byKey(const ValueKey('japanese-pitch-contour')), findsWidgets);
  });

  testWidgets('unknown pitch data is explicit and has no contour', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: JapanesePitchAccentHint(word: '未登録語')),
      ),
    );
    expect(
      find.text('Cao độ từ: chưa có dữ liệu đã kiểm chứng'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('未登録語')), findsOneWidget);
    expect(find.byKey(const ValueKey('japanese-pitch-contour')), findsNothing);
  });
}
