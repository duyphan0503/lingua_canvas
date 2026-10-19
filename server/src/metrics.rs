use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use axum::{
    body::Body,
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
};

const ROUTES: [&str; 8] = [
    "health",
    "curriculum",
    "auth",
    "review",
    "sync",
    "ai",
    "metrics",
    "other",
];
const STATUSES: [&str; 5] = ["1xx", "2xx", "3xx", "4xx", "5xx"];
const BUCKET_MS: [u64; 6] = [10, 50, 100, 500, 1000, 5000];

static REQUESTS: [AtomicU64; 40] = [const { AtomicU64::new(0) }; 40];
static DURATION_BUCKETS: [AtomicU64; 56] = [const { AtomicU64::new(0) }; 56];
static DURATION_COUNT: [AtomicU64; 8] = [const { AtomicU64::new(0) }; 8];
static DURATION_NANOS: [AtomicU64; 8] = [const { AtomicU64::new(0) }; 8];
static CACHE_OUTCOMES: [AtomicU64; 3] = [const { AtomicU64::new(0) }; 3];
static AI_OUTCOMES: [AtomicU64; 3] = [const { AtomicU64::new(0) }; 3];

pub enum CacheOutcome {
    RedisOk,
    MemoryFallback,
    RedisError,
}

pub enum AiOutcome {
    Provider,
    CuratedFallback,
    Error,
}

pub fn record_cache_outcome(outcome: CacheOutcome) {
    let index = match outcome {
        CacheOutcome::RedisOk => 0,
        CacheOutcome::MemoryFallback => 1,
        CacheOutcome::RedisError => 2,
    };
    CACHE_OUTCOMES[index].fetch_add(1, Ordering::Relaxed);
}

pub fn record_ai_outcome(outcome: AiOutcome) {
    let index = match outcome {
        AiOutcome::Provider => 0,
        AiOutcome::CuratedFallback => 1,
        AiOutcome::Error => 2,
    };
    AI_OUTCOMES[index].fetch_add(1, Ordering::Relaxed);
}

pub async fn record_request(request: Request<Body>, next: Next) -> Response {
    let route = route_index(request.uri().path());
    let started = Instant::now();
    let response = next.run(request).await;
    let status = usize::from(response.status().as_u16() / 100)
        .saturating_sub(1)
        .min(STATUSES.len() - 1);
    REQUESTS[route * STATUSES.len() + status].fetch_add(1, Ordering::Relaxed);

    let elapsed = started.elapsed();
    let elapsed_ms = elapsed.as_millis().min(u128::from(u64::MAX)) as u64;
    for (index, boundary) in BUCKET_MS.iter().enumerate() {
        if elapsed_ms <= *boundary {
            DURATION_BUCKETS[route * (BUCKET_MS.len() + 1) + index].fetch_add(1, Ordering::Relaxed);
        }
    }
    DURATION_BUCKETS[route * (BUCKET_MS.len() + 1) + BUCKET_MS.len()]
        .fetch_add(1, Ordering::Relaxed);
    DURATION_COUNT[route].fetch_add(1, Ordering::Relaxed);
    DURATION_NANOS[route].fetch_add(
        elapsed.as_nanos().min(u128::from(u64::MAX)) as u64,
        Ordering::Relaxed,
    );
    response
}

fn route_index(path: &str) -> usize {
    if path == "/metrics" {
        6
    } else if path == "/api/v1/health" {
        0
    } else if path.starts_with("/api/v1/lessons") {
        1
    } else if path.starts_with("/api/v1/auth/") {
        2
    } else if path.starts_with("/api/v1/fsrs/") {
        3
    } else if path.starts_with("/api/v1/sync") {
        4
    } else if path.starts_with("/api/v1/ai/") {
        5
    } else {
        7
    }
}

pub async fn prometheus() -> Response {
    let mut body = String::from(
        "# HELP lingua_http_requests_total HTTP requests by bounded route and status class.\n# TYPE lingua_http_requests_total counter\n",
    );
    for (route_index, route) in ROUTES.iter().enumerate() {
        for (status_index, status) in STATUSES.iter().enumerate() {
            let count =
                REQUESTS[route_index * STATUSES.len() + status_index].load(Ordering::Relaxed);
            if count != 0 {
                body.push_str(&format!(
                    "lingua_http_requests_total{{route=\"{route}\",status_class=\"{status}\"}} {count}\n"
                ));
            }
        }
    }

    body.push_str(
        "# HELP lingua_http_request_duration_seconds HTTP request duration.\n# TYPE lingua_http_request_duration_seconds histogram\n",
    );
    for (route_index, route) in ROUTES.iter().enumerate() {
        for (bucket_index, boundary) in BUCKET_MS.iter().enumerate() {
            let count = DURATION_BUCKETS[route_index * (BUCKET_MS.len() + 1) + bucket_index]
                .load(Ordering::Relaxed);
            body.push_str(&format!(
                "lingua_http_request_duration_seconds_bucket{{route=\"{route}\",le=\"{}\"}} {count}\n",
                *boundary as f64 / 1000.0
            ));
        }
        let count = DURATION_BUCKETS[route_index * (BUCKET_MS.len() + 1) + BUCKET_MS.len()]
            .load(Ordering::Relaxed);
        body.push_str(&format!(
            "lingua_http_request_duration_seconds_bucket{{route=\"{route}\",le=\"+Inf\"}} {count}\n"
        ));
        let total_count = DURATION_COUNT[route_index].load(Ordering::Relaxed);
        let total_seconds =
            DURATION_NANOS[route_index].load(Ordering::Relaxed) as f64 / 1_000_000_000.0;
        body.push_str(&format!(
            "lingua_http_request_duration_seconds_sum{{route=\"{route}\"}} {total_seconds}\nlingua_http_request_duration_seconds_count{{route=\"{route}\"}} {total_count}\n"
        ));
    }

    body.push_str(
        "# HELP lingua_cache_operations_total Cache command outcomes.\n# TYPE lingua_cache_operations_total counter\n",
    );
    for (index, outcome) in ["redis_ok", "memory_fallback", "redis_error"]
        .iter()
        .enumerate()
    {
        let count = CACHE_OUTCOMES[index].load(Ordering::Relaxed);
        body.push_str(&format!(
            "lingua_cache_operations_total{{outcome=\"{outcome}\"}} {count}\n"
        ));
    }
    body.push_str(
        "# HELP lingua_ai_completions_total AI provider and fallback outcomes.\n# TYPE lingua_ai_completions_total counter\n",
    );
    for (index, outcome) in ["provider", "curated_fallback", "error"].iter().enumerate() {
        let count = AI_OUTCOMES[index].load(Ordering::Relaxed);
        body.push_str(&format!(
            "lingua_ai_completions_total{{outcome=\"{outcome}\"}} {count}\n"
        ));
    }

    (
        StatusCode::OK,
        [(
            axum::http::header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
        .into_response()
}
