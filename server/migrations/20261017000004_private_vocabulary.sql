-- Private metadata is never stored in the public lessons table, including its FK placeholders.
CREATE TABLE private_lessons (
 user_id VARCHAR(64) NOT NULL REFERENCES user_accounts(user_id),
 lesson_id VARCHAR(64) NOT NULL,
 lesson JSONB NOT NULL,
 revision BIGINT NOT NULL CHECK (revision >= 1),
 deleted BOOLEAN NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq'),
 PRIMARY KEY(user_id,lesson_id),
 CHECK(user_id <> 'default_user')
);
CREATE INDEX idx_private_lessons_user_seq ON private_lessons(user_id,sync_seq);
-- Receipt and entity changes commit in the same transaction. Names share one account namespace.
CREATE TABLE private_sync_receipts (
 user_id VARCHAR(64) NOT NULL REFERENCES user_accounts(user_id),
 mutation_id VARCHAR(128) NOT NULL,
 payload JSONB NOT NULL,
 result JSONB NOT NULL,
 PRIMARY KEY(user_id,mutation_id),
 CHECK(user_id <> 'default_user')
);
