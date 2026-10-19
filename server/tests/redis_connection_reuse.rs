use server::redis_cache::RedisCache;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

async fn request(socket: &mut BufReader<TcpStream>) -> Option<Vec<String>> {
    let mut line = String::new();
    socket.read_line(&mut line).await.ok()?;
    let count: usize = line.strip_prefix('*')?.trim().parse().ok()?;
    let mut args = Vec::new();
    for _ in 0..count {
        line.clear();
        socket.read_line(&mut line).await.ok()?;
        let len: usize = line.strip_prefix('$')?.trim().parse().ok()?;
        let mut bytes = vec![0; len + 2];
        socket.read_exact(&mut bytes).await.ok()?;
        if !bytes.ends_with(b"\r\n") {
            return None;
        }
        bytes.truncate(len);
        args.push(String::from_utf8(bytes).ok()?);
    }
    Some(args)
}

struct Fake {
    cache: RedisCache,
    connections: Arc<AtomicUsize>,
    commands: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fake {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fake {
    async fn start(mode: &'static str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let cache = RedisCache::new(Some(&format!("redis://{}", listener.local_addr().unwrap())));
        let connections = Arc::new(AtomicUsize::new(0));
        let commands = Arc::new(Mutex::new(Vec::new()));
        let count = connections.clone();
        let seen = commands.clone();
        let task = tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let number = count.fetch_add(1, Ordering::SeqCst);
                let seen = seen.clone();
                clients.spawn(async move {
                    let mut socket = BufReader::new(socket);
                    while let Some(args) = request(&mut socket).await {
                        seen.lock().await.push(args[0].clone());
                        if mode == "stall" && args[0] == "GET" {
                            tokio::time::sleep(Duration::from_secs(2)).await;
                        }
                        let response = match args[0].as_str() {
                            "GET" => format!("${}\r\n{}\r\n", args[1].len(), args[1]),
                            "SETEX" => "+OK\r\n".to_owned(),
                            "EVAL" => ":1\r\n".to_owned(),
                            "PING" => "+PONG\r\n".to_owned(),
                            _ => panic!("unexpected command: {args:?}"),
                        };
                        if number == 0 && mode == "extra" {
                            let _ = socket.write_all(b"+OK\r\n+POISON\r\n").await;
                        } else if number == 0 && mode == "dirty" {
                            let _ = socket.write_all(b"$4\r\nbad!XX+POISON\r\n").await;
                        } else if socket.write_all(response.as_bytes()).await.is_err() {
                            break;
                        }
                        if number == 0 && mode == "close" {
                            break;
                        }
                    }
                });
            }
        });
        Self {
            cache,
            connections,
            commands,
            task,
        }
    }
}

#[tokio::test]
async fn reuses_one_connection_for_get_setex_eval_and_ping() {
    let fake = Fake::start("normal").await;
    fake.cache.set_ex("stored", "fallback", 10).await;
    assert_eq!(fake.cache.get("remote").await.as_deref(), Some("remote"));
    assert!(fake.cache.check_rate_limit("user", 1, 10).await);
    assert!(!fake.cache.check_rate_limit("user", 1, 10).await);
    assert!(fake.cache.ping().await);
    assert_eq!(
        *fake.commands.lock().await,
        ["SETEX", "GET", "EVAL", "EVAL", "PING"]
    );
    assert_eq!(fake.connections.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn concurrent_clones_keep_requests_and_replies_together() {
    let fake = Fake::start("normal").await;
    let mut calls = tokio::task::JoinSet::new();
    for number in 0..32 {
        let cache = fake.cache.clone();
        calls.spawn(async move {
            let key = format!("request-{number}");
            assert_eq!(cache.get(&key).await, Some(key));
        });
    }
    while let Some(result) = calls.join_next().await {
        result.unwrap();
    }
    assert_eq!(fake.connections.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn stale_socket_is_discarded_without_replaying_mutation() {
    let fake = Fake::start("close").await;
    assert!(fake.cache.ping().await);
    tokio::task::yield_now().await;
    assert!(fake.cache.check_rate_limit("user", 1, 10).await);
    assert!(fake.cache.ping().await);
    assert_eq!(*fake.commands.lock().await, ["PING", "PING"]);
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn malformed_reply_discards_connection_and_unread_bytes() {
    let fake = Fake::start("dirty").await;
    fake.cache.set_ex("stored", "fallback", 10).await;
    assert_eq!(fake.cache.get("stored").await.as_deref(), Some("stored"));
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn deadline_includes_waiting_for_connection_and_discards_timed_out_reply() {
    let fake = Fake::start("stall").await;
    let cache = fake.cache.clone();
    let started = Instant::now();
    let first = tokio::spawn(async move { cache.get("first").await });
    while fake.commands.lock().await.is_empty() {
        tokio::task::yield_now().await;
    }
    let second_started = Instant::now();
    assert!(fake.cache.get("second").await.is_none());
    assert!(second_started.elapsed() < Duration::from_millis(550));
    assert!(first.await.unwrap().is_none());
    assert!(started.elapsed() < Duration::from_millis(600));
    assert!(fake.cache.ping().await);
    assert!(fake.connections.load(Ordering::SeqCst) >= 2);
}

#[tokio::test]
async fn unsolicited_bytes_after_valid_reply_are_not_reused() {
    let fake = Fake::start("extra").await;
    fake.cache.set_ex("stored", "fallback", 10).await;
    assert_eq!(fake.cache.get("stored").await.as_deref(), Some("stored"));
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn ambiguous_eval_reply_is_not_retried() {
    let fake = Fake::start("dirty").await;
    assert!(fake.cache.check_rate_limit("user", 1, 10).await);
    assert!(fake.cache.ping().await);
    assert_eq!(*fake.commands.lock().await, ["EVAL", "PING"]);
    assert!(!fake.cache.check_rate_limit("user", 1, 10).await);
}

#[tokio::test]
async fn cancelled_request_drops_its_socket() {
    let fake = Fake::start("stall").await;
    let cache = fake.cache.clone();
    let call = tokio::spawn(async move { cache.get("cancelled").await });
    while fake.commands.lock().await.is_empty() {
        tokio::task::yield_now().await;
    }
    call.abort();
    assert!(call.await.unwrap_err().is_cancelled());
    assert!(fake.cache.ping().await);
    assert_eq!(*fake.commands.lock().await, ["GET", "PING"]);
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}
