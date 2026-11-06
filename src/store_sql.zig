//! The SQL zanity's store runs: its schema, and the statements Store prepares, one per field.
//! Every statement is fixed text, so no file contents, environment or request data become SQL.

/// The tables the store keeps, created on first use; WAL lets several runs share them.
pub const schema =
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS units (
    \\    unit_hash TEXT PRIMARY KEY,
    \\    language TEXT NOT NULL,
    \\    source TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS answers (
    \\    model TEXT NOT NULL,
    \\    question_hash TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    probability REAL NOT NULL,
    \\    asked_at TEXT NOT NULL,
    \\    PRIMARY KEY (model, question_hash, unit_hash)
    \\);
    \\CREATE TABLE IF NOT EXISTS observations (
    \\    path TEXT NOT NULL,
    \\    rule TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    unit_name TEXT NOT NULL,
    \\    line INTEGER NOT NULL,
    \\    language TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    question_hash TEXT NOT NULL,
    \\    probability REAL NOT NULL,
    \\    threshold REAL NOT NULL,
    \\    fired INTEGER NOT NULL,
    \\    seen_at TEXT NOT NULL,
    \\    PRIMARY KEY (path, rule, unit_hash, line)
    \\);
    \\CREATE TABLE IF NOT EXISTS labels (
    \\    rule TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    real INTEGER NOT NULL,
    \\    labelled_at TEXT NOT NULL,
    \\    PRIMARY KEY (rule, unit_hash)
    \\);
    \\CREATE TABLE IF NOT EXISTS runs (
    \\    at TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    units INTEGER NOT NULL,
    \\    asked INTEGER NOT NULL,
    \\    cached INTEGER NOT NULL,
    \\    input_tokens INTEGER NOT NULL,
    \\    output_tokens INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS false_positives (
    \\    path TEXT NOT NULL,
    \\    line INTEGER NOT NULL,
    \\    column INTEGER NOT NULL,
    \\    rule TEXT NOT NULL,
    \\    message TEXT NOT NULL,
    \\    code TEXT NOT NULL,
    \\    version TEXT NOT NULL,
    \\    flagged_at TEXT NOT NULL,
    \\    PRIMARY KEY (path, rule, message, code)
    \\);
    \\CREATE TABLE IF NOT EXISTS source_analyses (
    \\    analysis_hash TEXT PRIMARY KEY,
    \\    source_hash TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    language TEXT NOT NULL,
    \\    result TEXT NOT NULL CHECK (json_valid(result)),
    \\    created_at TEXT NOT NULL,
    \\    used_at TEXT NOT NULL,
    \\    hits INTEGER NOT NULL DEFAULT 0
    \\);
;

const find_answer = "SELECT probability FROM answers WHERE model = ?1 AND question_hash = ?2 AND unit_hash = ?3";
const insert_unit_if_missing_sql = "INSERT OR IGNORE INTO units (unit_hash, language, source) VALUES (?1, ?2, ?3)";
const upsert_answer_sql = "INSERT OR REPLACE INTO answers (model, question_hash, unit_hash, probability, asked_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";

const save_observation = "INSERT OR REPLACE INTO observations (path, rule, unit_hash, unit_name, line, language, model, question_hash, probability, threshold, fired, seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const save_run = "INSERT INTO runs (at, path, units, asked, cached, input_tokens, output_tokens) VALUES (strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), ?1, ?2, ?3, ?4, ?5, ?6)";
const save_false_positive = "INSERT OR REPLACE INTO false_positives (path, line, column, rule, message, code, version, flagged_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const find_analysis = "SELECT result FROM source_analyses WHERE analysis_hash = ?1 AND source_hash = ?2";
const save_label = "INSERT OR REPLACE INTO labels (rule, unit_hash, real, labelled_at) VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const find_label = "SELECT real FROM labels WHERE rule = ?1 AND unit_hash = ?2";
/// Every answer kept, newest first, with its label when it has one; ?1 narrows it to one rule,
/// ?2 and ?3 to one path and line.
const list_observed = "SELECT o.rule, o.path, o.line, o.unit_hash, o.unit_name, o.probability, o.threshold, l.real FROM observations o LEFT JOIN labels l ON l.rule = o.rule AND l.unit_hash = o.unit_hash WHERE (?1 = '' OR o.rule = ?1) AND (?2 = '' OR o.path = ?2) AND (?3 = 0 OR o.line = ?3) ORDER BY o.seen_at DESC";
const touch_analysis = "UPDATE source_analyses SET used_at = strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), hits = hits + 1 WHERE analysis_hash = ?1";
const save_analysis = "INSERT OR REPLACE INTO source_analyses (analysis_hash, source_hash, path, language, result, created_at, used_at, hits) VALUES (?1, ?2, ?3, ?4, ?5, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), 0)";

/// Built-in SQL for each prepared statement owned by Store, with matching field names.
pub const statements = .{
    .find = find_answer,
    .insert_unit_if_missing = insert_unit_if_missing_sql,
    .upsert_answer_by_identity = upsert_answer_sql,
    .observation = save_observation,
    .run = save_run,
    .find_analysis = find_analysis,
    .touch_analysis = touch_analysis,
    .save_analysis = save_analysis,
    .false_positive = save_false_positive,
    .save_label = save_label,
    .find_label = find_label,
    .list_observed = list_observed,
};
