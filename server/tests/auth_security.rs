use axum::{body::Body, extract::ConnectInfo, http::Request, Router};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use server::{ai::AIService, fsrs::FSRS, routes::AppState};
use std::{net::SocketAddr, sync::Arc};
use tower::ServiceExt;
fn state() -> AppState {
    AppState {
        cache: Arc::new(server::redis_cache::RedisCache::new(None)),
        accounts: Default::default(),
        auth_sessions: Default::default(),
        memory: Default::default(),
        lessons: vec![],
        cards: Default::default(),
        seen_review_ids: Default::default(),
        card_updated_at: Default::default(),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    }
}
async fn call(
    app: &Router,
    method: &str,
    path: &str,
    body: Value,
    token: Option<&str>,
    spoof: usize,
) -> (u16, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header("x-forwarded-for", format!("192.0.2.{spoof}"))
        .header("x-real-ip", format!("192.0.2.{spoof}"));
    if let Some(t) = token {
        req = req.header("x-sync-token", t);
    }
    let mut req = req.body(Body::from(body.to_string())).unwrap();
    req.extensions_mut().insert(ConnectInfo(
        "127.0.0.1:12345".parse::<SocketAddr>().unwrap(),
    ));
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status().as_u16();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
async fn register(app: &Router) -> Value {
    let (s, a) = call(
        app,
        "POST",
        "/api/v1/auth/register",
        json!({"username":"alice","pin":"1234","device_id":"phone","platform":"android"}),
        None,
        0,
    )
    .await;
    assert_eq!(s, 201);
    a
}
#[tokio::test]
async fn device_sessions_are_independent_and_revocation_cannot_relink() {
    let app = server::create_app(state());
    let a = register(&app).await;
    let phone = a["sync_token"].as_str().unwrap();
    let (s, b) = call(
        &app,
        "POST",
        "/api/v1/auth/login",
        json!({"sync_token":phone,"device_id":"desktop","platform":"linux"}),
        None,
        0,
    )
    .await;
    assert_eq!(s, 200);
    let desktop = b["sync_token"].as_str().unwrap();
    assert_ne!(
        phone, desktop,
        "each device needs an independent credential"
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/v1/auth/devices/desktop",
            json!({}),
            Some(phone),
            0
        )
        .await
        .0,
        204
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(desktop),
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"sync_token":desktop,"device_id":"relinked"}),
            None,
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(phone),
            0
        )
        .await
        .0,
        200
    );
}
#[tokio::test]
async fn pin_change_requires_current_pin_revokes_other_devices_and_returns_fresh_token() {
    let app = server::create_app(state());
    let a = register(&app).await;
    let phone = a["sync_token"].as_str().unwrap();
    let (_, b) = call(
        &app,
        "POST",
        "/api/v1/auth/login",
        json!({"sync_token":phone,"device_id":"web","platform":"web"}),
        None,
        0,
    )
    .await;
    let web = b["sync_token"].as_str().unwrap();
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/pin/change",
            json!({"current_pin":"9999","new_pin":"5678"}),
            Some(phone),
            0
        )
        .await
        .0,
        401
    );
    let (s, c) = call(
        &app,
        "POST",
        "/api/v1/auth/pin/change",
        json!({"current_pin":"1234","new_pin":"5678"}),
        Some(phone),
        0,
    )
    .await;
    assert_eq!(s, 200);
    let fresh = c["sync_token"].as_str().unwrap();
    assert_ne!(fresh, phone);
    assert!(
        c["devices"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["device_id"] == "phone" && d["platform"] == "android"),
        "credential replacement must preserve device platform"
    );
    for old in [phone, web] {
        assert_eq!(
            call(&app, "GET", "/api/v1/auth/devices", json!({}), Some(old), 0)
                .await
                .0,
            401
        );
    }
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(fresh),
            0
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"username":"alice","pin":"1234","device_id":"old"}),
            None,
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"username":"alice","pin":"5678","device_id":"new"}),
            None,
            0
        )
        .await
        .0,
        200
    );
}
#[tokio::test]
async fn rotate_requires_pin_and_only_replaces_current_session() {
    let app = server::create_app(state());
    let a = register(&app).await;
    let phone = a["sync_token"].as_str().unwrap();
    let (_, b) = call(
        &app,
        "POST",
        "/api/v1/auth/login",
        json!({"sync_token":phone,"device_id":"web"}),
        None,
        0,
    )
    .await;
    let web = b["sync_token"].as_str().unwrap();
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/token/rotate",
            json!({"current_pin":"9999"}),
            Some(phone),
            0
        )
        .await
        .0,
        401
    );
    let (s, c) = call(
        &app,
        "POST",
        "/api/v1/auth/token/rotate",
        json!({"current_pin":"1234"}),
        Some(phone),
        0,
    )
    .await;
    assert_eq!(s, 200);
    let fresh = c["sync_token"].as_str().unwrap();
    assert_ne!(fresh, phone);
    assert!(
        c["devices"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["device_id"] == "phone" && d["platform"] == "android"),
        "credential replacement must preserve device platform"
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(phone),
            0
        )
        .await
        .0,
        401
    );
    for token in [web, fresh] {
        assert_eq!(
            call(
                &app,
                "GET",
                "/api/v1/auth/devices",
                json!({}),
                Some(token),
                0
            )
            .await
            .0,
            200
        );
    }
}
#[tokio::test]
async fn spoofed_forwarding_headers_cannot_bypass_login_or_registration_limits() {
    for path in ["/api/v1/auth/register", "/api/v1/auth/login"] {
        let app = server::create_app(state());
        let mut limited = false;
        for i in 0..65 {
            let (s,_)=call(&app,"POST",path,json!({"username":format!("missing_{i}"),"pin":"bad","sync_token":format!("invalid_{i}"),"device_id":format!("device_{i}")}),None,i).await;
            if s == 429 {
                limited = true;
                break;
            }
        }
        assert!(
            limited,
            "{path} must bound socket peer attempts despite rotating account/device/header values"
        );
    }
}

