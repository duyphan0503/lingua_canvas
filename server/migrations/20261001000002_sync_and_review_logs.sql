-- Migration 002: Add review logs, completed lessons, and sync metadata

CREATE TABLE IF NOT EXISTS review_logs (
    id VARCHAR(64) PRIMARY KEY,
    item_id VARCHAR(64) NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    client_id VARCHAR(64) NOT NULL DEFAULT 'default_device',
    rating SMALLINT NOT NULL,
    state SMALLINT NOT NULL,
    review_time TIMESTAMPTZ NOT NULL,
    elapsed_days DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    scheduled_days INTEGER NOT NULL DEFAULT 0,
    server_received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS completed_lessons (
    lesson_id VARCHAR(64) NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    client_id VARCHAR(64) NOT NULL DEFAULT 'default_device',
    completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    score DOUBLE PRECISION NOT NULL DEFAULT 1.0,
    PRIMARY KEY (lesson_id, client_id)
);

CREATE INDEX IF NOT EXISTS idx_review_logs_item_time ON review_logs(item_id, review_time DESC);
CREATE INDEX IF NOT EXISTS idx_review_logs_client ON review_logs(client_id);
CREATE INDEX IF NOT EXISTS idx_fsrs_cards_updated_at ON fsrs_cards(updated_at);
