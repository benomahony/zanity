//! The SQL zanity's store runs: its schema, and the statements Store prepares, one per field.
//! Every statement is fixed text, so no file contents, environment or request data become SQL.

/// The version of `schema`, kept in the store's user_version. A store from before it is migrated
/// by running `migration` first, which drops what the schema now makes differently.
pub const schema_version = 2;

/// Version 2 keys source_analyses by analysis context and trims whole contexts, not rows.
pub const migration = "DROP TABLE IF EXISTS source_analyses;";

/// The tables the store keeps, created on first use; WAL lets several runs share them.
pub const schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA journal_size_limit = 67108864;
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
    \\CREATE TABLE IF NOT EXISTS embeddings (
    \\    model TEXT NOT NULL,
    \\    kind TEXT NOT NULL,
    \\    text_hash TEXT NOT NULL,
    \\    vector BLOB NOT NULL,
    \\    embedded_at TEXT NOT NULL,
    \\    PRIMARY KEY (model, kind, text_hash)
    \\);
    \\CREATE TABLE IF NOT EXISTS source_analyses (
    \\    analysis_hash TEXT PRIMARY KEY,
    \\    context_hash TEXT NOT NULL,
    \\    source_hash TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    language TEXT NOT NULL,
    \\    result TEXT NOT NULL CHECK (json_valid(result)),
    \\    created_at TEXT NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS source_analyses_context ON source_analyses (context_hash);
    \\CREATE TABLE IF NOT EXISTS analysis_contexts (
    \\    context_hash TEXT PRIMARY KEY,
    \\    used_at TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS run_analyses (
    \\    scope_hash TEXT PRIMARY KEY,
    \\    state_hash TEXT NOT NULL,
    \\    checked INTEGER NOT NULL,
    \\    created_at TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS run_findings (
    \\    scope_hash TEXT NOT NULL,
    \\    chunk INTEGER NOT NULL,
    \\    result TEXT NOT NULL CHECK (json_valid(result)),
    \\    PRIMARY KEY (scope_hash, chunk)
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
const find_vector = "SELECT vector FROM embeddings WHERE model = ?1 AND kind = ?2 AND text_hash = ?3";
const save_vector = "INSERT OR REPLACE INTO embeddings (model, kind, text_hash, vector, embedded_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const save_analysis = "INSERT OR REPLACE INTO source_analyses (analysis_hash, context_hash, source_hash, path, language, result, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";

const use_context = "INSERT OR REPLACE INTO analysis_contexts (context_hash, used_at) VALUES (?1, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
/// Keeps the ?1 most recently used analysis contexts and forgets the rest.
const trim_contexts = "DELETE FROM analysis_contexts WHERE context_hash NOT IN (SELECT context_hash FROM analysis_contexts ORDER BY used_at DESC LIMIT ?1)";
/// Deletes the analyses of every context the store no longer keeps.
const drop_unused_analyses = "DELETE FROM source_analyses WHERE context_hash NOT IN (SELECT context_hash FROM analysis_contexts)";
const find_run_analysis = "SELECT checked FROM run_analyses WHERE scope_hash = ?1 AND state_hash = ?2";
const list_run_findings = "SELECT result FROM run_findings WHERE scope_hash = ?1 ORDER BY chunk";
const save_run_analysis = "INSERT OR REPLACE INTO run_analyses (scope_hash, state_hash, checked, created_at) VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const clear_run_findings = "DELETE FROM run_findings WHERE scope_hash = ?1";
const save_run_findings = "INSERT INTO run_findings (scope_hash, chunk, result) VALUES (?1, ?2, ?3)";
/// Keeps the ?1 most recently saved runs and deletes the rest, with their findings.
const trim_run_analyses = "DELETE FROM run_analyses WHERE scope_hash NOT IN (SELECT scope_hash FROM run_analyses ORDER BY created_at DESC LIMIT ?1)";
const trim_run_findings = "DELETE FROM run_findings WHERE scope_hash NOT IN (SELECT scope_hash FROM run_analyses)";

/// Built-in SQL for each prepared statement owned by Store, with matching field names.
pub const statements = .{
    .find = find_answer,
    .insert_unit_if_missing = insert_unit_if_missing_sql,
    .upsert_answer_by_identity = upsert_answer_sql,
    .observation = save_observation,
    .run = save_run,
    .find_analysis = find_analysis,
    .save_analysis = save_analysis,
    .use_context = use_context,
    .trim_contexts = trim_contexts,
    .drop_unused_analyses = drop_unused_analyses,
    .find_run_analysis = find_run_analysis,
    .list_run_findings = list_run_findings,
    .save_run_analysis = save_run_analysis,
    .clear_run_findings = clear_run_findings,
    .save_run_findings = save_run_findings,
    .trim_run_analyses = trim_run_analyses,
    .trim_run_findings = trim_run_findings,
    .false_positive = save_false_positive,
    .save_label = save_label,
    .find_label = find_label,
    .list_observed = list_observed,
    .find_vector = find_vector,
    .save_vector = save_vector,
};
