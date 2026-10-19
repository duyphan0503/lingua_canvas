-- Credentials are individual revocable device sessions, never plaintext.
CREATE TABLE auth_sessions (
 token_hash CHAR(64) PRIMARY KEY,
 user_id VARCHAR(64) NOT NULL,
 device_id VARCHAR(64) NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 revoked_at TIMESTAMPTZ,
 FOREIGN KEY(user_id,device_id) REFERENCES user_devices(user_id,device_id) ON DELETE CASCADE
);
CREATE INDEX auth_sessions_user_device ON auth_sessions(user_id,device_id);
-- A seven-day one-time exchange window for old clients. Revoking this virtual
-- device removes the legacy credential too; there is no account-token fallback.
INSERT INTO user_devices(user_id,device_id,device_name,platform)
 SELECT user_id,'__legacy__','Legacy session (exchange within 7 days)','unknown'
 FROM user_accounts WHERE user_id <> 'default_user' AND sync_token <> ''
 ON CONFLICT DO NOTHING;
INSERT INTO auth_sessions(token_hash,user_id,device_id,expires_at)
 SELECT encode(sha256(convert_to(sync_token,'UTF8')),'hex'),user_id,'__legacy__',clock_timestamp()+interval '7 days'
 FROM user_accounts WHERE user_id <> 'default_user' AND sync_token <> '';
UPDATE user_accounts SET sync_token='retired_' || user_id WHERE user_id <> 'default_user';
