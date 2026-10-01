use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LessonItem {
    pub id: String,
    pub language: String, // "en" or "ja"
    pub category: String, // "alphabet", "kanji", "vocabulary_core", "it_workplace", "daily"
    pub target_text: String,
    pub phonetic_or_kana: String,
    pub meaning_vi: String,
    pub workplace_context: String,
    pub workplace_context_vi: String,
    pub stroke_order_hints: Vec<String>,
    pub difficulty_level: u8,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReviewRequest {
    pub item_id: String,
    pub rating: u8, // 1=Again, 2=Hard, 3=Good, 4=Easy
}

#[derive(Debug, Clone, Serialize)]
pub struct ReviewResponse {
    pub item_id: String,
    pub state: String,
    pub reps: u32,
    pub stability: f64,
    pub difficulty: f64,
    pub next_review: chrono::DateTime<chrono::Utc>,
    pub interval_days: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
pub struct RoleplayRequest {
    pub target_language: String, // "en" | "ja"
    pub topic: String,           // e.g. "daily_standup", "code_review", "interview"
    pub user_level: String,      // "beginner" | "intermediate"
    pub user_message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RoleplayResponse {
    pub reply: String,
    pub reply_translation_vi: String,
    pub breakdown: Vec<DialogueBreakdown>,
    pub writing_challenge: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DialogueBreakdown {
    pub word: String,
    pub meaning_vi: String,
    pub kana_or_phonetic: String,
}
