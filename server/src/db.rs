use chrono::{DateTime, Utc};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::time::Duration;

use crate::fsrs::{FSRSCard, State};
use crate::models::LessonItem;

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct DbLessonItem {
    pub id: String,
    pub language: String,
    pub category: String,
    pub target_text: String,
    pub phonetic_or_kana: String,
    pub meaning_vi: String,
    pub workplace_context: String,
    pub workplace_context_vi: String,
    pub stroke_order_hints: sqlx::types::Json<Vec<String>>,
    pub difficulty_level: i16,
    pub created_at: DateTime<Utc>,
}

impl From<DbLessonItem> for LessonItem {
    fn from(db: DbLessonItem) -> Self {
        Self {
            id: db.id,
            language: db.language,
            category: db.category,
            target_text: db.target_text,
            phonetic_or_kana: db.phonetic_or_kana,
            meaning_vi: db.meaning_vi,
            workplace_context: db.workplace_context,
            workplace_context_vi: db.workplace_context_vi,
            stroke_order_hints: db.stroke_order_hints.0,
            difficulty_level: db.difficulty_level as u8,
        }
    }
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct DbFsrsCard {
    pub item_id: String,
    pub state: i16,
    pub stability: f64,
    pub difficulty: f64,
    pub reps: i32,
    pub lapses: i32,
    pub last_review: DateTime<Utc>,
    pub next_review: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<DbFsrsCard> for FSRSCard {
    fn from(db: DbFsrsCard) -> Self {
        let state = match db.state {
            1 => State::Learning,
            2 => State::Review,
            3 => State::Relearning,
            _ => State::New,
        };
        Self {
            item_id: db.item_id,
            state,
            stability: db.stability,
            difficulty: db.difficulty,
            reps: db.reps as u32,
            lapses: db.lapses as u32,
            last_review: db.last_review,
            next_review: db.next_review,
        }
    }
}

/// Initialize PostgreSQL connection pool and run pending migrations.
/// Falls back gracefully to None if connection fails or DATABASE_URL is not set.
pub async fn init_pool(database_url: Option<&str>) -> Option<PgPool> {
    let url = match database_url {
        Some(u) if !u.trim().is_empty() => u.trim(),
        _ => {
            tracing::info!("DATABASE_URL not configured. Operating with in-memory fallback store.");
            return None;
        }
    };

    tracing::info!("Connecting to PostgreSQL database...");
    let pool = match PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(2))
        .connect(url)
        .await
    {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(
                "Failed to connect to PostgreSQL at {}: {}. Falling back to in-memory store.",
                url,
                e
            );
            return None;
        }
    };

    tracing::info!("Executing database migrations...");
    if let Err(e) = sqlx::migrate!("./migrations").run(&pool).await {
        tracing::warn!(
            "Failed to run database migrations: {}. Falling back to in-memory store.",
            e
        );
        return None;
    }

    tracing::info!("PostgreSQL connection pool and migrations ready.");
    Some(pool)
}

