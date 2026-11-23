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

-- M5:memory 工具沉淀的个人记忆
CREATE TABLE IF NOT EXISTS memory_note (
  id         TEXT PRIMARY KEY,
  content    TEXT NOT NULL,
  tags       TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_note_updated ON memory_note(updated_at);

-- M7:手机原生提醒。conversation_id 用 SET NULL:提醒是用户显式产物,
-- 删会话/临时会话被清扫都不该让一个已经答应过的闹钟消失。
CREATE TABLE IF NOT EXISTS reminder (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT REFERENCES conversation(id) ON DELETE SET NULL,
  text            TEXT NOT NULL,
  fire_at         TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','scheduled','fired','cancelled')),
  native_alarm_id TEXT,
  created_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reminder_status ON reminder(status, fire_at);

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

-- M2:上传到 DeepSeek Files API 的文档。原件与解析结果都不在本地留档(官方不支持下载),
-- 只记引用关系与状态,对话里用 file_id 回指。
CREATE TABLE IF NOT EXISTS file (
  id               TEXT PRIMARY KEY,
  conversation_id  TEXT REFERENCES conversation(id) ON DELETE SET NULL,
  name             TEXT NOT NULL,
  mime             TEXT NOT NULL,
  size             INTEGER NOT NULL DEFAULT 0,
  purpose          TEXT NOT NULL,
  provider_file_id TEXT NOT NULL,
  parse_status     TEXT NOT NULL DEFAULT 'parsed',
  created_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_file_conversation ON file(conversation_id);

-- M3:dsh 远程开发桥。事件表只存结构化事件(输出/思考增量太碎,只留在内存环形缓冲)
CREATE TABLE IF NOT EXISTS harness_node (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  platform  TEXT NOT NULL,
  status    TEXT NOT NULL DEFAULT 'offline',
  last_seen TEXT
);
CREATE TABLE IF NOT EXISTS harness_task (
  id         TEXT PRIMARY KEY,
  node_id    TEXT NOT NULL,
  workspace  TEXT,
  prompt     TEXT NOT NULL,
  status     TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS harness_event (
  id           TEXT PRIMARY KEY,
  task_id      TEXT NOT NULL REFERENCES harness_task(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  ts           TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_harness_event_task ON harness_event(task_id);

-- M3.5:会话级流(手机与电脑共用同一个会话)。seq 是服务器本地游标,手机按它续传;
-- dsh_seq 是 dsh 会话事件序号,用于插件重连补发时去重(瞬时事件为 NULL)。
CREATE TABLE IF NOT EXISTS harness_stream_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  dsh_seq      INTEGER,
  kind         TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  ts           TEXT NOT NULL,
  UNIQUE (session_id, seq)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_stream_session_dsh
  ON harness_stream_event(session_id, dsh_seq) WHERE dsh_seq IS NOT NULL;

-- v1.5.3:用户设置。目前只有个人 DeepSeek key(deepseek_api_key):
-- value 只存服务端,任何接口只回尾号,绝不进日志或客户端。
CREATE TABLE IF NOT EXISTS app_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- v1.9.0:邮箱账号(单人;仅允许一个账号)。密码只存 scrypt 哈希。
CREATE TABLE IF NOT EXISTS user_account (
  id             TEXT PRIMARY KEY,
  email          TEXT NOT NULL UNIQUE,
  password_hash  TEXT NOT NULL,
  email_verified INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL
);

-- v1.9.0:邮箱验证码(激活/重置密码)。只存哈希,明文只走邮件;一次性、限时。
CREATE TABLE IF NOT EXISTS auth_token (
  id         TEXT PRIMARY KEY,
  email      TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('verify','reset')),
  code_hash  TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at    TEXT
);
`;

/** 给既有库补列(SQLite 没有 ADD COLUMN IF NOT EXISTS)。 */
function ensureColumn(db: Database.Database, table: string, column: string, ddl: string): void {
  const columns = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>;
  if (columns.some((entry) => entry.name === column)) return;
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
}

export function openDb(dbPath: string): Db {
  if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  // M2 新增:assistant 的 server_tool_calls 原始块(含阅读链接的 signature),供下轮回传
  ensureColumn(db, 'message', 'server_blocks_json', "server_blocks_json TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, 'message', 'tool_blocks_json', "tool_blocks_json TEXT NOT NULL DEFAULT '[]'");
  // 拒答标识:{"source":"input"|"output","reason":"…"},NULL 表示没命中安全策略
  ensureColumn(db, 'message', 'safety_json', 'safety_json TEXT');
  // 设备吊销时间(非空即已吊销,token_hash 同时被换成不可能命中的值)
  ensureColumn(db, 'device', 'revoked_at', 'revoked_at TEXT');
  return db;
}

export const nowIso = (): string => new Date().toISOString();

/** 临时会话既不在列表默认查询中出现,也要在启动/每日清扫时删除。 */
export function purgeEphemeral(db: Db): number {
  const result = db.prepare('DELETE FROM conversation WHERE ephemeral = 1').run();
  return result.changes;
}
