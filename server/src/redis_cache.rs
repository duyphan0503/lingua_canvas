use crate::metrics::{self, CacheOutcome};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpStream,
    sync::Mutex,
    time::timeout,
};
enum Reply {
    Text(String),
    Integer(i64),
    Nil,
}
const MAX_VALUE: usize = 1_048_576;
#[derive(Clone)]
pub struct RedisCache {
    address: Option<String>,
    connection: Arc<Mutex<Option<BufReader<TcpStream>>>>,
    memory: Arc<Mutex<HashMap<String, (String, Instant)>>>,
    counts: Arc<Mutex<HashMap<String, (u32, Instant)>>>,
}
impl Default for RedisCache {
    fn default() -> Self {
        Self::new(std::env::var("REDIS_URL").ok().as_deref())
    }
}
impl RedisCache {
    pub fn new(url: Option<&str>) -> Self {
        let address = url
            .and_then(|s| s.strip_prefix("redis://"))
            .map(|s| s.trim_end_matches('/'))
            .filter(|s| !s.is_empty() && !s.contains(['@', '/', '?', '#']))
            .map(|s| {
                if s.contains(':') {
                    s.to_owned()
                } else {
                    format!("{s}:6379")
                }
            });
        Self {
            address,
            connection: Default::default(),
            memory: Default::default(),
            counts: Default::default(),
        }
    }
    async fn command(&self, args: &[&str]) -> Option<Reply> {
        let Some(address) = self.address.as_ref() else {
            metrics::record_cache_outcome(CacheOutcome::MemoryFallback);
            return None;
        };
        let result = timeout(Duration::from_millis(300), async {
            // The single connection serializes complete request/reply pairs across clones.
            // Take it out of the slot so errors, timeouts, and caller cancellation drop
            // the socket instead of returning a potentially partial reply to the pool.
            let mut connection = self.connection.lock().await;
            let mut stream = match connection.take() {
                Some(stream) => stream,
                None => BufReader::new(TcpStream::connect(address).await.ok()?),
            };
            let mut command = format!("*{}\r\n", args.len()).into_bytes();
            for arg in args {
                command.extend_from_slice(format!("${}\r\n", arg.len()).as_bytes());
                command.extend_from_slice(arg.as_bytes());
                command.extend_from_slice(b"\r\n");
            }
            stream.write_all(&command).await.ok()?;
            let reply = async {
                let kind = stream.read_u8().await.ok()?;
                let mut line = Vec::new();
                loop {
                    let byte = stream.read_u8().await.ok()?;
                    line.push(byte);
                    if line.len() > 128 {
                        return None;
                    }
                    if line.ends_with(b"\r\n") {
                        break;
                    }
                }
                let text = std::str::from_utf8(&line[..line.len() - 2]).ok()?;
                match kind {
                    b'+' => Some(Reply::Text(text.to_owned())),
                    b':' => text.parse().ok().map(Reply::Integer),
                    b'$' => {
                        let len: i64 = text.parse().ok()?;
                        if len == -1 {
                            return Some(Reply::Nil);
                        }
                        if !(0..=MAX_VALUE as i64).contains(&len) {
                            return None;
                        }
                        let mut body = vec![0; len as usize + 2];
                        stream.read_exact(&mut body).await.ok()?;
                        if !body.ends_with(b"\r\n") {
                            return None;
                        }
                        body.truncate(len as usize);
                        String::from_utf8(body).ok().map(Reply::Text)
                    }
                    _ => None,
                }
            }
            .await;
            // Never retry a command after writing: EVAL may already have incremented
            // the remote counter even when its reply was lost.
            // We never pipeline, so extra buffered bytes are an unsolicited reply.
            if reply.is_some() && stream.buffer().is_empty() {
                *connection = Some(stream);
            }
            reply
        })
        .await;
        match result {
            Ok(Some(reply)) => {
                metrics::record_cache_outcome(CacheOutcome::RedisOk);
                Some(reply)
            }
            Ok(None) | Err(_) => {
                metrics::record_cache_outcome(CacheOutcome::RedisError);
                None
            }
        }
    }
    pub async fn get(&self, key: &str) -> Option<String> {
        if key.len() > 8192 {
            return None;
        }
        if let Some(reply) = self.command(&["GET", key]).await {
            match reply {
                Reply::Text(value) => return Some(value),
                Reply::Nil => {
                    self.memory.lock().await.remove(key);
                    return None;
                }
                _ => {}
            }
        }
        let mut memory = self.memory.lock().await;
        if memory
            .get(key)
            .is_some_and(|(_, expiry)| *expiry <= Instant::now())
        {
            memory.remove(key);
        }
        memory.get(key).map(|(value, _)| value.clone())
    }
    pub async fn set_ex(&self, key: &str, value: &str, ttl: u64) {
        if value.len() > MAX_VALUE || key.len() > 8192 || ttl == 0 {
            return;
        }
        {
            let mut memory = self.memory.lock().await;
            memory.retain(|_, (_, expiry)| *expiry > Instant::now());
            if memory.len() >= 4096 {
                if let Some(old) = memory.keys().next().cloned() {
                    memory.remove(&old);
                }
            }
            memory.insert(
                key.into(),
                (
                    value.into(),
                    Instant::now() + Duration::from_secs(ttl.min(86400)),
                ),
            );
        }
        self.command(&["SETEX", key, &ttl.to_string(), value]).await;
    }
    pub async fn check_rate_limit(&self, key: &str, max: u32, window: u64) -> bool {
        let local = {
            let mut counts = self.counts.lock().await;
            counts.retain(|_, (_, expiry)| *expiry > Instant::now());
            if counts.len() >= 8192 && !counts.contains_key(key) {
                return false;
            }
            let entry = counts
                .entry(key.into())
                .or_insert((0, Instant::now() + Duration::from_secs(window.max(1))));
            entry.0 = entry.0.saturating_add(1);
            entry.0 <= max
        };
        // One atomic command avoids immortal counters if the connection drops between INCR and EXPIRE.
        match self.command(&["EVAL","local n=redis.call('INCR',KEYS[1]); if n==1 then redis.call('EXPIRE',KEYS[1],ARGV[1]) end; return n","1",&format!("rate:{key}"),&window.max(1).to_string()]).await {Some(Reply::Integer(n))=>local&&n<=max as i64,_=>local}
    }
    pub async fn ping(&self) -> bool {
        matches!(self.command(&["PING"]).await,Some(Reply::Text(s)) if s=="PONG")
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn fallback_ttl_and_limiter() {
        let c = RedisCache::new(Some("redis://127.0.0.1:9"));
        c.set_ex("key", "value", 1).await;
        assert_eq!(c.get("key").await.as_deref(), Some("value"));
        tokio::time::sleep(Duration::from_millis(1050)).await;
        assert!(c.get("key").await.is_none());
        assert!(c.check_rate_limit("u", 1, 1).await);
        assert!(!c.check_rate_limit("u", 1, 1).await);
        assert!(c.check_rate_limit("v", 1, 1).await);
    }
    #[tokio::test]
    async fn live_redis_round_trip_rate_and_ttl() {
        let Ok(url) = std::env::var("TEST_REDIS_URL") else {
            return;
        };
        let c = RedisCache::new(Some(&url));
        assert!(c.ping().await);
        let key = format!("utf8:{}", chrono::Utc::now().timestamp_micros());
        c.set_ex(&key, "会議\r\n$0\r\n", 1).await;
        // A separate client has no fallback entries, so this proves a RESP round trip.
        let other = RedisCache::new(Some(&url));
        assert_eq!(other.get(&key).await.as_deref(), Some("会議\r\n$0\r\n"));
        assert!(c.check_rate_limit(&key, 1, 1).await);
        assert!(!other.check_rate_limit(&key, 1, 1).await);
        tokio::time::sleep(Duration::from_millis(1100)).await;
        assert!(other.get(&key).await.is_none());
        assert!(other.check_rate_limit(&key, 1, 1).await);
    }
    #[tokio::test]
    async fn live_malformed_and_stalled_responses_are_bounded() {
        if std::env::var("TEST_REDIS_URL").is_err() {
            return;
        }
        for payload in [
            b"$9223372036854775807\r\n".as_slice(),
            b"$4\r\nbad!XX",
            b"+unterminated",
        ] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let payload = payload.to_vec();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                assert_eq!(socket.read_u8().await.unwrap(), b'*');
                socket.write_all(&payload).await.unwrap();
                tokio::time::sleep(Duration::from_secs(2)).await;
            });
            let c = RedisCache::new(Some(&format!("redis://{address}")));
            let started = Instant::now();
            assert!(c.get("x").await.is_none());
            assert!(started.elapsed() < Duration::from_millis(600));
            server.abort();
        }
    }
}
