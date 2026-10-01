use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// FSRS State of a card
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum State {
    New = 0,
    Learning = 1,
    Review = 2,
    Relearning = 3,
}

/// User rating for a review
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Rating {
    Again = 1,
    Hard = 2,
    Good = 3,
    Easy = 4,
}

/// FSRS Card Progress Record
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FSRSCard {
    pub item_id: String,
    pub state: State,
    pub stability: f64,
    pub difficulty: f64,
    pub reps: u32,
    pub lapses: u32,
    pub last_review: DateTime<Utc>,
    pub next_review: DateTime<Utc>,
}

impl FSRSCard {
    pub fn new(item_id: String) -> Self {
        let now = Utc::now();
        Self {
            item_id,
            state: State::New,
            stability: 0.0,
            difficulty: 0.0,
            reps: 0,
            lapses: 0,
            last_review: now,
            next_review: now,
        }
    }
}

/// FSRS-4.5 Scheduler implementation
#[derive(Debug, Clone)]
#[allow(clippy::upper_case_acronyms)]
pub struct FSRS {
    pub request_retention: f64, // target retention rate, e.g. 0.90
    pub maximum_interval: i64,  // in days, e.g. 36500
    pub w: [f64; 17],           // standard default weights
}

impl Default for FSRS {
    fn default() -> Self {
        Self {
            request_retention: 0.90,
            maximum_interval: 36500,
            // Standard default weights from FSRS-4.5
            w: [
                0.4072, 1.1829, 3.1262,
                15.4722, // initial stability for Again, Hard, Good, Easy
                7.2102, 0.5316, 1.0651, 0.0234, // difficulty parameters
                1.616, 0.1544, 1.0824, // stability parameters after recall
                1.9813, 0.0953, 0.2975, 2.2042, // stability parameters after forget
                0.2407, 2.9466, // short term parameters
            ],
        }
    }
}

impl FSRS {
    /// Calculate retrievability at elapsed days t given stability S
    pub fn retrievability(&self, elapsed_days: f64, stability: f64) -> f64 {
        if stability <= 0.0 {
            return 0.0;
        }
        (1.0 + 19.0 / 81.0 * elapsed_days / stability).powf(-0.5)
    }

    /// Calculate next interval from stability S and target retention
    pub fn next_interval(&self, stability: f64) -> i64 {
        let interval =
            (stability / 19.0 * 81.0 * (self.request_retention.powf(-2.0) - 1.0)).round() as i64;
        interval.clamp(1, self.maximum_interval)
    }

    /// Initial difficulty when card is first rated
    fn init_difficulty(&self, rating: Rating) -> f64 {
        let grade = rating as i32 as f64;
        let d = self.w[4] - (self.w[5] * (grade - 3.0)).exp() + 1.0;
        d.clamp(1.0, 10.0)
    }

    /// Initial stability when card is first rated
    fn init_stability(&self, rating: Rating) -> f64 {
        let idx = (rating as usize) - 1;
        self.w[idx].max(0.1)
    }

    /// Update difficulty after review
    fn next_difficulty(&self, d: f64, rating: Rating) -> f64 {
        let grade = rating as i32 as f64;
        let next_d = d - self.w[6] * (grade - 3.0);
        let mean_reversion =
            self.w[7] * self.init_difficulty(Rating::Easy) + (1.0 - self.w[7]) * next_d;
        mean_reversion.clamp(1.0, 10.0)
    }

    /// Stability after successful recall
    fn stability_after_recall(&self, d: f64, s: f64, r: f64, rating: Rating) -> f64 {
        let hard_penalty = if rating == Rating::Hard {
            self.w[15]
        } else {
            1.0
        };
        let easy_bonus = if rating == Rating::Easy {
            self.w[16]
        } else {
            1.0
        };
        s * (1.0
            + (self.w[8]).exp()
                * (11.0 - d)
                * s.powf(-self.w[9])
                * (((1.0 - r) * self.w[10]).exp() - 1.0)
                * hard_penalty
                * easy_bonus)
    }

