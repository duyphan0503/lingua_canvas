CREATE TABLE user_accounts (
 user_id VARCHAR(64) PRIMARY KEY,
 username VARCHAR(64) UNIQUE NOT NULL,
 display_name TEXT NOT NULL DEFAULT '',
 pin_hash VARCHAR(128) NOT NULL,
 sync_token VARCHAR(128) UNIQUE NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- The legacy profile is public but cannot be logged in using a predictable token.
INSERT INTO user_accounts(user_id,username,display_name,pin_hash,sync_token)
VALUES('default_user','default','Default Learner','disabled','');
CREATE TABLE user_devices (
 user_id VARCHAR(64) NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
 device_id VARCHAR(64) NOT NULL,
 device_name TEXT NOT NULL DEFAULT 'Lingua Client',
 platform VARCHAR(32) NOT NULL DEFAULT 'unknown',
 last_sync_seq BIGINT NOT NULL DEFAULT 0,
 last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY(user_id,device_id)
);
CREATE SEQUENCE sync_change_seq;
ALTER TABLE lessons ADD COLUMN sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');
ALTER TABLE fsrs_cards ADD COLUMN user_id VARCHAR(64) NOT NULL DEFAULT 'default_user' REFERENCES user_accounts(user_id), ADD COLUMN sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');
ALTER TABLE fsrs_cards DROP CONSTRAINT fsrs_cards_pkey, ADD PRIMARY KEY(user_id,item_id);
ALTER TABLE review_logs ADD COLUMN user_id VARCHAR(64) NOT NULL DEFAULT 'default_user' REFERENCES user_accounts(user_id), ADD COLUMN sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');
ALTER TABLE review_logs DROP CONSTRAINT review_logs_pkey, ADD PRIMARY KEY(user_id,id);
ALTER TABLE completed_lessons ADD COLUMN user_id VARCHAR(64) NOT NULL DEFAULT 'default_user' REFERENCES user_accounts(user_id), ADD COLUMN sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq'), ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp();
ALTER TABLE completed_lessons DROP CONSTRAINT completed_lessons_pkey, ADD PRIMARY KEY(user_id,lesson_id,client_id);
CREATE INDEX idx_fsrs_cards_user_seq ON fsrs_cards(user_id,sync_seq);
CREATE INDEX idx_review_logs_user_seq ON review_logs(user_id,sync_seq);
CREATE INDEX idx_completed_lessons_user_seq ON completed_lessons(user_id,sync_seq);
CREATE INDEX idx_lessons_sync_seq ON lessons(sync_seq);