#[tokio::test]
async fn expired_sessions_are_rejected_and_credentials_are_never_retained_in_plaintext() {
    let state = state();
    let app = server::create_app(state.clone());
    let a = register(&app).await;
    let token = a["sync_token"].as_str().unwrap();
    assert!(state
        .accounts
        .read()
        .await
        .values()
        .all(|a| a.sync_token != token));
    let mut sessions = state.auth_sessions.write().await;
    assert_eq!(sessions.sessions.len(), 1);
    let session = sessions.sessions.values_mut().next().unwrap();
    assert_ne!(session.token_hash, token);
    assert_eq!(session.token_hash.len(), 64);
    session.expires_at = chrono::Utc::now() - chrono::Duration::seconds(1);
    drop(sessions);
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(token),
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"sync_token":token,"device_id":"expired-relink"}),
            None,
            0
        )
        .await
        .0,
        401
    );
}
#[tokio::test]
async fn legacy_exchange_consumes_old_credential_and_revocation_never_resurrects_it() {
    for exchange in [true, false] {
        let state = state();
        state.accounts.write().await.insert(
            "legacy".into(),
            server::routes::auth::Account {
                user_id: "usr_legacy".into(),
                username: "legacy".into(),
                display_name: "Legacy".into(),
                pin_hash: "disabled".into(),
                sync_token: "old_plaintext_token".into(),
                devices: vec![],
            },
        );
        let app = server::create_app(state.clone());
        assert_eq!(
            call(
                &app,
                "GET",
                "/api/v1/auth/devices",
                json!({}),
                Some("old_plaintext_token"),
                0
            )
            .await
            .0,
            200
        );
        assert_eq!(state.accounts.read().await["legacy"].sync_token, "");
        if exchange {
            let (s, a) = call(
                &app,
                "POST",
                "/api/v1/auth/login",
                json!({"sync_token":"old_plaintext_token","device_id":"linux"}),
                None,
                0,
            )
            .await;
            assert_eq!(s, 200);
            assert_ne!(a["sync_token"], "old_plaintext_token");
        } else {
            assert_eq!(
                call(
                    &app,
                    "DELETE",
                    "/api/v1/auth/devices/__legacy__",
                    json!({}),
                    Some("old_plaintext_token"),
                    0
                )
                .await
                .0,
                204
            );
        }
        for _ in 0..2 {
            assert_eq!(
                call(
                    &app,
                    "GET",
                    "/api/v1/auth/devices",
                    json!({}),
                    Some("old_plaintext_token"),
                    0
                )
                .await
                .0,
                401
            );
            assert_eq!(
                call(
                    &app,
                    "POST",
                    "/api/v1/auth/login",
                    json!({"sync_token":"old_plaintext_token","device_id":"relink"}),
                    None,
                    0
                )
                .await
                .0,
                401
            );
        }
    }
}
#[tokio::test]
async fn pin_login_budget_survives_changing_device_and_forwarding_headers() {
    let app = server::create_app(state());
    for i in 0..10 {
        assert_eq!(
            call(
                &app,
                "POST",
                "/api/v1/auth/login",
                json!({"username":"missing","pin":"1234","device_id":format!("pin_device_{i}")}),
                None,
                i
            )
            .await
            .0,
            401
        );
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"username":"missing","pin":"1234","device_id":"new"}),
            None,
            11
        )
        .await
        .0,
        429
    );
}
#[tokio::test]
async fn device_deletion_is_scoped_to_account_and_requires_authentication() {
    let app = server::create_app(state());
    let a = register(&app).await;
    let (s, b) = call(
        &app,
        "POST",
        "/api/v1/auth/register",
        json!({"username":"bobby","pin":"1234","device_id":"private"}),
        None,
        0,
    )
    .await;
    assert_eq!(s, 201);
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/v1/auth/devices/private",
            json!({}),
            Some(a["sync_token"].as_str().unwrap()),
            0
        )
        .await
        .0,
        404
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/v1/auth/devices/phone",
            json!({}),
            None,
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(b["sync_token"].as_str().unwrap()),
            0
        )
        .await
        .0,
        200
    );
}