    /// Stability after forgetting (Again)
    fn stability_after_forget(&self, d: f64, s: f64, r: f64) -> f64 {
        (self.w[11]
            * d.powf(-self.w[12])
            * ((s + 1.0).powf(self.w[13]) - 1.0)
            * ((1.0 - r) * self.w[14]).exp())
        .clamp(0.1, s)
    }

    /// Process a review for a card at review_time
    pub fn review(&self, card: &FSRSCard, rating: Rating, review_time: DateTime<Utc>) -> FSRSCard {
        let mut updated = card.clone();
        let elapsed_days = (review_time - card.last_review).num_seconds().max(0) as f64 / 86400.0;
        let r = self.retrievability(elapsed_days, card.stability);

        match card.state {
            State::New => {
                updated.difficulty = self.init_difficulty(rating);
                updated.stability = self.init_stability(rating);
                updated.reps = 1;
                if rating == Rating::Again {
                    updated.state = State::Learning;
                    updated.lapses = 1;
                    updated.next_review = review_time + Duration::minutes(10);
                } else {
                    updated.state = State::Review;
                    let interval = self.next_interval(updated.stability);
                    updated.next_review = review_time + Duration::days(interval);
                }
            }
            State::Learning | State::Relearning => {
                updated.difficulty = self.next_difficulty(card.difficulty, rating);
                if rating == Rating::Again {
                    updated.reps += 1;
                    updated.next_review = review_time + Duration::minutes(10);
                } else {
                    updated.state = State::Review;
                    updated.stability = self.init_stability(rating);
                    updated.reps += 1;
                    let interval = self.next_interval(updated.stability);
                    updated.next_review = review_time + Duration::days(interval);
                }
            }
            State::Review => {
                updated.reps += 1;
                updated.difficulty = self.next_difficulty(card.difficulty, rating);

                if rating == Rating::Again {
                    updated.state = State::Relearning;
                    updated.lapses += 1;
                    updated.stability =
                        self.stability_after_forget(card.difficulty, card.stability, r);
                    updated.next_review = review_time + Duration::minutes(10);
                } else {
                    updated.stability =
                        self.stability_after_recall(card.difficulty, card.stability, r, rating);
                    let interval = self.next_interval(updated.stability);
                    updated.next_review = review_time + Duration::days(interval);
                }
            }
        }

        updated.last_review = review_time;
        updated
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_card_initial_good() {
        let fsrs = FSRS::default();
        let card = FSRSCard::new("word_1".to_string());
        let now = Utc::now();
        let updated = fsrs.review(&card, Rating::Good, now);

        assert_eq!(updated.state, State::Review);
        assert_eq!(updated.reps, 1);
        assert!(updated.stability > 0.0);
        assert!(updated.difficulty >= 1.0 && updated.difficulty <= 10.0);
        assert!(updated.next_review > now);
    }

    #[test]
    fn test_new_card_again_enters_learning() {
        let fsrs = FSRS::default();
        let card = FSRSCard::new("word_2".to_string());
        let now = Utc::now();
        let updated = fsrs.review(&card, Rating::Again, now);

        assert_eq!(updated.state, State::Learning);
        assert_eq!(updated.lapses, 1);
        // scheduled roughly 10 minutes later
        let diff = (updated.next_review - now).num_minutes();
        assert_eq!(diff, 10);
    }

    #[test]
    fn test_review_card_spaced_intervals_increase() {
        let fsrs = FSRS::default();
        let mut card = FSRSCard::new("word_3".to_string());
        let mut time = Utc::now();

        // 1st review: Good
        card = fsrs.review(&card, Rating::Good, time);
        let first_interval = (card.next_review - time).num_days();

        // Simulate advancing time to next review
        time = card.next_review;
        card = fsrs.review(&card, Rating::Good, time);
        let second_interval = (card.next_review - time).num_days();

        assert!(
            second_interval >= first_interval,
            "Interval should expand on consecutive Good ratings (first: {first_interval}, second: {second_interval})"
        );
    }
}