/// Seeds database with initial curriculum lessons if table is currently empty.
pub async fn seed_lessons_if_empty(
    pool: &PgPool,
    lessons: &[LessonItem],
) -> Result<(), sqlx::Error> {
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM lessons")
        .fetch_one(pool)
        .await?;
    if count.0 == 0 {
        tracing::info!(
            "Seeding PostgreSQL with {} initial lessons...",
            lessons.len()
        );
        for l in lessons {
            let hints = sqlx::types::Json(&l.stroke_order_hints);
            sqlx::query(
                r#"
                INSERT INTO lessons (
                    id, language, category, target_text, phonetic_or_kana,
                    meaning_vi, workplace_context, workplace_context_vi,
                    stroke_order_hints, difficulty_level
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                ON CONFLICT (id) DO NOTHING
                "#,
            )
            .bind(&l.id)
            .bind(&l.language)
            .bind(&l.category)
            .bind(&l.target_text)
            .bind(&l.phonetic_or_kana)
            .bind(&l.meaning_vi)
            .bind(&l.workplace_context)
            .bind(&l.workplace_context_vi)
            .bind(hints)
            .bind(l.difficulty_level as i16)
            .execute(pool)
            .await?;
        }
        tracing::info!("Initial curriculum seeding completed.");
    }
    Ok(())
}

/// Fetches lessons with optional language and category filters using dynamic queries.
pub async fn fetch_lessons(
    pool: &PgPool,
    language: Option<&str>,
    category: Option<&str>,
) -> Result<Vec<LessonItem>, sqlx::Error> {
    let mut query_str = "SELECT id, language, category, target_text, phonetic_or_kana, meaning_vi, workplace_context, workplace_context_vi, stroke_order_hints, difficulty_level, created_at FROM lessons WHERE 1=1".to_string();
    let mut bindings: Vec<String> = Vec::new();

    if let Some(lang) = language {
        bindings.push(lang.to_string());
        query_str.push_str(&format!(" AND language = ${}", bindings.len()));
    }
    if let Some(cat) = category {
        bindings.push(cat.to_string());
        query_str.push_str(&format!(" AND category = ${}", bindings.len()));
    }
    query_str.push_str(" ORDER BY id ASC");

    let mut q = sqlx::query_as::<_, DbLessonItem>(&query_str);
    for b in &bindings {
        q = q.bind(b);
    }

    let rows = q.fetch_all(pool).await?;
    Ok(rows.into_iter().map(LessonItem::from).collect())
}

/// Fetches a single lesson by ID from the database.
pub async fn fetch_lesson_by_id(
    pool: &PgPool,
    id: &str,
) -> Result<Option<LessonItem>, sqlx::Error> {
    let row = sqlx::query_as::<_, DbLessonItem>(
        "SELECT id, language, category, target_text, phonetic_or_kana, meaning_vi, workplace_context, workplace_context_vi, stroke_order_hints, difficulty_level, created_at FROM lessons WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(LessonItem::from))
}

/// Fetches a card record by item_id from the database.
pub async fn fetch_card_by_id(
    pool: &PgPool,
    item_id: &str,
) -> Result<Option<FSRSCard>, sqlx::Error> {
    let row = sqlx::query_as::<_, DbFsrsCard>(
        "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards WHERE item_id = $1",
    )
    .bind(item_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(FSRSCard::from))
}

/// Inserts or updates an FSRS card in PostgreSQL.
/// Ensures parent lesson exists to maintain foreign key integrity for ad-hoc/custom practice items.
pub async fn upsert_card(pool: &PgPool, card: &FSRSCard) -> Result<(), sqlx::Error> {
    let hints = sqlx::types::Json(Vec::<String>::new());
    sqlx::query(
        r#"
        INSERT INTO lessons (
            id, language, category, target_text, phonetic_or_kana,
            meaning_vi, workplace_context, workplace_context_vi,
            stroke_order_hints, difficulty_level
        ) VALUES ($1, 'custom', 'custom', $1, '', 'Custom card', '', '', $2, 1)
        ON CONFLICT (id) DO NOTHING
        "#,
    )
    .bind(&card.item_id)
    .bind(hints)
    .execute(pool)
    .await?;

    let state_i16 = card.state as i16;
    sqlx::query(
        r#"
        INSERT INTO fsrs_cards (
            item_id, state, stability, difficulty, reps, lapses,
            last_review, next_review, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
        ON CONFLICT (item_id) DO UPDATE SET
            state = EXCLUDED.state,
            stability = EXCLUDED.stability,
            difficulty = EXCLUDED.difficulty,
            reps = EXCLUDED.reps,
            lapses = EXCLUDED.lapses,
            last_review = EXCLUDED.last_review,
            next_review = EXCLUDED.next_review,
            updated_at = NOW()
        "#,
    )
    .bind(&card.item_id)
    .bind(state_i16)
    .bind(card.stability)
    .bind(card.difficulty)
    .bind(card.reps as i32)
    .bind(card.lapses as i32)
    .bind(card.last_review)
    .bind(card.next_review)
    .execute(pool)
    .await?;

    Ok(())
}

/// Fetches all cards scheduled for review at or before `now`.
pub async fn fetch_due_cards(
    pool: &PgPool,
    now: DateTime<Utc>,
) -> Result<Vec<FSRSCard>, sqlx::Error> {
    let rows = sqlx::query_as::<_, DbFsrsCard>(
        "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards WHERE next_review <= $1",
    )
    .bind(now)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(FSRSCard::from).collect())
}

/// Fetches item IDs for all cards that have been reviewed at least once.
pub async fn fetch_all_reviewed_card_ids(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    let rows: Vec<(String,)> = sqlx::query_as("SELECT item_id FROM fsrs_cards")
        .fetch_all(pool)
        .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}
