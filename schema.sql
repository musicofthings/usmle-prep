-- ============================================================
-- USMLE Exam Prep · D1 Database Schema
-- Run with: wrangler d1 execute usmle-sessions --file schema.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT     PRIMARY KEY,
  step        TEXT     NOT NULL CHECK(step IN ('Step 1','Step 2 CK','Step 3')),
  difficulty  TEXT     NOT NULL CHECK(difficulty IN ('Easy','Medium','Hard','Mixed')),
  score       INTEGER  NOT NULL,
  total       INTEGER  NOT NULL,
  pct         REAL     GENERATED ALWAYS AS (ROUND(score * 100.0 / total, 1)) STORED,
  avg_time_s  INTEGER,
  created_at  TEXT     NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS question_attempts (
  id          INTEGER  PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT     NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  subject     TEXT     NOT NULL,
  q_type      TEXT,
  correct     INTEGER  NOT NULL CHECK(correct IN (0,1)),
  time_s      INTEGER,
  created_at  TEXT     NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS question_cache_meta (
  cache_key   TEXT     PRIMARY KEY,
  pool_size   INTEGER  NOT NULL DEFAULT 0,
  hits        INTEGER  NOT NULL DEFAULT 0,
  last_hit    TEXT,
  created_at  TEXT     NOT NULL DEFAULT (datetime('now'))
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_attempts_session   ON question_attempts(session_id);
CREATE INDEX IF NOT EXISTS idx_attempts_subject   ON question_attempts(subject);
CREATE INDEX IF NOT EXISTS idx_sessions_step      ON sessions(step);
CREATE INDEX IF NOT EXISTS idx_sessions_created   ON sessions(created_at);

-- Analytics views
CREATE VIEW IF NOT EXISTS v_step_stats AS
SELECT
  step,
  COUNT(*)                               AS sessions,
  ROUND(AVG(pct), 1)                     AS avg_pct,
  ROUND(AVG(avg_time_s), 0)             AS avg_time_s,
  SUM(score)                             AS total_correct,
  SUM(total)                             AS total_questions
FROM sessions
GROUP BY step;

CREATE VIEW IF NOT EXISTS v_subject_stats AS
SELECT
  a.subject,
  COUNT(*)                               AS attempts,
  SUM(a.correct)                         AS correct,
  ROUND(SUM(a.correct)*100.0/COUNT(*),1) AS pct_correct,
  ROUND(AVG(a.time_s), 0)               AS avg_time_s
FROM question_attempts a
GROUP BY a.subject
ORDER BY pct_correct ASC;
