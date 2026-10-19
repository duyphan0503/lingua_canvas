mod private;
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
    body::{Body, Bytes},
    extract::{FromRequest, Query, Request, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{DateTime, Duration, Utc};
use std::{
    collections::{HashMap, HashSet},
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
    private_lessons: RwLock<HashMap<String, (crate::models::PrivateLessonWireState, i64)>>,
    receipts: RwLock<HashMap<String, private::Receipt>>,
}
impl MemorySync {
    pub(super) async fn due_private_lesson(
        &self,
        user: &str,
        lesson_id: &str,
    ) -> Option<crate::models::LessonItem> {
        self.private_lessons
            .read()
            .await
            .get(&key(user, lesson_id))
            .and_then(|(state, _)| (!state.deleted).then(|| state.lesson.clone()))
    }

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
/// Acquire a complete batch in actual advisory-key order, including hash collisions.
/// Review writers and multi-card progress imports share this order.
async fn batch_locks(
    tx: &mut sqlx::PgConnection,
    user: &str,
    namespace: i32,
    items: &[String],
) -> Result<(), StatusCode> {
    let keys: Vec<String> = items
        .iter()
        .map(|item| serde_json::to_string(&(user, item)).unwrap())
        .collect();
    let hashes: Vec<i32> =
        sqlx::query_scalar("SELECT DISTINCT hashtext(k) FROM unnest($1::text[]) AS k ORDER BY 1")
            .bind(keys)
            .fetch_all(&mut *tx)
            .await
            .map_err(error)?;
    for key in hashes {
        sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
            .bind(namespace)
            .bind(key)
            .execute(&mut *tx)
            .await
            .map_err(error)?;
    }
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
/// Apply the private-protocol byte budget to the received HTTP body, including
/// fields a typed DTO would discard. Legacy review-only requests retain Axum's
/// existing body cap. The oversized probe skips entity values without allocating
/// metadata, and runs before the actual SyncPushRequest JSON decoding.
pub struct SyncPushJson(SyncPushRequest);
#[axum::async_trait]
impl<S: Send + Sync> FromRequest<S> for SyncPushJson {
    type Rejection = StatusCode;

    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        let (parts, body) = request.into_parts();
        let bytes = Bytes::from_request(Request::from_parts(parts.clone(), body), state)
            .await
            .map_err(|rejection| rejection.status())?;
        if bytes.len() > 512 * 1024 {
            #[derive(serde::Deserialize)]
            struct PrivateFeatureProbe {
                #[serde(default)]
                custom_lesson_mutations: Vec<serde::de::IgnoredAny>,
                #[serde(default)]
                progress_imports: Vec<serde::de::IgnoredAny>,
            }
            let probe: PrivateFeatureProbe =
                serde_json::from_slice(&bytes).map_err(|_| StatusCode::BAD_REQUEST)?;
            if !probe.custom_lesson_mutations.is_empty() || !probe.progress_imports.is_empty() {
                return Err(StatusCode::PAYLOAD_TOO_LARGE);
            }
        }
        let Json(request) = Json::<SyncPushRequest>::from_request(
            Request::from_parts(parts, Body::from(bytes)),
            state,
        )
        .await
        .map_err(|rejection| rejection.status())?;
        Ok(Self(request))
    }
}

pub async fn push_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<Identity>,
    SyncPushJson(req): SyncPushJson,
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
    private::validate(&req, &user, now)?;
    let lock = state.memory.user_lock(&user).await;
    let _guard = if state.pool.is_none() {
        Some(lock.lock().await)
    } else {
        None
    };
    let mut custom_lesson_acks = Vec::new();
    let mut custom_lesson_conflicts = Vec::new();
    let mut progress_import_acks = Vec::new();
    let mut blocked = HashSet::new();
    for mutation in &req.custom_lesson_mutations {
        if blocked.contains(&mutation.lesson.id) {
            continue;
        }
        match private::mutate(&state, &user, mutation).await? {
            private::MutationResult::Ack(state) => {
                custom_lesson_acks.push(crate::models::CustomLessonAck {
                    mutation_id: mutation.mutation_id.clone(),
                    state,
                })
            }
            private::MutationResult::Conflict(server) => {
                blocked.insert(mutation.lesson.id.clone());
                custom_lesson_conflicts.push(crate::models::CustomLessonConflict {
                    mutation_id: mutation.mutation_id.clone(),
                    server,
                });
            }
            private::MutationResult::Import => return Err(StatusCode::BAD_REQUEST),
        }
    }
    for import in &req.progress_imports {
        if import.cards.iter().any(|c| blocked.contains(&c.item_id))
            || import
                .completed_lessons
                .iter()
                .any(|c| blocked.contains(&c.lesson_id))
        {
            continue;
        }
        private::import(&state, &user, import).await?;
        progress_import_acks.push(import.mutation_id.clone());
    }
    let mut ids = Vec::new();
    let mut updated = HashMap::new();
    let review_ids: Vec<_> = req
        .reviews
        .iter()
        .filter(|rev| !blocked.contains(&rev.item_id))
        .map(|rev| {
            rev.review_id.clone().unwrap_or_else(|| {
                format!("rev_{}_{}", rev.review_time.timestamp_millis(), rev.item_id)
            })
        })
        .collect();
    let review_items: Vec<_> = req
        .reviews
        .iter()
        .filter(|rev| !blocked.contains(&rev.item_id))
        .map(|rev| rev.item_id.clone())
        .collect();
    let mut tx = if let Some(pool) = &state.pool {
        if review_ids.is_empty() {
            None
        } else {
            let mut tx = pool.begin().await.map_err(error)?;
            writer_lock(&mut tx, &user).await?;
            batch_locks(&mut tx, &user, 1, &review_ids).await?;
            batch_locks(&mut tx, &user, 2, &review_items).await?;
            Some(tx)
        }
    } else {
        None
    };
    for rev in req.reviews {
        if blocked.contains(&rev.item_id) {
            continue;
        }
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
        };
        // PostgreSQL stores microseconds; a retried nanosecond timestamp must not
        // become newer than an identical imported baseline after persistence.
        let changed = seen.is_none()
            && card
                .as_ref()
                .is_none_or(|card| time.timestamp_micros() > card.last_review.timestamp_micros());
        let card = card.unwrap_or_else(|| FSRSCard::new(rev.item_id.clone()));
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
        if tx.is_none() {
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
    if let Some(tx) = tx {
        tx.commit().await.map_err(error)?;
    }
    let mut completed_ids = Vec::new();
    for comp in req.completed_lessons.unwrap_or_default() {
        if blocked.contains(&comp.lesson_id) {
            continue;
        }
        if let Some(p) = &state.pool {
            let mut tx = p.begin().await.map_err(error)?;
            writer_lock(&mut tx, &user).await?;
            // Only account-owned metadata authorizes a new custom FK placeholder.
            if sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM private_lessons WHERE user_id=$1 AND lesson_id=$2)",
            )
            .bind(&user)
            .bind(&comp.lesson_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(error)?
            {
                private::ensure_parent(&mut tx, &comp.lesson_id).await?;
            }
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
        capabilities: Default::default(),
        custom_lesson_acks,
        custom_lesson_conflicts,
        progress_import_acks,
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
    if query.since_seq.is_some_and(|s| s < 0)
        || query
            .catalog_version
            .as_ref()
            .is_some_and(|v| v.len() > 128)
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let since = query.since.or(query.last_sync_time);
    let seq = query.since_seq;
    let mut now = Utc::now();
    let mut cards = Vec::new();
    let lessons;
    let catalog_version;
    let catalog_complete;
    let mut completed = Vec::new();
    let mut private_lessons = Vec::new();
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
        latest_sync_seq=sqlx::query_scalar::<_,i64>("SELECT GREATEST(COALESCE((SELECT MAX(sync_seq) FROM fsrs_cards WHERE user_id=$1),0),COALESCE((SELECT MAX(sync_seq) FROM completed_lessons WHERE user_id=$1),0),COALESCE((SELECT MAX(sync_seq) FROM review_logs WHERE user_id=$1),0),COALESCE((SELECT MAX(sync_seq) FROM private_lessons WHERE user_id=$1),0))").bind(&user).fetch_one(&mut *tx).await.map_err(error)?;
        let rows=sqlx::query_as::<_,DbFsrsCard>("SELECT item_id,state,stability,difficulty,reps,lapses,last_review,next_review,updated_at FROM fsrs_cards WHERE user_id=$1 AND (($2::BIGINT IS NOT NULL AND sync_seq>$2) OR ($2 IS NULL AND ($3::TIMESTAMPTZ IS NULL OR updated_at >= $3))) ORDER BY item_id").bind(&user).bind(seq).bind(since).fetch_all(&mut *tx).await.map_err(error)?;
        for row in rows {
            let at = row.updated_at;
            cards.push(FsrsCardDto::from_card(&row.into(), Some(at)));
        }
        completed=sqlx::query_as::<_,SyncCompletedLessonItem>("SELECT lesson_id,completed_at,score FROM completed_lessons WHERE user_id=$1 AND (($2::BIGINT IS NOT NULL AND sync_seq>$2) OR ($2 IS NULL AND ($3::TIMESTAMPTZ IS NULL OR updated_at >= $3))) ORDER BY lesson_id").bind(&user).bind(seq).bind(since).fetch_all(&mut *tx).await.map_err(error)?;
        // Public writers must update this same revision row before committing.
        // Hold its shared lock until rows are read so the version labels exactly
        // the delivered catalog, independent of the account's progress cursor.
        let (epoch, revision): (String, i64) = sqlx::query_as(
            "SELECT epoch,revision FROM public_catalog_revision WHERE singleton FOR SHARE",
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(error)?;
        catalog_version = format!("{epoch}:{revision}");
        catalog_complete = query.catalog_version.is_some()
            && query.catalog_version.as_deref() != Some(&catalog_version);
        lessons = if query.catalog_version.as_deref() == Some(&catalog_version) {
            vec![]
        } else {
            sqlx::query_as::<_,DbLessonItem>("SELECT id,language,category,target_text,phonetic_or_kana,meaning_vi,workplace_context,workplace_context_vi,stroke_order_hints,difficulty_level,created_at FROM lessons WHERE category <> 'custom' AND ($1::BOOLEAN OR $2::TIMESTAMPTZ IS NULL OR created_at >= $2) ORDER BY id")
                .bind(query.catalog_version.is_some() || seq.is_some()).bind(since).fetch_all(&mut *tx).await.map_err(error)?.into_iter().map(Into::into).collect()
        };
        private_lessons = private::pull(&mut tx, &user, seq, since).await?;
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
        if user != DEFAULT_USER {
            for (k, (s, changed)) in state.memory.private_lessons.read().await.iter() {
                if owns(&user, k) {
                    latest = latest.max(*changed);
                    if seq.map_or_else(
                        || since.is_none_or(|at| s.updated_at >= at),
                        |at| *changed > at,
                    ) {
                        private_lessons.push(s.clone());
                    }
                }
            }
        }
        latest_sync_seq = latest;
        let mut catalog: Vec<_> = state
            .lessons
            .iter()
            .filter(|l| l.category != "custom")
            .cloned()
            .collect();
        catalog.sort_by(|a, b| a.id.cmp(&b.id));
        catalog_version = format!(
            "memory:{}",
            crate::pin::hex(&crate::pin::sha256(&serde_json::to_vec(&catalog).unwrap()))
        );
        catalog_complete = query.catalog_version.is_some()
            && query.catalog_version.as_deref() != Some(&catalog_version);
        lessons = if query.catalog_version.as_deref() == Some(&catalog_version) {
            vec![]
        } else if query.catalog_version.is_some() || seq.is_some() || since.is_none() {
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
    private_lessons.sort_by(|a, b| a.lesson.id.cmp(&b.lesson.id));
    auth::seen_device(&state, &user, query.client_id.as_deref(), latest_sync_seq).await?;
    Ok(Json(SyncPullResponse {
        catalog_version,
        catalog_complete,
        private_lessons,
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

#[cfg(test)]
mod memory_due_vocabulary_tests {
    use super::*;
    use crate::models::{LessonItem, PrivateLessonWireState};

    fn lesson() -> LessonItem {
        LessonItem {
            id: "private-word".into(),
            language: "ja".into(),
            category: "custom".into(),
            target_text: "予約".into(),
            phonetic_or_kana: "よやく".into(),
            meaning_vi: "đặt trước".into(),
            workplace_context: String::new(),
            workplace_context_vi: String::new(),
            stroke_order_hints: Vec::new(),
            difficulty_level: 1,
        }
    }

    #[tokio::test]
    async fn due_private_lesson_is_account_scoped_and_excludes_tombstones() {
        let memory = MemorySync::default();
        let state = PrivateLessonWireState {
            lesson: lesson(),
            revision: 1,
            deleted: false,
            updated_at: chrono::Utc::now(),
        };
        memory
            .private_lessons
            .write()
            .await
            .insert(key("account-a", "private-word"), (state.clone(), 1));
        assert_eq!(
            memory
                .due_private_lesson("account-a", "private-word")
                .await
                .map(|entry| entry.target_text),
            Some("予約".into())
        );
        assert!(memory
            .due_private_lesson("account-b", "private-word")
            .await
            .is_none());

        let mut tombstone = state;
        tombstone.deleted = true;
        memory
            .private_lessons
            .write()
            .await
            .insert(key("account-a", "deleted-word"), (tombstone, 2));
        assert!(memory
            .due_private_lesson("account-a", "deleted-word")
            .await
            .is_none());
    }
}
