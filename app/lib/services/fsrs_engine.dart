import 'dart:math';

enum FSRSState { newCard, learning, review, relearning }

enum FSRSRating {
  again, // 1
  hard, // 2
  good, // 3
  easy, // 4
}

class FSRSCard {
  final String itemId;
  final FSRSState state;
  final double stability;
  final double difficulty;
  final int reps;
  final int lapses;
  final DateTime lastReview;
  final DateTime nextReview;

  FSRSCard({
    required this.itemId,
    required this.state,
    required this.stability,
    required this.difficulty,
    required this.reps,
    required this.lapses,
    required this.lastReview,
    required this.nextReview,
  });

  factory FSRSCard.initial(String itemId) {
    final now = DateTime.now().toUtc();
    return FSRSCard(
      itemId: itemId,
      state: FSRSState.newCard,
      stability: 0.0,
      difficulty: 0.0,
      reps: 0,
      lapses: 0,
      lastReview: now,
      nextReview: now,
    );
  }

  factory FSRSCard.fromJson(Map<String, dynamic> json) {
    return FSRSCard(
      itemId: json['itemId'] as String,
      state: FSRSState.values[json['state'] as int? ?? 0],
      stability: (json['stability'] as num?)?.toDouble() ?? 0.0,
      difficulty: (json['difficulty'] as num?)?.toDouble() ?? 0.0,
      reps: (json['reps'] as num?)?.toInt() ?? 0,
      lapses: (json['lapses'] as num?)?.toInt() ?? 0,
      lastReview: DateTime.parse(json['lastReview'] as String),
      nextReview: DateTime.parse(json['nextReview'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'state': state.index,
      'stability': stability,
      'difficulty': difficulty,
      'reps': reps,
      'lapses': lapses,
      'lastReview': lastReview.toIso8601String(),
      'nextReview': nextReview.toIso8601String(),
    };
  }
}

class FSRSEngine {
  final double requestRetention;
  final int maximumInterval;
  final List<double> w;

  FSRSEngine({
    this.requestRetention = 0.90,
    this.maximumInterval = 36500,
    List<double>? weights,
  }) : w =
           weights ??
           [
             0.4072,
             1.1829,
             3.1262,
             15.4722,
             7.2102,
             0.5316,
             1.0651,
             0.0234,
             1.616,
             0.1544,
             1.0824,
             1.9813,
             0.0953,
             0.2975,
             2.2042,
             0.2407,
             2.9466,
           ];

  double retrievability(double elapsedDays, double stability) {
    if (stability <= 0.0) return 0.0;
    return pow(1.0 + 19.0 / 81.0 * elapsedDays / stability, -0.5).toDouble();
  }

  int nextInterval(double stability) {
    final interval =
        (stability / 19.0 * 81.0 * (pow(requestRetention, -2.0) - 1.0)).round();
    return interval.clamp(1, maximumInterval);
  }

  double initDifficulty(FSRSRating rating) {
    final grade = rating.index + 1.0;
    final d = w[4] - exp(w[5] * (grade - 3.0)) + 1.0;
    return d.clamp(1.0, 10.0);
  }

  double initStability(FSRSRating rating) {
    final idx = rating.index;
    return max(w[idx], 0.1);
  }

  double nextDifficulty(double d, FSRSRating rating) {
    final grade = rating.index + 1.0;
    final nextD = d - w[6] * (grade - 3.0);
    final meanReversion =
        w[7] * initDifficulty(FSRSRating.easy) + (1.0 - w[7]) * nextD;
    return meanReversion.clamp(1.0, 10.0);
  }

  double stabilityAfterRecall(double d, double s, double r, FSRSRating rating) {
    final hardPenalty = rating == FSRSRating.hard ? w[15] : 1.0;
    final easyBonus = rating == FSRSRating.easy ? w[16] : 1.0;
    return s *
        (1.0 +
            exp(w[8]) *
                (11.0 - d) *
                pow(s, -w[9]) *
                (exp((1.0 - r) * w[10]) - 1.0) *
                hardPenalty *
                easyBonus);
  }

  double stabilityAfterForget(double d, double s, double r) {
    final sNew =
        w[11] *
        pow(d, -w[12]) *
        (pow(s + 1.0, w[13]) - 1.0) *
        exp((1.0 - r) * w[14]);
    return sNew.clamp(0.1, s);
  }

  FSRSCard review(FSRSCard card, FSRSRating rating, DateTime reviewTime) {
    final elapsedDays =
        max(0, reviewTime.difference(card.lastReview).inSeconds) / 86400.0;
    final r = retrievability(elapsedDays, card.stability);

    var state = card.state;
    var reps = card.reps + 1;
    var lapses = card.lapses;
    var difficulty = card.difficulty;
    var stability = card.stability;
    DateTime nextReview;

    switch (card.state) {
      case FSRSState.newCard:
        difficulty = initDifficulty(rating);
        stability = initStability(rating);
        if (rating == FSRSRating.again) {
          state = FSRSState.learning;
          lapses += 1;
          nextReview = reviewTime.add(const Duration(minutes: 10));
        } else {
          state = FSRSState.review;
          final interval = nextInterval(stability);
          nextReview = reviewTime.add(Duration(days: interval));
        }
        break;

      case FSRSState.learning:
      case FSRSState.relearning:
        difficulty = nextDifficulty(card.difficulty, rating);
        if (rating == FSRSRating.again) {
          nextReview = reviewTime.add(const Duration(minutes: 10));
        } else {
          state = FSRSState.review;
          stability = initStability(rating);
          final interval = nextInterval(stability);
          nextReview = reviewTime.add(Duration(days: interval));
        }
        break;

      case FSRSState.review:
        difficulty = nextDifficulty(card.difficulty, rating);
        if (rating == FSRSRating.again) {
          state = FSRSState.relearning;
          lapses += 1;
          stability = stabilityAfterForget(card.difficulty, card.stability, r);
          nextReview = reviewTime.add(const Duration(minutes: 10));
        } else {
          stability = stabilityAfterRecall(
            card.difficulty,
            card.stability,
            r,
            rating,
          );
          final interval = nextInterval(stability);
          nextReview = reviewTime.add(Duration(days: interval));
        }
        break;
    }

    return FSRSCard(
      itemId: card.itemId,
      state: state,
      stability: stability,
      difficulty: difficulty,
      reps: reps,
      lapses: lapses,
      lastReview: reviewTime,
      nextReview: nextReview,
    );
  }
}