#[tokio::test]
async fn postgres_sessions_survive_restart_and_revocation_is_durable() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let suffix = chrono::Utc::now().timestamp_micros();
    let mut state = state();
    state.pool = Some(pool.clone());
    let app = server::create_app(state.clone());
    let (s,a)=call(&app,"POST","/api/v1/auth/register",json!({"username":format!("auth_{suffix}"),"pin":"1234","device_id":"phone","platform":"android"}),None,0).await;
    assert_eq!(s, 201);
    let phone = a["sync_token"].as_str().unwrap();
    let user = a["user_id"].as_str().unwrap();
    let stored: String =
        sqlx::query_scalar("SELECT sync_token FROM user_accounts WHERE user_id=$1")
            .bind(user)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_ne!(stored, phone);
    let hash: String = sqlx::query_scalar("SELECT token_hash FROM auth_sessions WHERE user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_ne!(hash, phone);
    assert_eq!(hash.len(), 64);
    let (_, b) = call(
        &app,
        "POST",
        "/api/v1/auth/login",
        json!({"sync_token":phone,"device_id":"web","platform":"web"}),
        None,
        0,
    )
    .await;
    let web = b["sync_token"].as_str().unwrap();
    assert_ne!(phone, web);
    state.auth_sessions = Default::default();
    let restarted = server::create_app(state.clone());
    assert_eq!(
        call(
            &restarted,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(web),
            0
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/v1/auth/devices/web",
            json!({}),
            Some(phone),
            0
        )
        .await
        .0,
        204
    );
    assert_eq!(
        call(
            &restarted,
            "POST",
            "/api/v1/auth/login",
            json!({"sync_token":web,"device_id":"relinked"}),
            None,
            0
        )
        .await
        .0,
        401
    );
    let (s, c) = call(
        &restarted,
        "POST",
        "/api/v1/auth/pin/change",
        json!({"current_pin":"1234","new_pin":"5678"}),
        Some(phone),
        0,
    )
    .await;
    assert_eq!(s, 200);
    let fresh = c["sync_token"].as_str().unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(phone),
            0
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(fresh),
            0
        )
        .await
        .0,
        200
    );
    sqlx::query("UPDATE auth_sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE user_id=$1").bind(user).execute(&pool).await.unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/v1/auth/devices",
            json!({}),
            Some(fresh),
            0
        )
        .await
        .0,
        401
    );
    sqlx::query("DELETE FROM user_accounts WHERE user_id=$1")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn postgres_migration_hashes_legacy_tokens_with_bounded_exchange_window() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    let schema = format!("auth_migration_{}", chrono::Utc::now().timestamp_micros());
    // This schema belongs exclusively to the test; rollback leaves shared fixtures alone.
    let mut tx = pool.begin().await.unwrap();
    sqlx::raw_sql(&format!(
        "CREATE SCHEMA {schema}; SET LOCAL search_path TO {schema};"
    ))
    .execute(&mut *tx)
    .await
    .unwrap();
    for sql in [
        include_str!("../migrations/20261001000001_initial_schema.sql"),
        include_str!("../migrations/20261001000002_sync_and_review_logs.sql"),
        include_str!("../migrations/20261001000003_gen3_sync_and_accounts.sql"),
        include_str!("../migrations/20261017000004_private_vocabulary.sql"),
    ] {
        sqlx::raw_sql(sql).execute(&mut *tx).await.unwrap();
    }
    sqlx::query("INSERT INTO user_accounts(user_id,username,pin_hash,sync_token) VALUES('usr_migration','migration','disabled','legacy_secret')").execute(&mut *tx).await.unwrap();
    sqlx::raw_sql(include_str!(
        "../migrations/20261019000005_auth_sessions.sql"
    ))
    .execute(&mut *tx)
    .await
    .unwrap();
    let (stored,hash,device,expires):(String,String,String,chrono::DateTime<chrono::Utc>)=sqlx::query_as("SELECT a.sync_token,s.token_hash,s.device_id,s.expires_at FROM user_accounts a JOIN auth_sessions s USING(user_id) WHERE a.user_id='usr_migration'").fetch_one(&mut *tx).await.unwrap();
    assert_eq!(stored, "retired_usr_migration");
    assert_eq!(device, "__legacy__");
    let expected: String =
        sqlx::query_scalar("SELECT encode(sha256(convert_to('legacy_secret','UTF8')),'hex')")
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert_eq!(hash, expected);
    assert!(expires > chrono::Utc::now() + chrono::Duration::days(6));
    assert!(expires <= chrono::Utc::now() + chrono::Duration::days(7));
    sqlx::query(
        "DELETE FROM user_devices WHERE user_id='usr_migration' AND device_id='__legacy__'",
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    let count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM auth_sessions WHERE user_id='usr_migration'")
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert_eq!(count, 0);
    tx.rollback().await.unwrap();
}

#[tokio::test]
async fn device_login_budget_survives_rotating_account_credentials() {
    let app = server::create_app(state());
    for i in 0..10 {
        assert_eq!(
            call(
                &app,
                "POST",
                "/api/v1/auth/login",
                json!({"sync_token":format!("missing_{i}"),"device_id":"same_device"}),
                None,
                i
            )
            .await
            .0,
            401
        );
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/login",
            json!({"sync_token":"another_missing","device_id":"same_device"}),
            None,
            11
        )
        .await
        .0,
        429
    );
}

#[tokio::test]
async fn reserved_legacy_device_is_rejected_before_registration_claims_username() {
    let state = state();
    let app = server::create_app(state.clone());
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/v1/auth/register",
            json!({"username":"reserved_device","pin":"1234","device_id":"__legacy__"}),
            None,
            0
        )
        .await
        .0,
        400
    );
    assert!(
        state.accounts.read().await.is_empty(),
        "rejected reserved device must not claim an account username"
    );
    assert_eq!(call(&app,"POST","/api/v1/auth/register",json!({"username":"reserved_device","pin":"1234","device_id":"phone","platform":"android"}),None,0).await.0,201);
}
