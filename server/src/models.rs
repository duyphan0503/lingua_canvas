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

fn default_profession() -> String {
    "it".to_string()
}

fn default_difficulty_level() -> String {
    "beginner".to_string()
}

#[derive(Debug, Clone, Deserialize)]
pub struct RoleplayRequest {
    #[serde(alias = "language")]
    pub target_language: String, // "en" | "ja"
    #[serde(alias = "context")]
    pub topic: String, // e.g. "daily_standup", "code_review", "interview"
    #[serde(alias = "difficulty", alias = "difficulty_level")]
    pub user_level: String, // "beginner" | "intermediate" | "advanced"
    #[serde(default, alias = "message")]
    pub user_message: String,
    #[serde(default = "default_profession", alias = "domain")]
    pub profession: String, // "it" | "hospitality" | "business" | "general"
}

#[derive(Debug, Clone, PartialEq)]
pub struct RoleplayResponse {
    pub reply: String,
    pub reply_translation_vi: String,
    pub breakdown: Vec<DialogueBreakdown>,
    pub writing_challenge: String,
    pub grammar_hints: Option<Vec<GrammarHint>>,
    pub suggested_replies: Option<Vec<String>>,
}

impl RoleplayResponse {
    pub fn opening_line(&self) -> &str {
        &self.reply
    }

    pub fn suggested_responses(&self) -> Option<&[String]> {
        self.suggested_replies.as_deref()
    }
}

impl Serialize for RoleplayResponse {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut count = 5;
        if self.grammar_hints.is_some() {
            count += 1;
        }
        if self.suggested_replies.is_some() {
            count += 2;
        }
        let mut s = serializer.serialize_struct("RoleplayResponse", count)?;
        s.serialize_field("reply", &self.reply)?;
        s.serialize_field("opening_line", &self.reply)?;
        s.serialize_field("reply_translation_vi", &self.reply_translation_vi)?;
        s.serialize_field("breakdown", &self.breakdown)?;
        s.serialize_field("writing_challenge", &self.writing_challenge)?;
        if let Some(ref gh) = self.grammar_hints {
            s.serialize_field("grammar_hints", gh)?;
        }
        if let Some(ref sr) = self.suggested_replies {
            s.serialize_field("suggested_replies", sr)?;
            s.serialize_field("suggested_responses", sr)?;
        }
        s.end()
    }
}

#[derive(Deserialize)]
struct RoleplayResponseHelper {
    #[serde(default)]
    reply: Option<String>,
    #[serde(default)]
    opening_line: Option<String>,
    #[serde(default)]
    reply_translation_vi: Option<String>,
    #[serde(default)]
    breakdown: Option<Vec<DialogueBreakdown>>,
    #[serde(default)]
    writing_challenge: Option<String>,
    #[serde(default)]
    grammar_hints: Option<Vec<GrammarHint>>,
    #[serde(default)]
    suggested_replies: Option<Vec<String>>,
    #[serde(default)]
    suggested_responses: Option<Vec<String>>,
}

impl<'de> Deserialize<'de> for RoleplayResponse {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let helper = RoleplayResponseHelper::deserialize(deserializer)?;
        let reply = helper.reply.or(helper.opening_line).unwrap_or_default();
        let suggested_replies = helper.suggested_replies.or(helper.suggested_responses);

        Ok(RoleplayResponse {
            reply,
            reply_translation_vi: helper.reply_translation_vi.unwrap_or_default(),
            breakdown: helper.breakdown.unwrap_or_default(),
            writing_challenge: helper.writing_challenge.unwrap_or_default(),
            grammar_hints: helper.grammar_hints,
            suggested_replies,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DialogueBreakdown {
    pub word: String,
    pub meaning_vi: String,
    pub kana_or_phonetic: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GrammarHint {
    pub pattern: String,
    pub explanation_vi: String,
    pub example: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DialogueLine {
    pub speaker: String,
    pub text: String,
    pub translation_vi: String,
    pub phonetic_or_romaji: String,
}

impl DialogueLine {
    pub fn translation(&self) -> &str {
        &self.translation_vi
    }

    pub fn romaji(&self) -> &str {
        &self.phonetic_or_romaji
    }
}

impl Serialize for DialogueLine {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut s = serializer.serialize_struct("DialogueLine", 6)?;
        s.serialize_field("speaker", &self.speaker)?;
        s.serialize_field("text", &self.text)?;
        s.serialize_field("translation_vi", &self.translation_vi)?;
        s.serialize_field("translation", &self.translation_vi)?;
        s.serialize_field("phonetic_or_romaji", &self.phonetic_or_romaji)?;
        s.serialize_field("romaji", &self.phonetic_or_romaji)?;
        s.end()
    }
}

#[derive(Deserialize)]
struct DialogueLineHelper {
    speaker: String,
    text: String,
    #[serde(default)]
    translation_vi: Option<String>,
    #[serde(default)]
    translation: Option<String>,
    #[serde(default)]
    phonetic_or_romaji: Option<String>,
    #[serde(default)]
    romaji: Option<String>,
}

impl<'de> Deserialize<'de> for DialogueLine {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let helper = DialogueLineHelper::deserialize(deserializer)?;
        let translation_vi = helper
            .translation_vi
            .or(helper.translation)
            .unwrap_or_default();
        let phonetic_or_romaji = helper
            .phonetic_or_romaji
            .or(helper.romaji)
            .unwrap_or_default();

        Ok(DialogueLine {
            speaker: helper.speaker,
            text: helper.text,
            translation_vi,
            phonetic_or_romaji,
        })
    }
}

fn deserialize_turn_count<'de, D>(deserializer: D) -> Result<Option<u8>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<u8>::deserialize(deserializer)?;
    Ok(opt.map(|t| t.clamp(2, 10)))
}

#[derive(Debug, Clone, Deserialize)]
pub struct DialogueRequest {
    #[serde(alias = "language")]
    pub target_language: String, // "en" | "ja"
    #[serde(default = "default_profession", alias = "domain")]
    pub profession: String, // "it" | "hospitality" | "business" | "general"
    #[serde(
        default = "default_difficulty_level",
        alias = "difficulty",
        alias = "user_level"
    )]
    pub difficulty_level: String, // "beginner" | "intermediate" | "advanced"
    #[serde(alias = "context")]
    pub topic: Option<String>,
    #[serde(default, alias = "turns", deserialize_with = "deserialize_turn_count")]
    pub turn_count: Option<u8>,
}

