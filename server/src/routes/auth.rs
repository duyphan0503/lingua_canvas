use super::AppState;
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
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
            .is_some_and(|s| s.is_empty() || s.len() > 64 || s.contains('\0'))
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
async fn find(
    state: &AppState,
    value: &str,
    by_token: bool,
) -> Result<Option<Account>, StatusCode> {
    if value.is_empty() {
        return Ok(None);
    }
    if let Some(pool) = &state.pool {
        sqlx::query_as::<_,Account>(if by_token {"SELECT user_id,username,display_name,pin_hash,sync_token FROM user_accounts WHERE sync_token=$1 AND user_id <> 'default_user'"}else{"SELECT user_id,username,display_name,pin_hash,sync_token FROM user_accounts WHERE username=$1 AND user_id <> 'default_user'"}).bind(value).fetch_optional(pool).await.map_err(db_error)
    } else {
        Ok(state
            .accounts
            .read()
            .await
            .values()
            .find(|a| {
                if by_token {
                    a.sync_token == value
                } else {
                    a.username == value
                }
            })
            .cloned())
    }
}
pub async fn resolve(
    state: &AppState,
    headers: &HeaderMap,
    identity: &Identity,
) -> Result<String, StatusCode> {
    let mut credentials = Vec::new();
    for v in headers.get_all("x-sync-token") {
        credentials.push(v.to_str().map_err(|_| StatusCode::UNAUTHORIZED)?.to_owned());
    }
    for v in headers.get_all("authorization") {
        let v = v.to_str().map_err(|_| StatusCode::UNAUTHORIZED)?;
        credentials.push(
            v.strip_prefix("Bearer ")
                .ok_or(StatusCode::UNAUTHORIZED)?
                .to_owned(),
        );
    }
    if let Some(v) = &identity.sync_token {
        credentials.push(v.clone());
    }
    let user = if let Some(t) = credentials.first() {
        if credentials.iter().any(|v| v != t) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        find(state, t, true)
            .await?
            .ok_or(StatusCode::UNAUTHORIZED)?
            .user_id
    } else {
        DEFAULT_USER.to_owned()
    };
    if identity.user_id.as_ref().is_some_and(|u| u != &user) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(user)
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
async fn link(
    state: &AppState,
    mut account: Account,
    req: &Credentials,
) -> Result<Account, StatusCode> {
    if let Some(id) = &req.device_id {
        if id.is_empty() || id.len() > 64 {
            return Err(StatusCode::BAD_REQUEST);
        }
        let device = Device {
            device_id: id.clone(),
            device_name: req
                .device_name
                .clone()
                .unwrap_or_else(|| "Lingua Client".into()),
            platform: req.platform.clone().unwrap_or_else(|| "unknown".into()),
            last_sync_seq: 0,
            last_seen_at: Utc::now(),
        };
        if device.device_name.len() > 128 || device.platform.len() > 32 {
            return Err(StatusCode::BAD_REQUEST);
        }
        if let Some(p) = &state.pool {
            sqlx::query("INSERT INTO user_devices(user_id,device_id,device_name,platform) VALUES($1,$2,$3,$4) ON CONFLICT(user_id,device_id) DO UPDATE SET device_name=EXCLUDED.device_name,platform=EXCLUDED.platform,last_seen_at=clock_timestamp()").bind(&account.user_id).bind(id).bind(&device.device_name).bind(&device.platform).execute(p).await.map_err(db_error)?;
        } else {
            let mut all = state.accounts.write().await;
            let a = all
                .get_mut(&account.username)
                .ok_or(StatusCode::UNAUTHORIZED)?;
            if let Some(old) = a.devices.iter_mut().find(|d| d.device_id == *id) {
                old.device_name = device.device_name;
                old.platform = device.platform;
                old.last_seen_at = device.last_seen_at;
            } else {
                a.devices.push(device);
            }
        }
    }
    account.devices = devices(state, &account.user_id).await?;
    Ok(account)
}
pub async fn register(
    State(state): State<AppState>,
    Json(req): Json<Credentials>,
) -> Result<(StatusCode, Json<Account>), StatusCode> {
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
    if find(&state, &username, false).await?.is_some() {
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
        sync_token: token("lct_"),
        devices: vec![],
    };
    if let Some(p) = &state.pool {
        sqlx::query("INSERT INTO user_accounts(user_id,username,display_name,pin_hash,sync_token) VALUES($1,$2,$3,$4,$5)").bind(&account.user_id).bind(&username).bind(&account.display_name).bind(&account.pin_hash).bind(&account.sync_token).execute(p).await.map_err(|e|if e.as_database_error().is_some_and(|e|e.is_unique_violation()){StatusCode::CONFLICT}else{db_error(e)})?;
    } else {
        let mut all = state.accounts.write().await;
        if all.contains_key(&username) {
            return Err(StatusCode::CONFLICT);
        }
        all.insert(username, account.clone());
    }
    Ok((
        StatusCode::CREATED,
        Json(link(&state, account, &req).await?),
    ))
}
pub async fn login(
    State(state): State<AppState>,
    Json(req): Json<Credentials>,
) -> Result<Json<Account>, StatusCode> {
    req.validate_device()?;
    let account = if let Some(t) = &req.sync_token {
        find(&state, t, true)
            .await?
            .ok_or(StatusCode::UNAUTHORIZED)?
    } else {
        let username = req.username.as_deref().unwrap_or("").trim().to_lowercase();
        if !state
            .cache
            .check_rate_limit(&format!("auth:{username}"), 10, 60)
            .await
        {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        let account = find(&state, &username, false)
            .await?
            .ok_or(StatusCode::UNAUTHORIZED)?;
        let pin = req.pin.clone().unwrap_or_default();
        if pin.len() > 12 {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let stored = account.pin_hash.clone();
        if !tokio::task::spawn_blocking(move || crate::pin::verify(&pin, &stored))
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        {
            return Err(StatusCode::UNAUTHORIZED);
        }
        account
    };
    Ok(Json(link(&state, account, &req).await?))
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
