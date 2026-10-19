use super::AppState;
use axum::{
    extract::{ConnectInfo, Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, net::SocketAddr, sync::Arc};
use tokio::sync::RwLock;
pub const DEFAULT_USER: &str = "default_user";
#[derive(Clone, Serialize, sqlx::FromRow)]
pub struct Device {
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
    pub last_sync_seq: i64,
    pub last_seen_at: DateTime<Utc>,
}
#[derive(Clone, Serialize, sqlx::FromRow)]
pub struct Account {
    pub user_id: String,
    pub username: String,
    pub display_name: String,
    #[serde(skip_serializing)]
    pub pin_hash: String,
    pub sync_token: String,
    #[sqlx(skip)]
    pub devices: Vec<Device>,
}
pub type Accounts = Arc<RwLock<HashMap<String, Account>>>;
#[derive(Default, Deserialize)]
pub struct Identity {
    pub user_id: Option<String>,
    pub sync_token: Option<String>,
}
impl Identity {
    pub fn merge(self, other: Self) -> Result<Self, StatusCode> {
        if self
            .user_id
            .as_ref()
            .zip(other.user_id.as_ref())
            .is_some_and(|(a, b)| a != b)
            || self
                .sync_token
                .as_ref()
                .zip(other.sync_token.as_ref())
                .is_some_and(|(a, b)| a != b)
        {
            return Err(StatusCode::UNAUTHORIZED);
        }
        Ok(Self {
            user_id: self.user_id.or(other.user_id),
            sync_token: self.sync_token.or(other.sync_token),
        })
    }
}
#[derive(Deserialize)]
pub struct Credentials {
    pub username: Option<String>,
    pub pin: Option<String>,
    pub display_name: Option<String>,
    pub sync_token: Option<String>,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
}
impl Credentials {
    fn validate_device(&self) -> Result<(), StatusCode> {
        if self
            .device_id
            .as_ref()
            .is_some_and(|s| s.is_empty() || s == "__legacy__" || s.len() > 64 || s.contains('\0'))
            || self
                .device_name
                .as_ref()
                .is_some_and(|s| s.len() > 128 || s.contains('\0'))
            || self
                .platform
                .as_ref()
                .is_some_and(|s| s.len() > 32 || s.contains('\0'))
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        Ok(())
    }
}
fn token(prefix: &str) -> String {
    let mut b = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut b);
    format!("{prefix}{}", crate::pin::hex(&b[..24]))
}
fn db_error(e: sqlx::Error) -> StatusCode {
    tracing::warn!("Account storage failed: {e}");
    StatusCode::INTERNAL_SERVER_ERROR
}
// Only a digest is retained after a credential has been returned to its client.
#[derive(Clone, sqlx::FromRow)]
pub struct Session {
    pub token_hash: String,
    pub user_id: String,
    pub device_id: String,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}
