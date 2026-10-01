import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/fsrs_engine.dart';

void main() {
  group('FSRSEngine Algorithm Unit Tests', () {
    late FSRSEngine engine;
    final baseTime = DateTime.utc(2026, 10, 1, 12, 0, 0);

    setUp(() {
      engine = FSRSEngine();
    });

    group('Retrievability calculations', () {
      test('retrievability is 0.0 when stability is non-positive', () {
        expect(engine.retrievability(0.0, 0.0), equals(0.0));
        expect(engine.retrievability(5.0, -1.0), equals(0.0));
      });

      test(
        'retrievability is 1.0 at elapsed time 0 with positive stability',
        () {
          final r = engine.retrievability(0.0, 5.0);
          expect(r, closeTo(1.0, 1e-6));
        },
      );

      test(
        'retrievability equals exactly requested retention (0.90) when elapsedDays == stability',
        () {
          // At elapsedDays = S: R = (1 + 19/81 * 1)^(-0.5) = (100/81)^(-0.5) = 9/10 = 0.90
          final r = engine.retrievability(10.0, 10.0);
          expect(r, closeTo(0.90, 1e-4));
        },
      );

      test('retrievability strictly decays over time', () {
        final rDay1 = engine.retrievability(1.0, 5.0);
        final rDay5 = engine.retrievability(5.0, 5.0);
        final rDay20 = engine.retrievability(20.0, 5.0);

        expect(rDay1, greaterThan(rDay5));
        expect(rDay5, greaterThan(rDay20));
        expect(rDay20, greaterThan(0.0));
      });
    });

    group('Interval scheduling', () {
      test('nextInterval scales proportionally with stability', () {
        final intervalLow = engine.nextInterval(1.0);
        final intervalMed = engine.nextInterval(10.0);
        final intervalHigh = engine.nextInterval(100.0);

        expect(intervalLow, greaterThanOrEqualTo(1));
        expect(intervalMed, greaterThan(intervalLow));
        expect(intervalHigh, greaterThan(intervalMed));
      });

      test(
        'nextInterval respects minimum of 1 day and maximumInterval clamping',
        () {
          final intervalMin = engine.nextInterval(0.001);
          expect(intervalMin, equals(1));

          final customEngine = FSRSEngine(maximumInterval: 30);
          final intervalCapped = customEngine.nextInterval(1000.0);
          expect(intervalCapped, equals(30));
        },
      );
    });

    group('Initial rating parameters', () {
      test('initStability strictly increases with rating quality', () {
        final sAgain = engine.initStability(FSRSRating.again);
        final sHard = engine.initStability(FSRSRating.hard);
        final sGood = engine.initStability(FSRSRating.good);
        final sEasy = engine.initStability(FSRSRating.easy);

        expect(sAgain, lessThan(sHard));
        expect(sHard, lessThan(sGood));
        expect(sGood, lessThan(sEasy));
      });

      test(
        'initDifficulty decreases with higher ratings and clamps to [1.0, 10.0]',
        () {
          final dAgain = engine.initDifficulty(FSRSRating.again);
          final dEasy = engine.initDifficulty(FSRSRating.easy);

          expect(dAgain, greaterThan(dEasy));
          expect(dAgain, inInclusiveRange(1.0, 10.0));
          expect(dEasy, inInclusiveRange(1.0, 10.0));
        },
      );
    });

    group('State transitions and review lifecycle', () {
      test(
        'New card -> rating Again -> transitions to Learning with lapse',
        () {
          final initialCard = FSRSCard.initial('test_card_1');
          expect(initialCard.state, equals(FSRSState.newCard));
          expect(initialCard.reps, equals(0));
          expect(initialCard.lapses, equals(0));

          final reviewed = engine.review(
            initialCard,
            FSRSRating.again,
            baseTime,
          );

          expect(reviewed.state, equals(FSRSState.learning));
          expect(reviewed.reps, equals(1));
          expect(reviewed.lapses, equals(1));
          expect(
            reviewed.nextReview,
            equals(baseTime.add(const Duration(minutes: 10))),
          );
        },
      );

      test(
        'New card -> rating Good -> transitions directly to Review with days interval',
        () {
          final initialCard = FSRSCard.initial('test_card_2');
          final reviewed = engine.review(
            initialCard,
            FSRSRating.good,
            baseTime,
          );

          expect(reviewed.state, equals(FSRSState.review));
          expect(reviewed.reps, equals(1));
          expect(reviewed.lapses, equals(0));
          expect(reviewed.stability, greaterThan(0.0));
          expect(
            reviewed.nextReview.difference(baseTime).inDays,
            greaterThanOrEqualTo(1),
          );
        },
      );

      test('Learning card -> rating Good -> graduates to Review', () {
        final learningCard = FSRSCard(
          itemId: 'test_card_3',
          state: FSRSState.learning,
          stability: 0.4,
          difficulty: 7.0,
          reps: 1,
          lapses: 1,
          lastReview: baseTime,
          nextReview: baseTime.add(const Duration(minutes: 10)),
        );

        final reviewed = engine.review(
          learningCard,
          FSRSRating.good,
          baseTime.add(const Duration(minutes: 10)),
        );

        expect(reviewed.state, equals(FSRSState.review));
        expect(reviewed.reps, equals(2));
        expect(reviewed.lapses, equals(1));
        expect(reviewed.nextReview.isAfter(reviewed.lastReview), isTrue);
      });

      test(
        'Review card -> rating Good -> stays in Review with stability growth',
        () {
          final reviewCard = FSRSCard(
            itemId: 'test_card_4',
            state: FSRSState.review,
            stability: 3.0,
            difficulty: 5.0,
            reps: 2,
            lapses: 0,
            lastReview: baseTime,
            nextReview: baseTime.add(const Duration(days: 3)),
          );

          final recallTime = baseTime.add(const Duration(days: 3));
          final reviewed = engine.review(
            reviewCard,
            FSRSRating.good,
            recallTime,
          );

          expect(reviewed.state, equals(FSRSState.review));
          expect(reviewed.reps, equals(3));
          expect(reviewed.lapses, equals(0));
          expect(reviewed.stability, greaterThan(reviewCard.stability));
          expect(
            reviewed.nextReview.difference(recallTime).inDays,
            greaterThan(3),
          );
        },
      );

      test('Review card -> rating Again -> lapses into Relearning', () {
        final reviewCard = FSRSCard(
          itemId: 'test_card_5',
          state: FSRSState.review,
          stability: 15.0,
          difficulty: 4.5,
          reps: 5,
          lapses: 0,
          lastReview: baseTime,
          nextReview: baseTime.add(const Duration(days: 15)),
        );

        final forgetTime = baseTime.add(const Duration(days: 15));
        final reviewed = engine.review(
          reviewCard,
          FSRSRating.again,
          forgetTime,
        );

        expect(reviewed.state, equals(FSRSState.relearning));
        expect(reviewed.reps, equals(6));
        expect(reviewed.lapses, equals(1));
        expect(reviewed.stability, lessThan(reviewCard.stability));
        expect(
          reviewed.nextReview,
          equals(forgetTime.add(const Duration(minutes: 10))),
        );
      });
    });

    group('FSRSCard Serialization', () {
      test('toJson and fromJson preserve card state accurately', () {
        final original = FSRSCard(
          itemId: 'card_json_test',
          state: FSRSState.review,
          stability: 12.34,
          difficulty: 5.67,
          reps: 4,
          lapses: 1,
          lastReview: baseTime,
          nextReview: baseTime.add(const Duration(days: 12)),
        );

        final map = original.toJson();
        final restored = FSRSCard.fromJson(map);

        expect(restored.itemId, original.itemId);
        expect(restored.state, original.state);
        expect(restored.stability, closeTo(original.stability, 1e-5));
        expect(restored.difficulty, closeTo(original.difficulty, 1e-5));
        expect(restored.reps, original.reps);
        expect(restored.lapses, original.lapses);
        expect(restored.lastReview, original.lastReview);
        expect(restored.nextReview, original.nextReview);
      });
    });
  });
}
