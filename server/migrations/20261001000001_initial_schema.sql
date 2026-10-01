-- Schema for Lingua Canvas PostgreSQL database

CREATE TABLE IF NOT EXISTS lessons (
    id VARCHAR(64) PRIMARY KEY,
    language VARCHAR(10) NOT NULL,
    category VARCHAR(50) NOT NULL,
    target_text TEXT NOT NULL,
    phonetic_or_kana TEXT NOT NULL,
    meaning_vi TEXT NOT NULL,
    workplace_context TEXT NOT NULL,
    workplace_context_vi TEXT NOT NULL,
    stroke_order_hints JSONB NOT NULL DEFAULT '[]'::jsonb,
    difficulty_level SMALLINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS fsrs_cards (
    item_id VARCHAR(64) PRIMARY KEY REFERENCES lessons(id) ON DELETE CASCADE,
    state SMALLINT NOT NULL DEFAULT 0,
    stability DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    difficulty DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    reps INTEGER NOT NULL DEFAULT 0,
    lapses INTEGER NOT NULL DEFAULT 0,
    last_review TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    next_review TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lessons_language_category ON lessons(language, category);
CREATE INDEX IF NOT EXISTS idx_fsrs_cards_next_review ON fsrs_cards(next_review);
