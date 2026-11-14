import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import Database from 'better-sqlite3';

export type Db = Database.Database;

/**
 * 建表迁移。分支模型:message.parent_id 构成消息树,
 * conversation.active_leaf_id 指向当前展示路径的叶子节点。
 * memory_note / harness_* 表分别留到 M5 / M3。
 */
const SCHEMA = `
CREATE TABLE IF NOT EXISTS device (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  paired_at   TEXT NOT NULL,
  last_seen   TEXT,
  token_hash  TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS conversation (
  id             TEXT PRIMARY KEY,
  title          TEXT NOT NULL DEFAULT '',
  pinned         INTEGER NOT NULL DEFAULT 0,
  ephemeral      INTEGER NOT NULL DEFAULT 0,
  active_leaf_id TEXT,
  settings_json  TEXT NOT NULL DEFAULT '{}',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS message (
  id               TEXT PRIMARY KEY,
  conversation_id  TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  parent_id        TEXT REFERENCES message(id) ON DELETE CASCADE,
  role             TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
  blocks_json      TEXT NOT NULL DEFAULT '[]',
  thinking         TEXT NOT NULL DEFAULT '',
  citations_json   TEXT NOT NULL DEFAULT '[]',
  tool_traces_json TEXT NOT NULL DEFAULT '[]',
  tokens_in        INTEGER NOT NULL DEFAULT 0,
  tokens_out       INTEGER NOT NULL DEFAULT 0,
  cost             REAL NOT NULL DEFAULT 0,
  stop_reason      TEXT,
  created_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_message_conversation ON message(conversation_id);
CREATE INDEX IF NOT EXISTS idx_message_parent ON message(parent_id);

-- tokens_in/tokens_out 是对 DESIGN §5.2 的小扩展:F9 需要按天统计 token,
-- 只在 usage_log.quantity 里放总 token 无法还原拆分。
CREATE TABLE IF NOT EXISTS usage_log (
  id              TEXT PRIMARY KEY,
  ts              TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('model','search','fetch','ocr','asr','tts')),
  quantity        REAL NOT NULL DEFAULT 0,
  cost            REAL NOT NULL DEFAULT 0,
  tokens_in       INTEGER NOT NULL DEFAULT 0,
  tokens_out      INTEGER NOT NULL DEFAULT 0,
  conversation_id TEXT,
  message_id      TEXT
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_log(ts);
`;

export function openDb(dbPath: string): Db {
  if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}

export const nowIso = (): string => new Date().toISOString();

/** 临时会话既不在列表默认查询中出现,也要在启动/每日清扫时删除。 */
export function purgeEphemeral(db: Db): number {
  const result = db.prepare('DELETE FROM conversation WHERE ephemeral = 1').run();
  return result.changes;
}