impl DialogueRequest {
    pub fn clamped_turns(&self) -> u8 {
        self.turn_count.unwrap_or(4).clamp(2, 10)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DialogueResponse {
    pub topic: String,
    pub profession: String,
    pub difficulty_level: String,
    pub title: String,
    pub title_vi: String,
    pub lines: Vec<DialogueLine>,
    pub vocabulary: Vec<DialogueBreakdown>,
    pub grammar_hints: Vec<GrammarHint>,
    pub suggested_writing_targets: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FsrsCardDto {
    pub item_id: String,
    pub state: String,
    pub stability: f64,
    pub difficulty: f64,
    pub reps: u32,
    pub lapses: u32,
    pub last_review: chrono::DateTime<chrono::Utc>,
    pub next_review: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

impl FsrsCardDto {
    pub fn from_card(
        card: &crate::fsrs::FSRSCard,
        updated_at: Option<chrono::DateTime<chrono::Utc>>,
    ) -> Self {
        Self {
            item_id: card.item_id.clone(),
            state: format!("{:?}", card.state),
            stability: card.stability,
            difficulty: card.difficulty,
            reps: card.reps,
            lapses: card.lapses,
            last_review: card.last_review,
            next_review: card.next_review,
            updated_at: updated_at.unwrap_or(card.last_review),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncReviewItem {
    #[serde(alias = "id")]
    pub review_id: Option<String>,
    pub item_id: String,
    pub rating: u8,
    #[serde(default)]
    pub state: Option<u8>,
    pub review_time: chrono::DateTime<chrono::Utc>,
    #[serde(default)]
    pub elapsed_days: Option<f64>,
    #[serde(default)]
    pub scheduled_days: Option<i32>,
    #[serde(default)]
    pub client_card_snapshot: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncCompletedLessonItem {
    pub lesson_id: String,
    pub completed_at: chrono::DateTime<chrono::Utc>,
    #[serde(default)]
    pub score: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncPushRequest {
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub last_sync_time: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub reviews: Vec<SyncReviewItem>,
    #[serde(default)]
    pub completed_lessons: Option<Vec<SyncCompletedLessonItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncPushResponse {
    pub synced_reviews: usize,
    pub synced_lessons: usize,
    pub synced_review_ids: Vec<String>,
    pub synced_completed_lesson_ids: Vec<String>,
    pub updated_cards: Vec<FsrsCardDto>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub server_time: chrono::DateTime<chrono::Utc>,
}

pub fn deserialize_optional_datetime<'de, D>(
    deserializer: D,
) -> Result<Option<chrono::DateTime<chrono::Utc>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<String>::deserialize(deserializer)?;
    match opt {
        Some(s) if !s.trim().is_empty() => {
            let s_fixed = s.replace(' ', "+");
            chrono::DateTime::parse_from_rfc3339(&s_fixed)
                .map(|dt| Some(dt.with_timezone(&chrono::Utc)))
                .or_else(|_| {
                    chrono::NaiveDateTime::parse_from_str(&s_fixed, "%Y-%m-%dT%H:%M:%S")
                        .map(|ndt| Some(ndt.and_utc()))
                })
                .map_err(serde::de::Error::custom)
        }
        _ => Ok(None),
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct SyncPullQuery {
    #[serde(default, deserialize_with = "deserialize_optional_datetime")]
    pub since: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default, deserialize_with = "deserialize_optional_datetime")]
    pub last_sync_time: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncPullResponse {
    pub cards: Vec<FsrsCardDto>,
    pub updated_cards: Vec<FsrsCardDto>,
    pub lessons: Vec<LessonItem>,
    pub new_lessons: Vec<LessonItem>,
    pub server_time: chrono::DateTime<chrono::Utc>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
}
