use super::{
    auth::{self, Identity, DEFAULT_USER},
    AppState,
};
use crate::{
    db::{self, DbFsrsCard, DbLessonItem},
    fsrs::{FSRSCard, Rating},
    models::{
        FsrsCardDto, SyncCompletedLessonItem, SyncPullQuery, SyncPullResponse, SyncPushRequest,
        SyncPushResponse,
    },
};
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{DateTime, Duration, Utc};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc,
    },
};
use tokio::sync::{Mutex, RwLock};
type CompletedEntry = (SyncCompletedLessonItem, i64, DateTime<Utc>);
#[derive(Default)]
pub struct MemorySync {
    sequence: AtomicI64,
    card_seq: RwLock<HashMap<String, i64>>,
    completed: RwLock<HashMap<String, CompletedEntry>>,
    locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
}
impl MemorySync {
    pub async fn user_lock(&self, user: &str) -> Arc<Mutex<()>> {
        self.locks
            .lock()
            .await
            .entry(user.into())
            .or_default()
            .clone()
    }
    async fn changed(&self, key: String) {
        let seq = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        self.card_seq.write().await.insert(key, seq);
    }
}
pub fn key(user: &str, item: &str) -> String {
    if user == DEFAULT_USER {
        item.into()
    } else {
        format!("\0{}", serde_json::to_string(&(user, item)).unwrap())
    }
}
fn owns(user: &str, key: &str) -> bool {
    if user == DEFAULT_USER {
        !key.starts_with('\0')
    } else {
        serde_json::from_str::<(String, String)>(key.strip_prefix('\0').unwrap_or(""))
            .is_ok_and(|(u, _)| u == user)
    }
}
fn error(e: sqlx::Error) -> StatusCode {
    tracing::warn!("Sync storage failed: {e}");
    StatusCode::INTERNAL_SERVER_ERROR
}
pub async fn writer_lock(tx: &mut sqlx::PgConnection, user: &str) -> Result<(), StatusCode> {
    // Shared writers can update independent cards concurrently. Pull takes the same account's exclusive barrier.
    sqlx::query("SELECT pg_advisory_xact_lock_shared(0,hashtext($1))")
        .bind(user)
        .execute(tx)
        .await
        .map_err(error)?;
    Ok(())
}
pub async fn card_lock(
    tx: &mut sqlx::PgConnection,
    user: &str,
    item: &str,
) -> Result<(), StatusCode> {
    sqlx::query("SELECT pg_advisory_xact_lock(2,hashtext($1))")
        .bind(serde_json::to_string(&(user, item)).unwrap())
        .execute(tx)
        .await
        .map_err(error)?;
    Ok(())
}
pub async fn record_memory_card(state: &AppState, user: &str, card: FSRSCard) {
    let k = key(user, &card.item_id);
    state.cards.write().await.insert(k.clone(), card);
    state
        .card_updated_at
        .write()
        .await
        .insert(k.clone(), Utc::now());
    state.memory.changed(k).await;
}
pub async fn push_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<Identity>,
    Json(req): Json<SyncPushRequest>,
) -> Result<Json<SyncPushResponse>, StatusCode> {
    let user = auth::resolve(
        &state,
        &headers,
        &Identity {
            user_id: req.user_id.clone(),
            sync_token: req.sync_token.clone(),
        }
        .merge(identity)?,
    )
    .await?;
    if req.reviews.iter().any(|r| {
        r.item_id.contains('\0') || r.review_id.as_ref().is_some_and(|id| id.contains('\0'))
    }) || req
        .completed_lessons
        .as_ref()
        .is_some_and(|all| all.iter().any(|c| c.lesson_id.contains('\0')))
        || req.since_seq.is_some_and(|s| s < 0)
        || req.reviews.iter().any(|r| !(1..=4).contains(&r.rating))
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let client = req.client_id.as_deref().unwrap_or("default_device");
    let now = Utc::now();
    let lock = state.memory.user_lock(&user).await;
    let _guard = if state.pool.is_none() {
        Some(lock.lock().await)
    } else {
        None
    };
    let mut ids = Vec::new();
    let mut updated = HashMap::new();
    for rev in req.reviews {
        let rating = match rev.rating {
            1 => Rating::Again,
            2 => Rating::Hard,
            3 => Rating::Good,
            _ => Rating::Easy,
        };
        let time = if rev.review_time > now + Duration::minutes(5) {
            now
        } else {
            rev.review_time
        };
        let id = rev.review_id.unwrap_or_else(|| {
            format!("rev_{}_{}", rev.review_time.timestamp_millis(), rev.item_id)
        });
        let card_key = key(&user, &rev.item_id);
        let review_key = key(&user, &id);
        let mut tx = if let Some(p) = &state.pool {
            let mut tx = p.begin().await.map_err(error)?;
            writer_lock(&mut tx, &user).await?;
            sqlx::query("SELECT pg_advisory_xact_lock(1,hashtext($1))")
                .bind(serde_json::to_string(&(&user, &id)).unwrap())
                .execute(&mut *tx)
                .await
                .map_err(error)?;
            card_lock(&mut tx, &user, &rev.item_id).await?;
            Some(tx)
        } else {
            None
        };
        let seen = if let Some(tx) = &mut tx {
            sqlx::query_scalar::<_, String>(
                "SELECT item_id FROM review_logs WHERE user_id=$1 AND id=$2",
            )
            .bind(&user)
            .bind(&id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(error)?
        } else {
            state.seen_review_ids.read().await.get(&review_key).cloned()
        };
        if seen.as_ref().is_some_and(|item| item != &rev.item_id) {
            return Err(StatusCode::BAD_REQUEST);
        }
        let card = if let Some(tx) = &mut tx {
            db::fetch_card_by_id(tx, &rev.item_id, &user)
                .await
                .map_err(error)?
        } else {
            state.cards.read().await.get(&card_key).cloned()
        }
        .unwrap_or_else(|| FSRSCard::new(rev.item_id.clone()));
        let changed = seen.is_none() && (card.reps == 0 || time > card.last_review);
        let card = if changed {
            state.fsrs.review(&card, rating, time)
        } else {
            card
        };
        if let Some(tx) = &mut tx {
            if changed {
                db::upsert_card(tx, &card, &user).await.map_err(error)?;
            }
            if seen.is_none() {
                sqlx::query("INSERT INTO review_logs(user_id,id,item_id,client_id,rating,state,review_time,elapsed_days,scheduled_days,server_received_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,clock_timestamp()) ON CONFLICT(user_id,id) DO NOTHING").bind(&user).bind(&id).bind(&rev.item_id).bind(client).bind(rev.rating as i16).bind(card.state as i16).bind(time).bind(rev.elapsed_days.unwrap_or(0.0)).bind(rev.scheduled_days.unwrap_or_else(||((card.next_review-time).num_seconds() as f64/86400.0).round() as i32)).execute(&mut **tx).await.map_err(error)?;
            }
        }
        if let Some(tx) = tx {
            tx.commit().await.map_err(error)?;
        } else {
            if changed {
                record_memory_card(&state, &user, card.clone()).await;
            }
            state
                .seen_review_ids
                .write()
                .await
                .insert(review_key, rev.item_id.clone());
        }
        ids.push(id);
        updated.insert(rev.item_id, FsrsCardDto::from_card(&card, Some(now)));
    }
    let mut completed_ids = Vec::new();
    for comp in req.completed_lessons.unwrap_or_default() {
        if let Some(p) = &state.pool {
            let mut tx = p.begin().await.map_err(error)?;
            writer_lock(&mut tx, &user).await?;
            sqlx::query("INSERT INTO completed_lessons(user_id,lesson_id,client_id,completed_at,score) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,lesson_id,client_id) DO UPDATE SET completed_at=EXCLUDED.completed_at,score=EXCLUDED.score,updated_at=clock_timestamp(),sync_seq=nextval('sync_change_seq') WHERE completed_lessons.completed_at<EXCLUDED.completed_at").bind(&user).bind(&comp.lesson_id).bind(client).bind(comp.completed_at).bind(comp.score.unwrap_or(1.0)).execute(&mut *tx).await.map_err(error)?;
            tx.commit().await.map_err(error)?;
        } else {
            let k = serde_json::to_string(&(&user, &comp.lesson_id, client)).unwrap();
            let mut completed = state.memory.completed.write().await;
            if !completed
                .get(&k)
                .is_some_and(|(old, _, _)| old.completed_at >= comp.completed_at)
            {
                let seq = state.memory.sequence.fetch_add(1, Ordering::SeqCst) + 1;
                completed.insert(k, (comp.clone(), seq, Utc::now()));
            }
        }
        completed_ids.push(comp.lesson_id);
    }
    // Push did not deliver a complete snapshot: advancing here could skip concurrent cards.
    let latest_sync_seq = req.since_seq.unwrap_or(0);
    auth::seen_device(&state, &user, req.client_id.as_deref(), latest_sync_seq).await?;
    Ok(Json(SyncPushResponse {
        latest_sync_seq,
        synced_reviews: ids.len(),
        synced_lessons: completed_ids.len(),
        synced_review_ids: ids,
        synced_completed_lesson_ids: completed_ids,
        updated_cards: updated.into_values().collect(),
        timestamp: now,
        server_time: now,
    }))
}
pub async fn pull_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SyncPullQuery>,
) -> Result<Json<SyncPullResponse>, StatusCode> {
    let user = auth::resolve(
        &state,
        &headers,
        &Identity {
            user_id: query.user_id.clone(),
            sync_token: query.sync_token.clone(),
        },
    )
    .await?;
    if query.since_seq.is_some_and(|s| s < 0) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let since = query.since.or(query.last_sync_time);
    let seq = query.since_seq;
    let mut now = Utc::now();
    let mut cards = Vec::new();
    let lessons;
    let mut completed = Vec::new();
    let latest_sync_seq;
    if let Some(p) = &state.pool {
        let mut tx = p.begin().await.map_err(error)?;
        // Wait for existing writers; subsequent writers wait until this account's snapshot finishes.
        sqlx::query("SELECT pg_advisory_xact_lock(0,hashtext($1))")
            .bind(&user)
            .execute(&mut *tx)
            .await
            .map_err(error)?;
        now = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(error)?;
        latest_sync_seq=sqlx::query_scalar::<_,i64>("SELECT GREATEST(COALESCE((SELECT MAX(sync_seq) FROM fsrs_cards WHERE user_id=$1),0),COALESCE((SELECT MAX(sync_seq) FROM completed_lessons WHERE user_id=$1),0),COALESCE((SELECT MAX(sync_seq) FROM review_logs WHERE user_id=$1),0))").bind(&user).fetch_one(&mut *tx).await.map_err(error)?;
        let rows=sqlx::query_as::<_,DbFsrsCard>("SELECT item_id,state,stability,difficulty,reps,lapses,last_review,next_review,updated_at FROM fsrs_cards WHERE user_id=$1 AND (($2::BIGINT IS NOT NULL AND sync_seq>$2) OR ($2 IS NULL AND ($3::TIMESTAMPTZ IS NULL OR updated_at >= $3))) ORDER BY item_id").bind(&user).bind(seq).bind(since).fetch_all(&mut *tx).await.map_err(error)?;
        for row in rows {
            let at = row.updated_at;
            cards.push(FsrsCardDto::from_card(&row.into(), Some(at)));
        }
        completed=sqlx::query_as::<_,SyncCompletedLessonItem>("SELECT lesson_id,completed_at,score FROM completed_lessons WHERE user_id=$1 AND (($2::BIGINT IS NOT NULL AND sync_seq>$2) OR ($2 IS NULL AND ($3::TIMESTAMPTZ IS NULL OR updated_at >= $3))) ORDER BY lesson_id").bind(&user).bind(seq).bind(since).fetch_all(&mut *tx).await.map_err(error)?;
        // Only the public curriculum belongs in the global catalog; custom rows back private FSRS cards.
        // Always send a complete public catalog statement snapshot with sequence pulls.
        // A catalog insert committing out of sequence cannot be skipped by an account's cursor.
        lessons=sqlx::query_as::<_,DbLessonItem>("SELECT id,language,category,target_text,phonetic_or_kana,meaning_vi,workplace_context,workplace_context_vi,stroke_order_hints,difficulty_level,created_at FROM lessons WHERE category <> 'custom' AND ($1::BIGINT IS NOT NULL OR $2::TIMESTAMPTZ IS NULL OR created_at >= $2) ORDER BY id").bind(seq).bind(since).fetch_all(&mut *tx).await.map_err(error)?.into_iter().map(Into::into).collect();
        tx.commit().await.map_err(error)?;
    } else {
        let lock = state.memory.user_lock(&user).await;
        let _guard = lock.lock().await;
        let all = state.cards.read().await;
        let times = state.card_updated_at.read().await;
        let sequences = state.memory.card_seq.read().await;
        let mut latest = 0;
        for (k, card) in all.iter().filter(|(k, _)| owns(&user, k)) {
            let changed = sequences.get(k).copied().unwrap_or(0);
            latest = latest.max(changed);
            let at = times.get(k).copied().unwrap_or(card.last_review);
            if seq.map_or_else(|| since.is_none_or(|s| at >= s), |s| changed > s) {
                cards.push(FsrsCardDto::from_card(card, Some(at)));
            }
        }
        for (k, (comp, changed, at)) in state.memory.completed.read().await.iter() {
            if serde_json::from_str::<(String, String, String)>(k).is_ok_and(|(u, _, _)| u == user)
            {
                latest = latest.max(*changed);
                if seq.map_or_else(|| since.is_none_or(|s| *at >= s), |s| *changed > s) {
                    completed.push(comp.clone());
                }
            }
        }
        latest_sync_seq = latest;
        lessons = if seq.is_some() || since.is_none() {
            state
                .lessons
                .iter()
                .filter(|l| l.category != "custom")
                .cloned()
                .collect()
        } else {
            vec![]
        };
    }
    cards.sort_by(|a, b| a.item_id.cmp(&b.item_id));
    auth::seen_device(&state, &user, query.client_id.as_deref(), latest_sync_seq).await?;
    Ok(Json(SyncPullResponse {
        latest_sync_seq,
        completed_lessons: completed,
        cards: cards.clone(),
        updated_cards: cards,
        lessons: lessons.clone(),
        new_lessons: lessons,
        server_time: now,
        timestamp: now,
    }))
}
