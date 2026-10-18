use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use server::{ai::AIService, fsrs::FSRS, routes::AppState};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tower::ServiceExt;
fn state() -> AppState {
    AppState {
        cache: Arc::new(server::redis_cache::RedisCache::default()),
        accounts: Default::default(),
        memory: Default::default(),
        lessons: server::data::get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    }
}
fn app() -> Router {
    server::create_app(state())
}
async fn request(
    app: &Router,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
) -> (u16, Value, Option<String>) {
    let mut r = Request::builder()
        .uri(path)
        .method(if body.is_some() { "POST" } else { "GET" })
        .header("content-type", "application/json");
    if let Some(t) = token {
        r = r.header("X-Sync-Token", t)
    }
    let res = app
        .clone()
        .oneshot(
            r.body(Body::from(body.map(|x| x.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = res.status().as_u16();
    let cache = res
        .headers()
        .get("x-cache")
        .map(|x| x.to_str().unwrap().to_owned());
    let b = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&b).unwrap_or(Value::Null),
        cache,
    )
}
#[tokio::test]
async fn accounts_isolate_same_ids_and_link_devices() {
    let a = app();
    let (s, one, _) = request(
        &a,
        "/api/v1/auth/register",
        Some(json!({"username":"alice","pin":"123456","device_id":"phone","platform":"android"})),
        None,
    )
    .await;
    assert_eq!(s, 201);
    let token = one["sync_token"].as_str().unwrap();
    let (s, two, _) = request(
        &a,
        "/api/v1/auth/register",
        Some(json!({"username":"bobby","pin":"654321","device_id":"phone","platform":"android"})),
        None,
    )
    .await;
    assert_eq!(s, 201);
    let token2 = two["sync_token"].as_str().unwrap();
    let review = json!({"reviews":[{"review_id":"same","item_id":"ja_hira_a","rating":3,"review_time":chrono::Utc::now()},{"review_id":"second","item_id":"ja_hira_i","rating":4,"review_time":chrono::Utc::now()}],"completed_lessons":[{"lesson_id":"ja_hira_a","completed_at":chrono::Utc::now()}]});
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review.clone()), Some(token))
            .await
            .0,
        200
    );
    let empty = request(&a, "/api/v1/sync/pull?since_seq=0", None, Some(token2)).await;
    assert_eq!(empty.1["cards"].as_array().unwrap().len(), 0);
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review), Some(token2))
            .await
            .0,
        200
    );
    let (s, login, _) = request(
        &a,
        "/api/v1/auth/login",
        Some(json!({"sync_token":token,"device_id":"desktop","platform":"linux"})),
        None,
    )
    .await;
    assert_eq!(s, 200);
    assert_eq!(login["devices"].as_array().unwrap().len(), 2);
    let (s, pull, _) = request(&a, "/api/v1/sync/pull?since_seq=0", None, Some(token)).await;
    assert_eq!(s, 200);
    assert_eq!(pull["cards"].as_array().unwrap().len(), 2);
    assert_eq!(pull["cards"][0]["reps"], 1);
    assert_eq!(pull["completed_lessons"].as_array().unwrap().len(), 1);
    let listed = request(&a, "/api/v1/auth/devices", None, Some(token2)).await;
    assert_eq!(listed.0, 200);
    assert_eq!(listed.1["devices"].as_array().unwrap().len(), 1);
    assert_eq!(listed.1["devices"][0]["device_id"], "phone");
    assert_eq!(listed.1["devices"][0]["platform"], "android");
    let (s, good_login, _) = request(
        &a,
        "/api/v1/auth/login",
        Some(json!({"username":"alice","pin":"123456","device_id":"desktop","platform":"linux"})),
        None,
    )
    .await;
    assert_eq!(s, 200);
    assert_eq!(good_login["user_id"], one["user_id"]);
    let seq = pull["latest_sync_seq"].as_i64().unwrap();
    assert!(seq > 0);
    assert_eq!(
        request(
            &a,
            &format!("/api/v1/sync/pull?since_seq={seq}"),
            None,
            Some(token)
        )
        .await
        .1["cards"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        request(&a, "/api/v1/sync/pull", None, None).await.1["cards"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        request(
            &a,
            "/api/v1/auth/login",
            Some(json!({"username":"alice","pin":"000000"})),
            None
        )
        .await
        .0,
        401
    );
}
#[tokio::test]
async fn invalid_identity_never_falls_back() {
    let a = app();
    assert_eq!(
        request(&a, "/api/v1/sync/pull", None, Some("invalid"))
            .await
            .0,
        401
    );
    assert_eq!(
        request(&a, "/api/v1/sync/pull?user_id=victim", None, None)
            .await
            .0,
        401
    );
    assert_eq!(
        request(
            &a,
            "/api/v1/fsrs/review",
            Some(json!({"item_id":"ja_hira_a","rating":3})),
            Some("invalid")
        )
        .await
        .0,
        401
    );
}
#[tokio::test]
async fn query_identity_is_an_assertion_on_post_routes() {
    let a = app();
    assert_eq!(
        request(
            &a,
            "/api/v1/fsrs/review?user_id=victim",
            Some(json!({"item_id":"ja_hira_a","rating":3})),
            None
        )
        .await
        .0,
        401
    );
    assert_eq!(
        request(
            &a,
            "/api/v1/sync?sync_token=invalid",
            Some(json!({"reviews":[]})),
            None
        )
        .await
        .0,
        401
    );
}

#[tokio::test]
async fn ai_cache_preserves_json_and_marks_hits() {
    let a = app();
    let req = json!({"target_language":"en","profession":"business","difficulty_level":"beginner","topic":"meeting","turn_count":2});
    let first = request(&a, "/api/v1/ai/dialogue", Some(req.clone()), None).await;
    assert_eq!(first.0, 200);
    assert_eq!(first.2.as_deref(), Some("MISS"));
    let second = request(&a, "/api/v1/ai/dialogue", Some(req), None).await;
    assert_eq!(second.2.as_deref(), Some("HIT"));
    assert_eq!(first.1, second.1);
}

#[tokio::test]
async fn ai_limiter_counts_hits_and_separates_accounts() {
    let state = state();
    state.accounts.write().await.insert(
        "fixture".into(),
        server::routes::auth::Account {
            user_id: "usr_fixture".into(),
            username: "fixture".into(),
            display_name: "Fixture".into(),
            pin_hash: "disabled".into(),
            sync_token: "fixture_token".into(),
            devices: vec![],
        },
    );
    let a = server::create_app(state);
    let body = json!({"target_language":"en","topic":"limit","turn_count":2});
    for _ in 0..120 {
        assert_eq!(
            request(&a, "/api/v1/ai/dialogue", Some(body.clone()), None)
                .await
                .0,
            200
        );
    }
    assert_eq!(
        request(&a, "/api/v1/ai/dialogue", Some(body), None).await.0,
        429
    );
    let other = request(
        &a,
        "/api/v1/ai/dialogue",
        Some(json!({"target_language":"en","topic":"limit","turn_count":2})),
        Some("fixture_token"),
    )
    .await;
    assert_eq!(other.0, 200);
    assert_eq!(other.2.as_deref(), Some("MISS"));
    assert_eq!(
        request(
            &a,
            "/api/v1/ai/dialogue",
            Some(json!({"target_language":"en"})),
            Some("invalid")
        )
        .await
        .0,
        401
    );
}

#[tokio::test]
async fn postgres_accounts_and_sequence_barriers() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    server::db::seed_lessons_if_empty(&pool, &server::data::get_seed_lessons())
        .await
        .unwrap();
    let suffix = chrono::Utc::now().timestamp_micros();
    let user1 = format!("usr_seq_{suffix}");
    let user2 = format!("usr_other_{suffix}");
    let token1 = format!("token_seq_{suffix}");
    let token2 = format!("token_other_{suffix}");
    for (user, token) in [(&user1, &token1), (&user2, &token2)] {
        sqlx::query("INSERT INTO user_accounts(user_id,username,pin_hash,sync_token) VALUES($1,$1,'disabled',$2)").bind(user).bind(token).execute(&pool).await.unwrap();
    }
    let make_app = || {
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
            pool: Some(pool.clone()),
        })
    };
    let a = make_app();
    let review = json!({"reviews":[{"review_id":"same_id","item_id":"ja_hira_a","rating":3,"review_time":chrono::Utc::now()}],"completed_lessons":[{"lesson_id":"ja_hira_a","completed_at":chrono::Utc::now()}]});
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review.clone()), Some(&token1))
            .await
            .0,
        200
    );
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review), Some(&token2))
            .await
            .0,
        200
    );
    assert_eq!(
        request(
            &make_app(),
            "/api/v1/sync/pull?since_seq=0",
            None,
            Some(&token1)
        )
        .await
        .1["cards"][0]["reps"],
        1
    );
    let mut writer = pool.begin().await.unwrap();
    server::routes::sync::writer_lock(&mut writer, &user1)
        .await
        .unwrap();
    server::routes::sync::card_lock(&mut writer, &user1, "ja_hira_i")
        .await
        .unwrap();
    server::db::upsert_card(
        &mut writer,
        &server::fsrs::FSRSCard::new("ja_hira_i".into()),
        &user1,
    )
    .await
    .unwrap();
    // Another card writer from the same account must remain concurrent.
    let same_account = request(
        &a,
        "/api/v1/fsrs/review",
        Some(json!({"item_id":"ja_hira_u","rating":3})),
        Some(&token1),
    );
    assert_eq!(
        tokio::time::timeout(std::time::Duration::from_secs(2), same_account)
            .await
            .unwrap()
            .0,
        200
    );
    let app2 = a.clone();
    let t = token1.clone();
    let pull = tokio::spawn(async move {
        request(&app2, "/api/v1/sync/pull?since_seq=0", None, Some(&t)).await
    });
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(!pull.is_finished());
    let other = request(&a, "/api/v1/sync/pull?since_seq=0", None, Some(&token2));
    assert_eq!(
        tokio::time::timeout(std::time::Duration::from_secs(2), other)
            .await
            .unwrap()
            .1["cards"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    writer.commit().await.unwrap();
    let result = pull.await.unwrap();
    assert_eq!(result.0, 200);
    assert_eq!(result.1["cards"].as_array().unwrap().len(), 3);
    assert_eq!(result.1["completed_lessons"].as_array().unwrap().len(), 1);
    let seq = result.1["latest_sync_seq"].as_i64().unwrap();
    assert!(seq > 0);
    assert_eq!(
        request(
            &make_app(),
            &format!("/api/v1/sync/pull?since_seq={seq}"),
            None,
            Some(&token1)
        )
        .await
        .1["cards"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        request(
            &a,
            "/api/v1/sync/pull?user_id=default_user",
            None,
            Some(&token1)
        )
        .await
        .0,
        401
    );
}

#[tokio::test]
async fn malformed_device_registration_does_not_reserve_username() {
    let state = state();
    let a = server::create_app(state.clone());
    assert_eq!(
        request(
            &a,
            "/api/v1/auth/register",
            Some(json!({"username":"reserve","pin":"1234","device_id":""})),
            None
        )
        .await
        .0,
        400
    );
    assert!(state.accounts.read().await.is_empty());
}

#[tokio::test]
async fn postgres_custom_practice_never_enters_public_catalog() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    server::db::seed_lessons_if_empty(&pool, &server::data::get_seed_lessons())
        .await
        .unwrap();
    let suffix = chrono::Utc::now().timestamp_micros();
    let alice = format!("custom_alice_{suffix}");
    let bob = format!("custom_bob_{suffix}");
    for user in [&alice, &bob] {
        sqlx::query("INSERT INTO user_accounts(user_id,username,pin_hash,sync_token) VALUES($1,$1,'disabled',$1)").bind(user).execute(&pool).await.unwrap();
    }
    let mut state = state();
    state.pool = Some(pool);
    let a = server::create_app(state);
    let direct_word = format!("private_direct_{suffix}");
    let batch_word = format!("private_batch_{suffix}");
    assert_eq!(
        request(
            &a,
            "/api/v1/fsrs/review",
            Some(json!({"item_id":direct_word,"rating":3})),
            Some(&alice)
        )
        .await
        .0,
        200
    );
    assert_eq!(request(&a,"/api/v1/sync",Some(json!({"reviews":[{"review_id":format!("private_review_{suffix}"),"item_id":batch_word,"rating":3,"review_time":chrono::Utc::now()}],"completed_lessons":[{"lesson_id":batch_word,"completed_at":chrono::Utc::now()}]})),Some(&alice)).await.0,200);
    for token in [Some(alice.as_str()), Some(bob.as_str()), None] {
        for path in ["/api/v1/lessons", "/api/v1/lessons?category=custom"] {
            let (status, catalog, _) = request(&a, path, None, token).await;
            assert_eq!(status, 200);
            for word in [&direct_word, &batch_word] {
                assert!(
                    !catalog.as_array().unwrap().iter().any(|l| l["id"] == *word),
                    "private word {word} leaked through {path}"
                );
            }
        }
        for path in [
            "/api/v1/sync/pull?since_seq=0",
            "/api/v1/sync/pull?since=1970-01-01T00:00:00Z",
        ] {
            let (status, pull, _) = request(&a, path, None, token).await;
            assert_eq!(status, 200);
            for word in [&direct_word, &batch_word] {
                for field in ["lessons", "new_lessons"] {
                    assert!(
                        !pull[field]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|l| l["id"] == *word),
                        "private word leaked through {field}"
                    );
                }
            }
            if token == Some(alice.as_str()) {
                for word in [&direct_word, &batch_word] {
                    assert!(pull["cards"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|c| c["item_id"] == *word && c["reps"] == 1));
                }
                assert!(pull["completed_lessons"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|c| c["lesson_id"] == batch_word));
            } else {
                for word in [&direct_word, &batch_word] {
                    assert!(!pull["cards"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|c| c["item_id"] == *word));
                }
            }
        }
        for word in [&direct_word, &batch_word] {
            assert_eq!(
                request(&a, &format!("/api/v1/lessons/{word}"), None, token)
                    .await
                    .0,
                404
            );
        }
    }
    // Legacy anonymous ad-hoc reviews still synchronize through the default profile.
    let legacy = format!("private_legacy_{suffix}");
    assert_eq!(
        request(
            &a,
            "/api/v1/fsrs/review",
            Some(json!({"item_id":legacy,"rating":3})),
            None
        )
        .await
        .0,
        200
    );
    let (_, pull, _) = request(&a, "/api/v1/sync/pull?since_seq=0", None, None).await;
    assert!(pull["cards"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["item_id"] == legacy && c["reps"] == 1));
}

#[tokio::test]
async fn fallback_catalog_also_excludes_synthetic_custom_lessons() {
    let mut state = state();
    let mut custom = state.lessons[0].clone();
    custom.id = "private_fallback".into();
    custom.category = "custom".into();
    state.lessons.insert(0, custom);
    let a = server::create_app(state);
    let (_, catalog, _) = request(&a, "/api/v1/lessons", None, None).await;
    assert!(!catalog
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["id"] == "private_fallback"));
    let (_, due, _) = request(&a, "/api/v1/fsrs/due", None, None).await;
    assert!(!due
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["id"] == "private_fallback"));
    assert_eq!(
        request(&a, "/api/v1/lessons/private_fallback", None, None)
            .await
            .0,
        404
    );
    let (_, pull, _) = request(&a, "/api/v1/sync/pull?since_seq=0", None, None).await;
    assert!(!pull["lessons"]
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["id"] == "private_fallback"));
}
