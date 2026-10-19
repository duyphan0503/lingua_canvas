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
        auth_sessions: Default::default(),
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

async fn request(
    app: &Router,
    path: &str,
    data: Option<Value>,
    token: Option<&str>,
) -> (u16, Value) {
    let mut request = Request::builder()
        .method(if data.is_some() { "POST" } else { "GET" })
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        request = request.header("X-Sync-Token", token);
    }
    let response = app
        .clone()
        .oneshot(
            request
                .body(Body::from(data.map(|v| v.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status().as_u16();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

#[tokio::test]
async fn unchanged_public_catalog_is_suppressed_without_changing_legacy_pulls() {
    let app = app(None);
    let (status, first) = request(&app, "/api/v1/sync/pull?since_seq=0", None, None).await;
    assert_eq!(status, 200);
    assert_eq!(first["lessons"].as_array().unwrap().len(), 355);
    let version = first["catalog_version"]
        .as_str()
        .expect("server must expose an independent catalog version");
    let (_, second) = request(
        &app,
        &format!("/api/v1/sync/pull?since_seq=99999&catalog_version={version}"),
        None,
        None,
    )
    .await;
    assert_eq!(second["catalog_version"], version);
    assert_eq!(second["lessons"], json!([]));
    assert_eq!(second["new_lessons"], json!([]));
    let (_, legacy) = request(&app, "/api/v1/sync/pull?since_seq=99999", None, None).await;
    assert_eq!(legacy["lessons"].as_array().unwrap().len(), 355);
    let (_, stale) = request(
        &app,
        "/api/v1/sync/pull?since_seq=99999&catalog_version=stale",
        None,
        None,
    )
    .await;
    assert_eq!(stale["lessons"].as_array().unwrap().len(), 355);
}

#[tokio::test]
#[ignore = "requires disposable TEST_DATABASE_URL"]
async fn postgres_batch_rollback_and_catalog_commit_visibility() {
    let url = std::env::var("TEST_DATABASE_URL").expect("requires TEST_DATABASE_URL");
    let parsed = reqwest::Url::parse(&url).unwrap();
    assert!(matches!(
        parsed.host_str(),
        Some("127.0.0.1" | "localhost" | "::1")
    ));
    assert!(parsed.path().starts_with("/lingua_private_test_"));
    let pool = server::db::init_pool(Some(&url))
        .await
        .expect("PostgreSQL and migrations must work");
    server::db::seed_lessons_if_empty(&pool, &server::data::get_seed_lessons())
        .await
        .unwrap();
    let app = app(Some(pool.clone()));
    let name = format!("batch_{}", Utc::now().timestamp_micros());
    let (status, account) = request(
        &app,
        "/api/v1/auth/register",
        Some(json!({"username":name,"pin":"123456","device_id":"batch_device"})),
        None,
    )
    .await;
    assert_eq!(status, 201, "{account}");
    let token = account["sync_token"].as_str().unwrap();
    let user = account["user_id"].as_str().unwrap();
    let at = Utc::now() - Duration::hours(1);
    let failure_id = format!("abort_{}", Utc::now().timestamp_micros());
    sqlx::query(&format!("CREATE FUNCTION {failure_id}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id = '{failure_id}' THEN RAISE EXCEPTION 'intentional batch failure'; END IF; RETURN NEW; END $$")).execute(&pool).await.unwrap();
    sqlx::query(&format!("CREATE TRIGGER {failure_id} BEFORE INSERT ON review_logs FOR EACH ROW EXECUTE FUNCTION {failure_id}()")).execute(&pool).await.unwrap();
    let failing = json!({"reviews":[
        {"review_id":"before_abort","item_id":"ja_hira_a","rating":3,"review_time":at},
        {"review_id":failure_id,"item_id":"ja_hira_i","rating":3,"review_time":at}
    ]});
    let failed = request(&app, "/api/v1/sync", Some(failing), Some(token)).await;
    sqlx::query(&format!("DROP TRIGGER {failure_id} ON review_logs"))
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(&format!("DROP FUNCTION {failure_id}()"))
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(failed.0, 500);
    let reviews: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM review_logs WHERE user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        reviews, 0,
        "SQL failure in a later review must roll back earlier FSRS writes"
    );
    let duplicate = json!({"reviews":[
        {"review_id":"collision","item_id":"ja_hira_a","rating":3,"review_time":at},
        {"review_id":"collision","item_id":"ja_hira_i","rating":3,"review_time":at}
    ]});
    assert_eq!(
        request(&app, "/api/v1/sync", Some(duplicate), Some(token))
            .await
            .0,
        400
    );
    let reviews: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM review_logs WHERE user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        reviews, 0,
        "a rejected review batch must not partially commit"
    );
    let cards: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM fsrs_cards WHERE user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(cards, 0);

    let batch = |suffix: &str, ids: [&str; 2]| json!({"reviews":ids.into_iter().map(|id| json!({"review_id":format!("{suffix}_{id}"),"item_id":id,"rating":3,"review_time":at})).collect::<Vec<_>>()});
    let (left, right) = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        tokio::join!(
            request(
                &app,
                "/api/v1/sync",
                Some(batch("one", ["ja_hira_a", "ja_hira_i"])),
                Some(token)
            ),
            request(
                &app,
                "/api/v1/sync",
                Some(batch("two", ["ja_hira_i", "ja_hira_a"])),
                Some(token)
            )
        )
    })
    .await
    .expect("opposite batch order must not deadlock");
    assert_eq!(left.0, 200, "{left:?}");
    assert_eq!(right.0, 200, "{right:?}");
    let (_, first) = request(
        &app,
        "/api/v1/sync/pull?since_seq=999999999",
        None,
        Some(token),
    )
    .await;
    let version = first["catalog_version"].as_str().unwrap();
    let new_id = format!("catalog_{}", Utc::now().timestamp_micros());
    let mut tx = pool.begin().await.unwrap();
    sqlx::query("INSERT INTO lessons(id,language,category,target_text,phonetic_or_kana,meaning_vi,workplace_context,workplace_context_vi,stroke_order_hints,difficulty_level) VALUES($1,'en','test','Test','','test','','','[]',1)").bind(&new_id).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let (_, next) = request(
        &app,
        &format!("/api/v1/sync/pull?since_seq=999999999&catalog_version={version}"),
        None,
        Some(token),
    )
    .await;
    assert_ne!(next["catalog_version"], first["catalog_version"]);
    assert!(next["lessons"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == new_id));
    let version2 = next["catalog_version"].as_str().unwrap();
    let mut tx = pool.begin().await.unwrap();
    sqlx::query("UPDATE lessons SET meaning_vi='rollback' WHERE id=$1")
        .bind(&new_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.rollback().await.unwrap();
    let (_, unchanged) = request(
        &app,
        &format!("/api/v1/sync/pull?catalog_version={version2}"),
        None,
        Some(token),
    )
    .await;
    assert_eq!(unchanged["catalog_version"], version2);
    assert_eq!(unchanged["lessons"], json!([]));
    sqlx::query("DELETE FROM lessons WHERE id=$1")
        .bind(&new_id)
        .execute(&pool)
        .await
        .unwrap();
}
