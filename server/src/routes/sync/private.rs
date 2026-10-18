use super::*;
use crate::{fsrs::State as CardState, models::*};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Receipt {
    payload: Value,
    result: MutationResult,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) enum MutationResult {
    Ack(PrivateLessonWireState),
    Conflict(Option<PrivateLessonWireState>),
    Import,
}
pub(super) fn valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.is_ascii() && !id.contains('\0')
}
fn valid_mutation_id(id: &str) -> bool {
    (1..=128).contains(&id.len()) && id.is_ascii() && !id.contains('\0')
}
fn text(s: &str) -> bool {
    s.len() <= 16_384 && !s.contains('\0')
}
fn valid_completion(c: &SyncCompletedLessonItem, now: DateTime<Utc>) -> bool {
    valid_id(&c.lesson_id)
        && valid_time(c.completed_at, now)
        && c.score
            .is_none_or(|s| s.is_finite() && (0.0..=1.0).contains(&s))
}
fn valid_time(t: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    t >= DateTime::from_timestamp(0, 0).unwrap() && t <= now + Duration::minutes(5)
}
fn card_state(s: &str) -> Result<CardState, StatusCode> {
    match s {
        "New" => Ok(CardState::New),
        "Learning" => Ok(CardState::Learning),
        "Review" => Ok(CardState::Review),
        "Relearning" => Ok(CardState::Relearning),
        _ => Err(StatusCode::BAD_REQUEST),
    }
}
pub(super) fn validate(
    req: &SyncPushRequest,
    user: &str,
    now: DateTime<Utc>,
) -> Result<(), StatusCode> {
    if req.custom_lesson_mutations.is_empty() && req.progress_imports.is_empty() {
        return Ok(());
    }
    if user == DEFAULT_USER {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let entries = req.custom_lesson_mutations.len()
        + req.progress_imports.len()
        + req.reviews.len()
        + req.completed_lessons.as_ref().map_or(0, Vec::len);
    if entries > 50
        || serde_json::to_vec(req)
            .map_err(|_| StatusCode::BAD_REQUEST)?
            .len()
            > 512 * 1024
    {
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }
    for m in &req.custom_lesson_mutations {
        let l = &m.lesson;
        if !valid_mutation_id(&m.mutation_id)
            || m.base_revision < 0
            || m.base_revision == i64::MAX
            || !valid_id(&l.id)
            || l.category != "custom"
            || !matches!(l.language.as_str(), "en" | "ja")
            || !(1..=5).contains(&l.difficulty_level)
            || l.target_text.trim().is_empty()
            || l.meaning_vi.trim().is_empty()
            || ![
                &l.target_text,
                &l.phonetic_or_kana,
                &l.meaning_vi,
                &l.workplace_context,
                &l.workplace_context_vi,
            ]
            .iter()
            .all(|s| text(s))
            || l.stroke_order_hints.len() > 64
            || !l.stroke_order_hints.iter().all(|s| text(s))
        {
            return Err(StatusCode::BAD_REQUEST);
        }
    }
    for i in &req.progress_imports {
        if !valid_mutation_id(&i.mutation_id) || i.cards.len() + i.completed_lessons.len() > 50 {
            return Err(StatusCode::BAD_REQUEST);
        }
        let mut seen = HashSet::new();
        for c in &i.cards {
            if !valid_id(&c.item_id)
                || !seen.insert(&c.item_id)
                || card_state(&c.state).is_err()
                || !c.stability.is_finite()
                || !(0.0..=36500.0).contains(&c.stability)
                || !c.difficulty.is_finite()
                || !(0.0..=10.0).contains(&c.difficulty)
                || c.lapses > c.reps
                || c.reps > i32::MAX as u32
                || c.lapses > i32::MAX as u32
                || !valid_time(c.last_review, now)
                || !valid_time(c.updated_at, now)
                || c.next_review < c.last_review
                || c.next_review > now + Duration::days(36500)
            {
                return Err(StatusCode::BAD_REQUEST);
            }
        }
        let mut seen = HashSet::new();
        if i.completed_lessons
            .iter()
            .any(|c| !valid_completion(c, now) || !seen.insert(&c.lesson_id))
        {
            return Err(StatusCode::BAD_REQUEST);
        }
    }
    Ok(())
}
async fn receipt_lock(tx: &mut sqlx::PgConnection, user: &str, id: &str) -> Result<(), StatusCode> {
    sqlx::query("SELECT pg_advisory_xact_lock(3,hashtext($1))")
        .bind(json!([user, id]).to_string())
        .execute(tx)
        .await
        .map_err(error)?;
    Ok(())
}
async fn receipt(
    tx: &mut sqlx::PgConnection,
    user: &str,
    id: &str,
    payload: &Value,
) -> Result<Option<MutationResult>, StatusCode> {
    let old = sqlx::query_as::<_, (Value, Value)>(
        "SELECT payload,result FROM private_sync_receipts WHERE user_id=$1 AND mutation_id=$2",
    )
    .bind(user)
    .bind(id)
    .fetch_optional(tx)
    .await
    .map_err(error)?;
    old.map(|(p, r)| {
        if p != *payload {
            Err(StatusCode::BAD_REQUEST)
        } else {
            serde_json::from_value(r).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
        }
    })
    .transpose()
}
async fn save_receipt(
    tx: &mut sqlx::PgConnection,
    user: &str,
    id: &str,
    payload: &Value,
    result: &MutationResult,
) -> Result<(), StatusCode> {
    sqlx::query(
        "INSERT INTO private_sync_receipts(user_id,mutation_id,payload,result) VALUES($1,$2,$3,$4)",
    )
    .bind(user)
    .bind(id)
    .bind(payload)
    .bind(serde_json::to_value(result).unwrap())
    .execute(tx)
    .await
    .map_err(error)?;
    Ok(())
}
fn decide(m: &CustomLessonMutation, old: Option<PrivateLessonWireState>) -> MutationResult {
    let rev = old.as_ref().map_or(0, |s| s.revision);
    if m.base_revision == rev {
        MutationResult::Ack(PrivateLessonWireState {
            lesson: m.lesson.clone(),
            revision: rev + 1,
            deleted: m.deleted,
            updated_at: Utc::now(),
        })
    } else if old
        .as_ref()
        .is_some_and(|s| s.lesson == m.lesson && s.deleted == m.deleted)
    {
        MutationResult::Ack(old.unwrap())
    } else {
        MutationResult::Conflict(old)
    }
}
pub(super) async fn mutate(
    state: &AppState,
    user: &str,
    m: &CustomLessonMutation,
) -> Result<MutationResult, StatusCode> {
    let payload = json!({"custom":m});
    if let Some(p) = &state.pool {
        let mut tx = p.begin().await.map_err(error)?;
        writer_lock(&mut tx, user).await?;
        receipt_lock(&mut tx, user, &m.mutation_id).await?;
        if let Some(r) = receipt(&mut tx, user, &m.mutation_id, &payload).await? {
            return Ok(r);
        }
        card_lock(&mut tx, user, &m.lesson.id).await?;
        if sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM lessons WHERE id=$1 AND category<>'custom')",
        )
        .bind(&m.lesson.id)
        .fetch_one(&mut *tx)
        .await
        .map_err(error)?
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        let old=sqlx::query_as::<_,(Value,i64,bool,DateTime<Utc>)>("SELECT lesson,revision,deleted,updated_at FROM private_lessons WHERE user_id=$1 AND lesson_id=$2").bind(user).bind(&m.lesson.id).fetch_optional(&mut *tx).await.map_err(error)?.map(|(l,revision,deleted,updated_at)|serde_json::from_value(l).map(|lesson|PrivateLessonWireState{lesson,revision,deleted,updated_at})).transpose().map_err(|_|StatusCode::INTERNAL_SERVER_ERROR)?;
        let previous = old.as_ref().map_or(0, |s| s.revision);
        let mut r = decide(m, old);
        if let MutationResult::Ack(s) = &mut r {
            if s.revision > previous {
                s.updated_at=sqlx::query_scalar("INSERT INTO private_lessons(user_id,lesson_id,lesson,revision,deleted) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,lesson_id) DO UPDATE SET lesson=EXCLUDED.lesson,revision=EXCLUDED.revision,deleted=EXCLUDED.deleted,updated_at=clock_timestamp(),sync_seq=nextval('sync_change_seq') RETURNING updated_at").bind(user).bind(&m.lesson.id).bind(serde_json::to_value(&m.lesson).unwrap()).bind(s.revision).bind(s.deleted).fetch_one(&mut *tx).await.map_err(error)?;
            }
        }
        save_receipt(&mut tx, user, &m.mutation_id, &payload, &r).await?;
        tx.commit().await.map_err(error)?;
        Ok(r)
    } else {
        let k = key(user, &m.mutation_id);
        if let Some(r) = state.memory.receipts.read().await.get(&k) {
            return if r.payload == payload {
                Ok(r.result.clone())
            } else {
                Err(StatusCode::BAD_REQUEST)
            };
        }
        if state
            .lessons
            .iter()
            .any(|l| l.id == m.lesson.id && l.category != "custom")
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        let lk = key(user, &m.lesson.id);
        let old = state
            .memory
            .private_lessons
            .read()
            .await
            .get(&lk)
            .map(|(s, _)| s.clone());
        let previous = old.as_ref().map_or(0, |s| s.revision);
        let r = decide(m, old);
        if let MutationResult::Ack(s) = &r {
            if s.revision > previous {
                let seq = state.memory.sequence.fetch_add(1, Ordering::SeqCst) + 1;
                state
                    .memory
                    .private_lessons
                    .write()
                    .await
                    .insert(lk, (s.clone(), seq));
            }
        }
        state.memory.receipts.write().await.insert(
            k,
            Receipt {
                payload,
                result: r.clone(),
            },
        );
        Ok(r)
    }
}
pub(super) async fn import(
    state: &AppState,
    user: &str,
    i: &ProgressImport,
) -> Result<(), StatusCode> {
    let payload = json!({"import":i});
    if let Some(p) = &state.pool {
        let mut tx = p.begin().await.map_err(error)?;
        writer_lock(&mut tx, user).await?;
        receipt_lock(&mut tx, user, &i.mutation_id).await?;
        if receipt(&mut tx, user, &i.mutation_id, &payload)
            .await?
            .is_some()
        {
            return Ok(());
        }
        // Stable lock order avoids deadlocks for overlapping import chunks and review writers.
        let mut ids: Vec<_> = i
            .cards
            .iter()
            .map(|c| c.item_id.as_str())
            .chain(i.completed_lessons.iter().map(|c| c.lesson_id.as_str()))
            .collect();
        ids.sort_unstable();
        ids.dedup();
        // A backup may contain progress only for lessons this account owns or
        // public lessons already present in the shared catalogue. Never let an
        // arbitrary client ID reserve a future public lesson ID via a custom
        // placeholder row.
        for id in &ids {
            let known = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM lessons WHERE id=$1 AND category<>'custom') OR EXISTS(SELECT 1 FROM private_lessons WHERE user_id=$2 AND lesson_id=$1)",
            )
            .bind(id)
            .bind(user)
            .fetch_one(&mut *tx)
            .await
            .map_err(error)?;
            if !known {
                return Err(StatusCode::BAD_REQUEST);
            }
        }
        for id in ids {
            card_lock(&mut tx, user, id).await?;
            ensure_parent(&mut tx, id).await?;
        }
        for c in &i.cards {
            let old = db::fetch_card_by_id(&mut tx, &c.item_id, user)
                .await
                .map_err(error)?;
            if old.is_none_or(|old| {
                c.last_review.timestamp_micros() > old.last_review.timestamp_micros()
            }) {
                db::upsert_card(&mut tx, &to_card(c)?, user)
                    .await
                    .map_err(error)?;
            }
        }
        for c in &i.completed_lessons {
            sqlx::query("INSERT INTO completed_lessons(user_id,lesson_id,client_id,completed_at,score) SELECT $1,$2,'private_import',$3,$4 WHERE NOT EXISTS(SELECT 1 FROM completed_lessons WHERE user_id=$1 AND lesson_id=$2 AND completed_at >= $3) ON CONFLICT(user_id,lesson_id,client_id) DO UPDATE SET completed_at=EXCLUDED.completed_at,score=EXCLUDED.score,updated_at=clock_timestamp(),sync_seq=nextval('sync_change_seq') WHERE completed_lessons.completed_at<EXCLUDED.completed_at").bind(user).bind(&c.lesson_id).bind(c.completed_at).bind(c.score.unwrap_or(1.0)).execute(&mut *tx).await.map_err(error)?;
        }
        save_receipt(
            &mut tx,
            user,
            &i.mutation_id,
            &payload,
            &MutationResult::Import,
        )
        .await?;
        tx.commit().await.map_err(error)?;
    } else {
        let k = key(user, &i.mutation_id);
        if let Some(r) = state.memory.receipts.read().await.get(&k) {
            return if r.payload == payload {
                Ok(())
            } else {
                Err(StatusCode::BAD_REQUEST)
            };
        }
        let ids: HashSet<&str> = i
            .cards
            .iter()
            .map(|c| c.item_id.as_str())
            .chain(i.completed_lessons.iter().map(|c| c.lesson_id.as_str()))
            .collect();
        for id in ids {
            let public = state
                .lessons
                .iter()
                .any(|lesson| lesson.id == id && lesson.category != "custom");
            let own_private = state
                .memory
                .private_lessons
                .read()
                .await
                .contains_key(&key(user, id));
            if !public && !own_private {
                return Err(StatusCode::BAD_REQUEST);
            }
        }
        for c in &i.cards {
            let newer = state
                .cards
                .read()
                .await
                .get(&key(user, &c.item_id))
                .is_none_or(|old| {
                    c.last_review.timestamp_micros() > old.last_review.timestamp_micros()
                });
            if newer {
                record_memory_card(state, user, to_card(c)?).await;
            }
        }
        for c in &i.completed_lessons {
            let mut all = state.memory.completed.write().await;
            let newer = !all.iter().any(|(k, (old, _, _))| {
                serde_json::from_str::<(String, String, String)>(k)
                    .is_ok_and(|(u, id, _)| u == user && id == c.lesson_id)
                    && old.completed_at.timestamp_micros() >= c.completed_at.timestamp_micros()
            });
            if newer {
                let seq = state.memory.sequence.fetch_add(1, Ordering::SeqCst) + 1;
                all.insert(
                    json!([user, c.lesson_id, "private_import"]).to_string(),
                    (c.clone(), seq, Utc::now()),
                );
            }
        }
        state.memory.receipts.write().await.insert(
            k,
            Receipt {
                payload,
                result: MutationResult::Import,
            },
        );
    }
    Ok(())
}
fn to_card(c: &FsrsCardDto) -> Result<FSRSCard, StatusCode> {
    Ok(FSRSCard {
        item_id: c.item_id.clone(),
        state: card_state(&c.state)?,
        stability: c.stability,
        difficulty: c.difficulty,
        reps: c.reps,
        lapses: c.lapses,
        last_review: c.last_review,
        next_review: c.next_review,
    })
}
pub(super) async fn ensure_parent(tx: &mut sqlx::PgConnection, id: &str) -> Result<(), StatusCode> {
    sqlx::query("INSERT INTO lessons(id,language,category,target_text,phonetic_or_kana,meaning_vi,workplace_context,workplace_context_vi,stroke_order_hints,difficulty_level) VALUES($1,'custom','custom',$1,'','Custom card','','','[]',1) ON CONFLICT(id) DO NOTHING").bind(id).execute(tx).await.map_err(error)?;
    Ok(())
}
pub(super) async fn pull(
    tx: &mut sqlx::PgConnection,
    user: &str,
    seq: Option<i64>,
    since: Option<DateTime<Utc>>,
) -> Result<Vec<PrivateLessonWireState>, StatusCode> {
    if user == DEFAULT_USER {
        return Ok(vec![]);
    }
    sqlx::query_as::<_,(Value,i64,bool,DateTime<Utc>)>("SELECT lesson,revision,deleted,updated_at FROM private_lessons WHERE user_id=$1 AND (($2::BIGINT IS NOT NULL AND sync_seq>$2) OR ($2 IS NULL AND ($3::TIMESTAMPTZ IS NULL OR updated_at >= $3))) ORDER BY lesson_id").bind(user).bind(seq).bind(since).fetch_all(tx).await.map_err(error)?.into_iter().map(|(l,revision,deleted,updated_at)|serde_json::from_value(l).map(|lesson|PrivateLessonWireState{lesson,revision,deleted,updated_at}).map_err(|_|StatusCode::INTERNAL_SERVER_ERROR)).collect()
}