pub struct SessionStore {
    pub sessions: HashMap<String, Session>,
    legacy_deadline: DateTime<Utc>,
}
impl Default for SessionStore {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            legacy_deadline: Utc::now() + chrono::Duration::days(7),
        }
    }
}
pub type Sessions = Arc<RwLock<SessionStore>>;
fn digest(value: &str) -> String {
    crate::pin::hex(&crate::pin::sha256(value.as_bytes()))
}
async fn find(state: &AppState, username: &str) -> Result<Option<Account>, StatusCode> {
    if let Some(pool) = &state.pool {
        sqlx::query_as::<_,Account>("SELECT user_id,username,display_name,pin_hash,sync_token FROM user_accounts WHERE username=$1 AND user_id <> 'default_user'").bind(username).fetch_optional(pool).await.map_err(db_error)
    } else {
        Ok(state
            .accounts
            .read()
            .await
            .get(username)
            .filter(|a| a.user_id != DEFAULT_USER)
            .cloned())
    }
}
async fn session_account(state: &AppState, value: &str) -> Result<(Account, Session), StatusCode> {
    if value.is_empty() || value.len() > 128 {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let hashed = digest(value);
    if let Some(pool) = &state.pool {
        let session=sqlx::query_as::<_,Session>("SELECT token_hash,user_id,device_id,expires_at,revoked_at FROM auth_sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>clock_timestamp()")
            .bind(&hashed).fetch_optional(pool).await.map_err(db_error)?.ok_or(StatusCode::UNAUTHORIZED)?;
        let account=sqlx::query_as::<_,Account>("SELECT user_id,username,display_name,pin_hash,sync_token FROM user_accounts WHERE user_id=$1 AND user_id <> 'default_user'")
            .bind(&session.user_id).fetch_optional(pool).await.map_err(db_error)?.ok_or(StatusCode::UNAUTHORIZED)?;
        return Ok((account, session));
    }
    let mut store = state.auth_sessions.write().await;
    // Memory mode supports pre-upgrade fixtures/accounts for a bounded window.
    // Consume plaintext immediately, so deleting a session can never resurrect it.
    if !store.sessions.contains_key(&hashed) && store.legacy_deadline > Utc::now() {
        let mut all = state.accounts.write().await;
        if let Some(a) = all
            .values_mut()
            .find(|a| a.user_id != DEFAULT_USER && a.sync_token == value)
        {
            a.sync_token.clear();
            if !a.devices.iter().any(|d| d.device_id == "__legacy__") {
                a.devices.push(Device {
                    device_id: "__legacy__".into(),
                    device_name: "Legacy session".into(),
                    platform: "unknown".into(),
                    last_sync_seq: 0,
                    last_seen_at: Utc::now(),
                });
            }
            let legacy = Session {
                token_hash: hashed.clone(),
                user_id: a.user_id.clone(),
                device_id: "__legacy__".into(),
                expires_at: store.legacy_deadline,
                revoked_at: None,
            };
            store.sessions.insert(hashed.clone(), legacy);
        }
    }
    let session = store
        .sessions
        .get(&hashed)
        .filter(|s| s.revoked_at.is_none() && s.expires_at > Utc::now())
        .cloned()
        .ok_or(StatusCode::UNAUTHORIZED)?;
    let account = state
        .accounts
        .read()
        .await
        .values()
        .find(|a| a.user_id == session.user_id)
        .cloned()
        .ok_or(StatusCode::UNAUTHORIZED)?;
    Ok((account, session))
}
fn supplied_token(headers: &HeaderMap, identity: &Identity) -> Result<Option<String>, StatusCode> {
    let mut credentials = Vec::new();
    for v in headers.get_all("x-sync-token") {
        credentials.push(v.to_str().map_err(|_| StatusCode::UNAUTHORIZED)?.to_owned());
    }
    for v in headers.get_all("authorization") {
        credentials.push(
            v.to_str()
                .map_err(|_| StatusCode::UNAUTHORIZED)?
                .strip_prefix("Bearer ")
                .ok_or(StatusCode::UNAUTHORIZED)?
                .to_owned(),
        );
    }
    if let Some(v) = &identity.sync_token {
        credentials.push(v.clone());
    }
    if let Some(t) = credentials.first() {
        if credentials.iter().any(|v| v != t) {
            return Err(StatusCode::UNAUTHORIZED);
        }
    }
    Ok(credentials.into_iter().next())
}
pub async fn resolve(
    state: &AppState,
    headers: &HeaderMap,
    identity: &Identity,
) -> Result<String, StatusCode> {
    let user = match supplied_token(headers, identity)? {
        Some(t) => session_account(state, &t).await?.0.user_id,
        None => DEFAULT_USER.to_owned(),
    };
    if identity.user_id.as_ref().is_some_and(|u| u != &user) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(user)
}
// Socket IP is the trust boundary. Forwarding headers deliberately play no role.
async fn limit(
    state: &AppState,
    peer: Option<ConnectInfo<SocketAddr>>,
    operation: &str,
    account: &str,
    device: Option<&str>,
) -> Result<(), StatusCode> {
    let peer = peer
        .map(|p| p.0.ip().to_string())
        .unwrap_or_else(|| "unknown-peer".into());
    let ceiling = if operation == "register" { 10 } else { 60 };
    let dimensions = [
        (format!("auth:{operation}:peer:{peer}"), ceiling),
        (format!("auth:{operation}:account:{}", digest(account)), 10),
        (
            format!(
                "auth:{operation}:device:{}",
                digest(device.unwrap_or("unknown-device"))
            ),
            10,
        ),
    ];
    for (key, max) in dimensions {
        if !state.cache.check_rate_limit(&key, max, 60).await {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
    }
    Ok(())
}
async fn verify_pin(account: &Account, pin: &str) -> Result<(), StatusCode> {
    if pin.len() > 12 {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let pin = pin.to_owned();
    let stored = account.pin_hash.clone();
    if tokio::task::spawn_blocking(move || crate::pin::verify(&pin, &stored))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    {
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}
async fn devices(state: &AppState, user: &str) -> Result<Vec<Device>, StatusCode> {
    if let Some(p) = &state.pool {
        sqlx::query_as::<_,Device>("SELECT device_id,device_name,platform,last_sync_seq,last_seen_at FROM user_devices WHERE user_id=$1 ORDER BY device_id").bind(user).fetch_all(p).await.map_err(db_error)
    } else {
        Ok(state
            .accounts
            .read()
            .await
            .values()
            .find(|a| a.user_id == user)
            .map(|a| a.devices.clone())
            .unwrap_or_default())
    }
}
// Account locking serializes issuance and revocation across server processes.
// Revalidate the source session and PIN snapshot under that lock to close races.
async fn issue(
    state: &AppState,
    mut account: Account,
    req: &Credentials,
    source: Option<&Session>,
    rotate: bool,
    new_pin: Option<String>,
) -> Result<Account, StatusCode> {
    let raw = token("lct_");
    let device_id = req.device_id.clone().unwrap_or_else(|| token("dev_"));
    if device_id == "__legacy__" && source.is_none() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let device = Device {
        device_id: device_id.clone(),
        device_name: req
            .device_name
            .clone()
            .unwrap_or_else(|| "Lingua Client".into()),
        platform: req.platform.clone().unwrap_or_else(|| "unknown".into()),
        last_sync_seq: 0,
        last_seen_at: Utc::now(),
    };
    let session = Session {
        token_hash: digest(&raw),
        user_id: account.user_id.clone(),
        device_id: device_id.clone(),
        expires_at: Utc::now() + chrono::Duration::days(30),
        revoked_at: None,
    };
    if let Some(pool) = &state.pool {
        let mut tx = pool.begin().await.map_err(db_error)?;
        let current: Option<String> =
            sqlx::query_scalar("SELECT pin_hash FROM user_accounts WHERE user_id=$1 FOR UPDATE")
                .bind(&account.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(db_error)?;
        if current.as_deref() != Some(&account.pin_hash) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        if let Some(old) = source {
            let valid:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM auth_sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>clock_timestamp())").bind(&old.token_hash).fetch_one(&mut *tx).await.map_err(db_error)?;
            if !valid {
                return Err(StatusCode::UNAUTHORIZED);
            }
        }
        if let Some(ref hash) = new_pin {
            sqlx::query("UPDATE user_accounts SET pin_hash=$2 WHERE user_id=$1")
                .bind(&account.user_id)
                .bind(hash)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            sqlx::query("UPDATE auth_sessions SET revoked_at=clock_timestamp() WHERE user_id=$1 AND revoked_at IS NULL").bind(&account.user_id).execute(&mut *tx).await.map_err(db_error)?;
        } else if rotate || source.is_some_and(|s| s.device_id == "__legacy__") {
            if let Some(old) = source {
                sqlx::query(
                    "UPDATE auth_sessions SET revoked_at=clock_timestamp() WHERE token_hash=$1",
                )
                .bind(&old.token_hash)
                .execute(&mut *tx)
                .await
                .map_err(db_error)?;
            }
        }
        // A login on an existing device replaces that device's credentials only.
        sqlx::query("UPDATE auth_sessions SET revoked_at=clock_timestamp() WHERE user_id=$1 AND device_id=$2 AND revoked_at IS NULL").bind(&account.user_id).bind(&device_id).execute(&mut *tx).await.map_err(db_error)?;
        sqlx::query("INSERT INTO user_devices(user_id,device_id,device_name,platform) VALUES($1,$2,$3,$4) ON CONFLICT(user_id,device_id) DO UPDATE SET device_name=EXCLUDED.device_name,platform=EXCLUDED.platform,last_seen_at=clock_timestamp()").bind(&account.user_id).bind(&device_id).bind(&device.device_name).bind(&device.platform).execute(&mut *tx).await.map_err(db_error)?;
        sqlx::query("INSERT INTO auth_sessions(token_hash,user_id,device_id,expires_at) VALUES($1,$2,$3,$4)").bind(&session.token_hash).bind(&account.user_id).bind(&device_id).bind(session.expires_at).execute(&mut *tx).await.map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
    } else {
        let mut store = state.auth_sessions.write().await;
        let mut all = state.accounts.write().await;
        let a = all
            .get_mut(&account.username)
            .ok_or(StatusCode::UNAUTHORIZED)?;
        if a.pin_hash != account.pin_hash {
            return Err(StatusCode::UNAUTHORIZED);
        }
        if let Some(old) = source {
            if !store
                .sessions
                .get(&old.token_hash)
                .is_some_and(|s| s.revoked_at.is_none() && s.expires_at > Utc::now())
            {
                return Err(StatusCode::UNAUTHORIZED);
            }
        }
        for old in store
            .sessions
            .values_mut()
            .filter(|s| s.user_id == account.user_id)
        {
            if new_pin.is_some()
                || old.device_id == device_id
                || source.is_some_and(|s| {
                    s.token_hash == old.token_hash && (rotate || s.device_id == "__legacy__")
                })
            {
                old.revoked_at = Some(Utc::now());
            }
        }
        if let Some(hash) = new_pin {
            a.pin_hash = hash;
        }
        a.sync_token.clear();
        if let Some(d) = a.devices.iter_mut().find(|d| d.device_id == device_id) {
            d.device_name = device.device_name;
            d.platform = device.platform;
            d.last_seen_at = Utc::now();
        } else {
            a.devices.push(device);
        }
        store.sessions.insert(session.token_hash.clone(), session);
    }
    account.sync_token = raw;
    account.devices = devices(state, &account.user_id).await?;
    Ok(account)
}
pub async fn register(
    State(state): State<AppState>,
    peer: Option<ConnectInfo<SocketAddr>>,
    Json(req): Json<Credentials>,
) -> Result<(StatusCode, Json<Account>), StatusCode> {
    let rate_username = req.username.as_deref().unwrap_or("").trim().to_lowercase();
    limit(
        &state,
        peer,
        "register",
        &rate_username,
        req.device_id.as_deref(),
    )
    .await?;
    req.validate_device()?;
    let username = req.username.as_deref().unwrap_or("").trim().to_lowercase();
    let pin = req.pin.as_deref().unwrap_or("");
    if !(3..=32).contains(&username.len())
        || !username
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        || username == "default"
        || !(4..=12).contains(&pin.len())
        || !pin.bytes().all(|b| b.is_ascii_digit())
        || req
            .display_name
            .as_ref()
            .is_some_and(|s| s.len() > 128 || s.contains('\0'))
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    if find(&state, &username).await?.is_some() {
        return Err(StatusCode::CONFLICT);
    }
    let pin = pin.to_owned();
    let pin_hash = tokio::task::spawn_blocking(move || crate::pin::hash(&pin))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let account = Account {
        user_id: token("usr_"),
        username: username.clone(),
        display_name: req.display_name.clone().unwrap_or_else(|| username.clone()),
        pin_hash,
        sync_token: String::new(),
        devices: vec![],
    };
    if let Some(p) = &state.pool {
        sqlx::query("INSERT INTO user_accounts(user_id,username,display_name,pin_hash,sync_token) VALUES($1,$2,$3,$4,$5)").bind(&account.user_id).bind(&username).bind(&account.display_name).bind(&account.pin_hash).bind(format!("retired_{}",account.user_id)).execute(p).await.map_err(|e|if e.as_database_error().is_some_and(|e|e.is_unique_violation()){StatusCode::CONFLICT}else{db_error(e)})?;
    } else {
        let mut all = state.accounts.write().await;
        if all.contains_key(&username) {
            return Err(StatusCode::CONFLICT);
        }
        all.insert(username, account.clone());
    }
    Ok((
        StatusCode::CREATED,
        Json(issue(&state, account, &req, None, false, None).await?),
    ))
}
pub async fn login(
    State(state): State<AppState>,
    peer: Option<ConnectInfo<SocketAddr>>,
    Json(req): Json<Credentials>,
) -> Result<Json<Account>, StatusCode> {
    let username = req.username.as_deref().unwrap_or("").trim().to_lowercase();
    limit(
        &state,
        peer,
        "login",
        req.sync_token.as_deref().unwrap_or(&username),
        req.device_id.as_deref(),
    )
    .await?;
    req.validate_device()?;
    let (account, source) = if let Some(t) = &req.sync_token {
        let (account, session) = session_account(&state, t).await?;
        if !state
            .cache
            .check_rate_limit(&format!("auth:login:user:{}", account.user_id), 10, 60)
            .await
        {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        (account, Some(session))
    } else {
        let a = find(&state, &username)
            .await?
            .ok_or(StatusCode::UNAUTHORIZED)?;
        verify_pin(&a, req.pin.as_deref().unwrap_or("")).await?;
        (a, None)
    };
    // Token login without a supplied device still creates a separate session.
    Ok(Json(
        issue(&state, account, &req, source.as_ref(), false, None).await?,
    ))
}
#[derive(Deserialize)]
pub struct Reauthenticate {
    pub current_pin: String,
    pub new_pin: Option<String>,
}
async fn authenticated(
    state: &AppState,
    headers: &HeaderMap,
    id: &Identity,
) -> Result<(Account, Session), StatusCode> {
    let t = supplied_token(headers, id)?.ok_or(StatusCode::UNAUTHORIZED)?;
    let pair = session_account(state, &t).await?;
    if id.user_id.as_ref().is_some_and(|u| u != &pair.0.user_id) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(pair)
}
async fn replace_token(
    state: AppState,
    peer: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    req: Reauthenticate,
    change: bool,
) -> Result<Json<Account>, StatusCode> {
    let (account, session) = authenticated(&state, &headers, &Identity::default()).await?;
    limit(
        &state,
        peer,
        "reauth",
        &account.user_id,
        Some(&session.device_id),
    )
    .await?;
    verify_pin(&account, &req.current_pin).await?;
    let new_pin = if change {
        let pin = req.new_pin.ok_or(StatusCode::BAD_REQUEST)?;
        if !(4..=12).contains(&pin.len()) || !pin.bytes().all(|b| b.is_ascii_digit()) {
            return Err(StatusCode::BAD_REQUEST);
        }
        Some(
            tokio::task::spawn_blocking(move || crate::pin::hash(&pin))
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
        )
    } else {
        None
    };
    let current_device = devices(&state, &account.user_id)
        .await?
        .into_iter()
        .find(|d| d.device_id == session.device_id);
    let credentials = Credentials {
        username: None,
        pin: None,
        display_name: None,
        sync_token: None,
        device_id: Some(session.device_id.clone()),
        device_name: current_device.as_ref().map(|d| d.device_name.clone()),
        platform: current_device.map(|d| d.platform),
    };
    Ok(Json(
        issue(&state, account, &credentials, Some(&session), true, new_pin).await?,
    ))
}
pub async fn rotate_token(
    State(state): State<AppState>,
    peer: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    Json(req): Json<Reauthenticate>,
) -> Result<Json<Account>, StatusCode> {
    replace_token(state, peer, headers, req, false).await
}
pub async fn change_pin(
    State(state): State<AppState>,
    peer: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    Json(req): Json<Reauthenticate>,
) -> Result<Json<Account>, StatusCode> {
    replace_token(state, peer, headers, req, true).await
}
pub async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(identity): Query<Identity>,
) -> Result<StatusCode, StatusCode> {
    let (account, source) = authenticated(&state, &headers, &identity).await?;
    if let Some(pool) = &state.pool {
        let mut tx = pool.begin().await.map_err(db_error)?;
        sqlx::query("SELECT user_id FROM user_accounts WHERE user_id=$1 FOR UPDATE")
            .bind(&account.user_id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        let valid:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM auth_sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>clock_timestamp())").bind(&source.token_hash).fetch_one(&mut *tx).await.map_err(db_error)?;
        if !valid {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let deleted = sqlx::query("DELETE FROM user_devices WHERE user_id=$1 AND device_id=$2")
            .bind(&account.user_id)
            .bind(&id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        if deleted.rows_affected() == 0 {
            return Err(StatusCode::NOT_FOUND);
        }
        tx.commit().await.map_err(db_error)?;
    } else {
        let mut store = state.auth_sessions.write().await;
        if !store
            .sessions
            .get(&source.token_hash)
            .is_some_and(|s| s.revoked_at.is_none() && s.expires_at > Utc::now())
        {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let mut all = state.accounts.write().await;
        let a = all
            .get_mut(&account.username)
            .ok_or(StatusCode::UNAUTHORIZED)?;
        if !a.devices.iter().any(|d| d.device_id == id) {
            return Err(StatusCode::NOT_FOUND);
        }
        a.devices.retain(|d| d.device_id != id);
        for s in store
            .sessions
            .values_mut()
            .filter(|s| s.user_id == account.user_id && s.device_id == id)
        {
            s.revoked_at = Some(Utc::now());
        }
        a.sync_token.clear();
    }
    Ok(StatusCode::NO_CONTENT)
}
pub async fn list_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(id): Query<Identity>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let user = resolve(&state, &headers, &id).await?;
    if user == DEFAULT_USER {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(
        serde_json::json!({"devices":devices(&state,&user).await?}),
    ))
}
pub async fn seen_device(
    state: &AppState,
    user: &str,
    id: Option<&str>,
    seq: i64,
) -> Result<(), StatusCode> {
    let Some(id) = id else { return Ok(()) };
    if let Some(p) = &state.pool {
        sqlx::query("UPDATE user_devices SET last_seen_at=clock_timestamp(),last_sync_seq=GREATEST(last_sync_seq,$3) WHERE user_id=$1 AND device_id=$2").bind(user).bind(id).bind(seq).execute(p).await.map_err(db_error)?;
    } else {
        for a in state.accounts.write().await.values_mut() {
            if a.user_id == user {
                if let Some(d) = a.devices.iter_mut().find(|d| d.device_id == id) {
                    d.last_seen_at = Utc::now();
                    d.last_sync_seq = d.last_sync_seq.max(seq);
                }
            }
        }
    }
    Ok(())
}
