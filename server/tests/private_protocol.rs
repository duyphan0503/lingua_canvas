use axum::{body::Body, http::Request, Router};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use server::{ai::AIService, fsrs::FSRS, routes::AppState};
use std::sync::Arc;
use tower::ServiceExt;

fn app(pool: Option<sqlx::PgPool>) -> Router {
    server::create_app(AppState {
        cache: Arc::new(server::redis_cache::RedisCache::new(None)),
        accounts: Default::default(),
        memory: Default::default(),
        lessons: server::data::get_seed_lessons(),
        cards: Default::default(),
        seen_review_ids: Default::default(),
        card_updated_at: Default::default(),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool,
    })
}
async fn request(a: &Router, path: &str, body: Option<Value>, token: Option<&str>) -> (u16, Value) {
    let mut r = Request::builder()
        .uri(path)
        .method(if body.is_some() { "POST" } else { "GET" })
        .header("content-type", "application/json");
    if let Some(t) = token {
        r = r.header("X-Sync-Token", t);
    }
    let res = a
        .clone()
        .oneshot(
            r.body(Body::from(body.map(|v| v.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = res.status().as_u16();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
async fn account(a: &Router, name: &str) -> String {
    let (status, v) = request(
        a,
        "/api/v1/auth/register",
        Some(json!({"username":name,"pin":"123456"})),
        None,
    )
    .await;
    assert_eq!(status, 201, "{v}");
    v["sync_token"].as_str().unwrap().into()
}
fn lesson(id: &str, word: &str) -> Value {
    json!({"id":id,"language":"ja","category":"custom","target_text":word,"phonetic_or_kana":"かな","meaning_vi":"Nghĩa riêng","workplace_context":"context","workplace_context_vi":"ngữ cảnh","stroke_order_hints":["one","two"],"difficulty_level":2})
}
fn mutation(id: &str, base: i64, word: Value, deleted: bool) -> Value {
    json!({"mutation_id":id,"base_revision":base,"lesson":word,"deleted":deleted})
}
async fn push(a: &Router, token: &str, m: Value) -> (u16, Value) {
    request(
        a,
        "/api/v1/sync",
        Some(json!({"custom_lesson_mutations":[m]})),
        Some(token),
    )
    .await
}
async fn protocol_cases(a: &Router, suffix: &str) {
    let t = account(a, &format!("alice{suffix}")).await;
    let other = account(a, &format!("bobby{suffix}")).await;
    let m = mutation("create", 0, lesson("custom_private", "秘密"), false);
    assert_eq!(
        request(
            a,
            "/api/v1/sync",
            Some(json!({"custom_lesson_mutations":[m.clone()]})),
            None
        )
        .await
        .0,
        401
    );
    let (status, created) = push(a, &t, m.clone()).await;
    assert_eq!(status, 200);
    assert_eq!(created["capabilities"]["private_vocabulary_sync"], 1);
    assert_eq!(created["custom_lesson_acks"][0]["state"]["revision"], 1);
    assert_eq!(
        push(a, &t, m.clone()).await.1["custom_lesson_acks"],
        created["custom_lesson_acks"]
    );
    let completed = request(
        a,
        "/api/v1/sync",
        Some(
            json!({"completed_lessons":[{"lesson_id":"custom_private","completed_at":Utc::now()}]}),
        ),
        Some(&t),
    )
    .await;
    assert_eq!(completed.0, 200);
    assert_eq!(
        completed.1["synced_completed_lesson_ids"],
        json!(["custom_private"])
    );
    let public = request(a, "/api/v1/lessons", None, None).await.1;
    assert_eq!(public.as_array().unwrap().len(), 155);
    assert!(!public
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["id"] == "custom_private"));

    assert_eq!(
        push(
            a,
            &t,
            mutation("create", 0, lesson("custom_private", "changed"), false)
        )
        .await
        .0,
        400
    );
    assert_eq!(
        push(
            a,
            &t,
            mutation("public", 0, lesson("ja_hira_a", "shadow"), false)
        )
        .await
        .0,
        400
    );
    for token in [Some(other.as_str()), None] {
        assert_eq!(
            request(a, "/api/v1/sync/pull?since_seq=0", None, token)
                .await
                .1["private_lessons"],
            json!([])
        );
    }
    assert_eq!(
        request(a, "/api/v1/lessons/custom_private", None, None)
            .await
            .0,
        404
    );
    let pull = request(a, "/api/v1/sync/pull?since_seq=0", None, Some(&t))
        .await
        .1;
    assert_eq!(pull["private_lessons"][0]["lesson"], m["lesson"]);
    let cursor = pull["latest_sync_seq"].as_i64().unwrap();
    assert!(cursor > 0);
    let edited = push(
        a,
        &t,
        mutation("edit", 1, lesson("custom_private", "編集"), false),
    )
    .await
    .1;
    assert_eq!(edited["custom_lesson_acks"][0]["state"]["revision"], 2);
    let conflict = push(
        a,
        &t,
        mutation("stale-delete", 1, lesson("custom_private", "秘密"), true),
    )
    .await
    .1;
    assert_eq!(
        conflict["custom_lesson_conflicts"][0]["server"]["revision"],
        2
    );
    assert_eq!(conflict["custom_lesson_acks"], json!([]));
    assert_eq!(
        push(
            a,
            &t,
            mutation("delete", 2, lesson("custom_private", "編集"), true)
        )
        .await
        .1["custom_lesson_acks"][0]["state"]["revision"],
        3
    );
    let delta = request(
        a,
        &format!("/api/v1/sync/pull?since_seq={cursor}"),
        None,
        Some(&t),
    )
    .await
    .1;
    assert_eq!(delta["private_lessons"][0]["deleted"], true);
    assert_eq!(
        push(a, &t, m).await.1["custom_lesson_acks"][0]["state"]["revision"],
        1
    );
    assert_eq!(
        push(
            a,
            &t,
            mutation("restore", 3, lesson("custom_private", "編集"), false)
        )
        .await
        .1["custom_lesson_acks"][0]["state"]["revision"],
        4
    );
    assert_eq!(
        push(
            a,
            &t,
            mutation("stale-restore", 3, lesson("custom_private", "編集"), true)
        )
        .await
        .1["custom_lesson_conflicts"][0]["server"]["revision"],
        4
    );
}
#[tokio::test]
async fn memory_private_cas_receipts_tombstones_and_account_privacy() {
    protocol_cases(&app(None), "memory").await;
}

fn snapshot(id: &str, time: chrono::DateTime<Utc>, reps: u32) -> Value {
    json!({"item_id":id,"state":"Review","stability":12.5,"difficulty":4.5,"reps":reps,"lapses":1,"last_review":time,"next_review":time+Duration::days(12),"updated_at":time})
}
async fn progress_cases(a: &Router, suffix: &str) {
    let t = account(a, &format!("import{suffix}")).await;
    let at = Utc::now() - Duration::days(1);
    let import = json!({"mutation_id":"backup","cards":[snapshot("ja_hira_a",at,7)],"completed_lessons":[{"lesson_id":"ja_hira_a","completed_at":at,"score":0.8}]});
    let payload = json!({"progress_imports":[import.clone()]});
    assert_eq!(
        request(a, "/api/v1/sync", Some(payload.clone()), None)
            .await
            .0,
        401
    );
    let accepted = request(a, "/api/v1/sync", Some(payload.clone()), Some(&t)).await;
    assert_eq!(accepted.0, 200);
    assert_eq!(accepted.1["progress_import_acks"], json!(["backup"]));
    let review =
        json!({"reviews":[{"review_id":"old","item_id":"ja_hira_a","rating":3,"review_time":at}]});
    assert_eq!(
        request(a, "/api/v1/sync", Some(review), Some(&t)).await.1["updated_cards"][0]["reps"],
        7
    );
    assert_eq!(
        request(a, "/api/v1/sync", Some(payload), Some(&t)).await.1["progress_import_acks"],
        json!(["backup"])
    );
    let older = json!({"progress_imports":[{"mutation_id":"older","cards":[snapshot("ja_hira_a",at-Duration::days(1),2)],"completed_lessons":[]}]});
    assert_eq!(
        request(a, "/api/v1/sync", Some(older), Some(&t)).await.0,
        200
    );
    let pull = request(a, "/api/v1/sync/pull", None, Some(&t)).await.1;
    assert_eq!(pull["cards"][0]["reps"], 7);
    assert_eq!(pull["cards"][0]["stability"], 12.5);
    let mut invalid = import;
    invalid["mutation_id"] = json!("bad");
    invalid["cards"][0]["last_review"] = json!(Utc::now() + Duration::minutes(6));
    assert_eq!(
        request(
            a,
            "/api/v1/sync",
            Some(json!({"progress_imports":[invalid]})),
            Some(&t)
        )
        .await
        .0,
        400
    );
}
#[tokio::test]
async fn memory_import_snapshots_do_not_replay_reviews() {
    progress_cases(&app(None), "memory").await;
}
#[tokio::test]
async fn postgres_private_protocol_and_progress() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let p = sqlx::postgres::PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&p).await.unwrap();
    server::db::seed_lessons_if_empty(&p, &server::data::get_seed_lessons())
        .await
        .unwrap();
    let a = app(Some(p));
    let suffix = Utc::now().timestamp_micros().to_string();
    protocol_cases(&a, &suffix).await;
    progress_cases(&a, &suffix).await;
    baseline_cases(&a, &format!("baseline{suffix}")).await;
}

#[tokio::test]
async fn private_conflicts_block_only_related_entries_and_cas_is_concurrent() {
    let a = app(None);
    let t = account(&a, "race_private").await;
    push(
        &a,
        &t,
        mutation("first", 0, lesson("custom_private", "one"), false),
    )
    .await;
    let (one, two) = tokio::join!(
        push(
            &a,
            &t,
            mutation("race1", 1, lesson("custom_private", "two"), false)
        ),
        push(
            &a,
            &t,
            mutation("race2", 1, lesson("custom_private", "three"), true)
        )
    );
    assert_eq!(one.0, 200);
    assert_eq!(two.0, 200);
    assert_eq!(
        one.1["custom_lesson_acks"].as_array().unwrap().len()
            + two.1["custom_lesson_acks"].as_array().unwrap().len(),
        1
    );
    assert_eq!(
        one.1["custom_lesson_conflicts"].as_array().unwrap().len()
            + two.1["custom_lesson_conflicts"].as_array().unwrap().len(),
        1
    );
    let at = Utc::now() - Duration::hours(1);
    let body = json!({"custom_lesson_mutations":[mutation("blocked",0,lesson("custom_private","stale"),false),mutation("independent",0,lesson("custom_other","independent"),false)],"reviews":[{"review_id":"blocked_review","item_id":"custom_private","rating":3,"review_time":at},{"review_id":"good_review","item_id":"ja_hira_i","rating":3,"review_time":at}],"progress_imports":[{"mutation_id":"blocked_import","cards":[snapshot("custom_private",at,8)],"completed_lessons":[]},{"mutation_id":"good_import","cards":[snapshot("ja_hira_u",at,9)],"completed_lessons":[]}]});
    let (status, v) = request(&a, "/api/v1/sync", Some(body), Some(&t)).await;
    assert_eq!(status, 200);
    assert_eq!(v["synced_review_ids"], json!(["good_review"]));
    assert_eq!(v["progress_import_acks"], json!(["good_import"]));
    assert_eq!(v["custom_lesson_acks"][0]["mutation_id"], "independent");
    let pull = request(&a, "/api/v1/sync/pull", None, Some(&t)).await.1;
    assert_eq!(pull["cards"].as_array().unwrap().len(), 2);
}
#[tokio::test]
async fn baseline_import_and_source_review_both_orders_keep_repetitions() {
    baseline_cases(&app(None), "baseline_both_orders").await;
}
async fn baseline_cases(a: &Router, name: &str) {
    let t = account(a, name).await;
    let at = Utc::now() - Duration::days(1);
    for (id, import_first) in [("ja_hira_a", true), ("ja_hira_i", false)] {
        let review = json!({"reviews":[{"review_id":id,"item_id":id,"rating":3,"review_time":at}]});
        let baseline = json!({"progress_imports":[{"mutation_id":id,"cards":[snapshot(id,at+Duration::seconds(1),7)],"completed_lessons":[]}]});
        let (first, second) = if import_first {
            (baseline, review)
        } else {
            (review, baseline)
        };
        assert_eq!(
            request(a, "/api/v1/sync", Some(first), Some(&t)).await.0,
            200
        );
        assert_eq!(
            request(a, "/api/v1/sync", Some(second), Some(&t)).await.0,
            200
        );
    }
    let mut zero = snapshot("ja_hira_u", at, 0);
    zero["lapses"] = json!(0);
    zero["state"] = json!("New");
    assert_eq!(request(a,"/api/v1/sync",Some(json!({"progress_imports":[{"mutation_id":"zero","cards":[zero],"completed_lessons":[]}],"reviews":[{"review_id":"oldzero","item_id":"ja_hira_u","rating":3,"review_time":at}]})),Some(&t)).await.0,200);
    let pull = request(a, "/api/v1/sync/pull", None, Some(&t)).await.1;
    assert_eq!(pull["cards"][0]["reps"], 7);
    assert_eq!(pull["cards"][1]["reps"], 7);
    assert_eq!(pull["cards"][2]["reps"], 0);
}
#[tokio::test]
async fn private_validation_and_receipt_namespace_reject_without_state_loss() {
    let a = app(None);
    let t = account(&a, "validation_private").await;
    let base = mutation("valid", 0, lesson("custom_valid", "secret"), false);
    for (field, value) in [
        ("language", json!("fr")),
        ("category", json!("daily")),
        ("id", json!("x".repeat(65))),
        ("id", json!("秘密")),
        ("id", json!("bad\u{0000}id")),
        ("target_text", json!("")),
        ("difficulty_level", json!(0)),
    ] {
        let mut m = base.clone();
        m["lesson"][field] = value;
        assert_eq!(push(&a, &t, m).await.0, 400, "field {field}");
    }
    assert_eq!(push(&a, &t, base.clone()).await.0, 200);
    assert_eq!(request(&a,"/api/v1/sync",Some(json!({"progress_imports":[{"mutation_id":"valid","cards":[],"completed_lessons":[]}]})),Some(&t)).await.0,400);
    let same = push(
        &a,
        &t,
        mutation("same_stale", 0, lesson("custom_valid", "secret"), false),
    )
    .await
    .1;
    assert_eq!(same["custom_lesson_acks"][0]["state"]["revision"], 1);
    let many = vec![base; 51];
    assert_eq!(
        request(
            &a,
            "/api/v1/sync",
            Some(json!({"custom_lesson_mutations":many})),
            Some(&t)
        )
        .await
        .0,
        413
    );
    for (field, value) in [
        ("difficulty", json!(11)),
        ("stability", json!(-1)),
        ("state", json!("Unknown")),
        ("lapses", json!(10)),
        ("reps", json!(2147483648u64)),
    ] {
        let mut card = snapshot("ja_hira_a", Utc::now() - Duration::hours(1), 7);
        card[field] = value;
        assert_eq!(request(&a,"/api/v1/sync",Some(json!({"progress_imports":[{"mutation_id":"invalid","cards":[card],"completed_lessons":[]}]})),Some(&t)).await.0,400,"field {field}");
    }
    assert_eq!(
        request(&a, "/api/v1/sync/pull", None, Some(&t)).await.1["private_lessons"][0]["revision"],
        1
    );
}

#[tokio::test]
async fn postgres_private_pull_waits_for_writers_and_import_receipts_are_atomic() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let p = sqlx::postgres::PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&p).await.unwrap();
    server::db::seed_lessons_if_empty(&p, &server::data::get_seed_lessons())
        .await
        .unwrap();
    let a = app(Some(p.clone()));
    let suffix = Utc::now().timestamp_micros();
    let t = account(&a, &format!("barrier{suffix}")).await;
    let u: String = sqlx::query_scalar("SELECT user_id FROM user_accounts WHERE sync_token=$1")
        .bind(&t)
        .fetch_one(&p)
        .await
        .unwrap();
    let mut tx = p.begin().await.unwrap();
    server::routes::sync::writer_lock(&mut tx, &u)
        .await
        .unwrap();
    sqlx::query("INSERT INTO private_lessons(user_id,lesson_id,lesson,revision,deleted) VALUES($1,'custom_barrier',$2,1,false)").bind(&u).bind(lesson("custom_barrier","uncommitted")).execute(&mut *tx).await.unwrap();
    let cloned = a.clone();
    let token = t.clone();
    let mut pulling = tokio::spawn(async move {
        request(&cloned, "/api/v1/sync/pull?since_seq=0", None, Some(&token)).await
    });
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(150), &mut pulling)
            .await
            .is_err()
    );
    tx.commit().await.unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(3), pulling)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.0, 200);
    assert_eq!(
        result.1["private_lessons"][0]["lesson"]["target_text"],
        "uncommitted"
    );
    let m1 = mutation("race_pg1", 1, lesson("custom_barrier", "edit"), false);
    let m2 = mutation("race_pg2", 1, lesson("custom_barrier", "delete"), true);
    let (r1, r2) = tokio::join!(push(&a, &t, m1), push(&a, &t, m2));
    assert_eq!(r1.0, 200);
    assert_eq!(r2.0, 200);
    assert_eq!(
        r1.1["custom_lesson_acks"].as_array().unwrap().len()
            + r2.1["custom_lesson_acks"].as_array().unwrap().len(),
        1
    );
    let at = Utc::now() - Duration::days(1);
    let import = json!({"progress_imports":[{"mutation_id":"parallel_import","cards":[snapshot("ja_hira_a",at,11)],"completed_lessons":[]}]});
    let (r1, r2) = tokio::join!(
        request(&a, "/api/v1/sync", Some(import.clone()), Some(&t)),
        request(&a, "/api/v1/sync", Some(import.clone()), Some(&t))
    );
    assert_eq!(r1.0, 200);
    assert_eq!(r2.0, 200);
    assert_eq!(r1.1["progress_import_acks"], r2.1["progress_import_acks"]);
    let before: i64 = sqlx::query_scalar(
        "SELECT sync_seq FROM fsrs_cards WHERE user_id=$1 AND item_id='ja_hira_a'",
    )
    .bind(&u)
    .fetch_one(&p)
    .await
    .unwrap();
    let recreated = app(Some(p.clone()));
    assert_eq!(
        request(&recreated, "/api/v1/sync", Some(import), Some(&t))
            .await
            .0,
        200
    );
    let after: i64 = sqlx::query_scalar(
        "SELECT sync_seq FROM fsrs_cards WHERE user_id=$1 AND item_id='ja_hira_a'",
    )
    .bind(&u)
    .fetch_one(&p)
    .await
    .unwrap();
    assert_eq!(before, after);
    // A failing second entity rolls back the first card and the receipt together.
    sqlx::query("CREATE OR REPLACE FUNCTION reject_private_test_card() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.item_id='custom_fail_import' THEN RAISE EXCEPTION 'test rollback'; END IF; RETURN NEW; END $$").execute(&p).await.unwrap();
    sqlx::query("CREATE TRIGGER private_test_reject BEFORE INSERT ON fsrs_cards FOR EACH ROW EXECUTE FUNCTION reject_private_test_card()").execute(&p).await.unwrap();
    let fail = json!({"progress_imports":[{"mutation_id":"rollback","cards":[snapshot("custom_first_import",at,3),snapshot("custom_fail_import",at,3)],"completed_lessons":[]}]});
    let r = request(&a, "/api/v1/sync", Some(fail), Some(&t)).await;
    sqlx::query("DROP TRIGGER private_test_reject ON fsrs_cards")
        .execute(&p)
        .await
        .unwrap();
    sqlx::query("DROP FUNCTION reject_private_test_card()")
        .execute(&p)
        .await
        .unwrap();
    assert_eq!(r.0, 500);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM fsrs_cards WHERE user_id=$1 AND item_id='custom_first_import'",
    )
    .bind(&u)
    .fetch_one(&p)
    .await
    .unwrap();
    assert_eq!(count, 0);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM private_sync_receipts WHERE user_id=$1 AND mutation_id='rollback'",
    )
    .bind(&u)
    .fetch_one(&p)
    .await
    .unwrap();
    assert_eq!(count, 0);
}
