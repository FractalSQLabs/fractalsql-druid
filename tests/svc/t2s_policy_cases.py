# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The text-to-SQL policy table: a statement, and what the documented rules say about it.

The statements are Druid SQL, which Calcite parses: "--" and "//" are line comments (no whitespace
needed after them), "#" is not a comment, a string is single-quoted with a quote doubled and a
backslash is an ordinary character, and a double-quoted token is an identifier.

The expected verdict of every case here comes from reading the rules in
service/adapter/src/fractalsql_textsql.c, not from running the code and
copying its answer. The rules, in the order the checker applies them:

  1. A versioned comment (``/*! ... */``) or an optimizer-hint comment
     (``/*+ ... */``) is rejected outright: the server executes their
     contents.
  2. The statement must be exactly one top-level statement. A trailing
     semicolon is still one statement.
  3. The leading keyword must be permitted: SELECT always; INSERT and
     UPDATE only when the daemon runs in "select_insert_update" mode.
     A leading parenthesis is a parenthesized SELECT (or set
     operation) -- a parenthesized DML statement is not valid SQL and
     is not permitted.
  4. The statement must not call a denied function: an identifier
     followed by "(" whose lower-cased name starts with one of the
     denied prefixes (the state-changing fractal_* functions, and EXTERN, Druid SQL's
     way to read or write outside the cluster).
  5. The statement must not contain INTO OUTFILE or INTO DUMPFILE:
     that writes to the filesystem and is never permitted.

Each case is (id, category, statement, select_mode, insert_update_mode,
expected_reason). The verdict is "allow" or "reject". The reason, when
given, is a substring the rejection message must contain.

The runner (service/tests/t2s_policy.py) compares the daemon's answers
with these expectations. A case whose result differs from the documented
rule is a finding; the ones already found are listed in KNOWN_DIFFERENCES
below, each with the finding it belongs to, so that a NEW difference
fails the gate.
"""

# (id, category, statement, in "select" mode, in "select_insert_update" mode, reason)
CASES = [
    # ---- case mixing ----------------------------------------------------
    ("case-lower", "case", "select 1", "allow", "allow", None),
    ("case-mixed", "case", "SeLeCt 1", "allow", "allow", None),
    ("case-upper", "case", "SELECT 1", "allow", "allow", None),
    ("case-keyword-in-name", "case", "SELECTOR 1", "reject", "reject", "not permitted"),
    ("case-dollar-after", "case", "SELECT$1", "reject", "reject", "not permitted"),

    # ---- comments --------------------------------------------------------
    ("comment-line-end", "comment", "SELECT 1 -- trailing", "allow", "allow", None),
    ("comment-line-lead", "comment", "-- lead\nSELECT 1", "allow", "allow", None),
    ("comment-block-lead", "comment", "/* lead */ SELECT 1", "allow", "allow", None),
    ("comment-block-mid", "comment", "SELECT /* mid */ 1", "allow", "allow", None),
    # "#" is not a comment in Druid SQL (it is a syntax error), so a statement that starts with one is not a SELECT.
    ("comment-hash", "comment", "# lead\nSELECT 1", "reject", "reject", "not permitted"),
    ("comment-unterminated", "comment", "SELECT 1 /* unterminated", "allow", "allow", None),
    ("comment-inside-token", "comment", "select/**/1", "allow", "allow", None),
    ("comment-between-tokens", "comment", "SELECT 1 /* a */ ; /* b */", "allow", "allow", None),
    ("comment-versioned", "comment", "/*! SELECT 1 */", "reject", "reject", "comments are not allowed"),
    ("comment-versioned-numeric", "comment", "/*!50000 DROP TABLE t */ SELECT 1", "reject", "reject", "comments are not allowed"),
    ("comment-hint", "comment", "/*+ index hint */ SELECT 1", "reject", "reject", "comments are not allowed"),
    ("comment-versioned-in-string", "comment", "SELECT '/*!*/'", "allow", "allow", None),
    ("comment-versioned-in-quotes", "comment", 'SELECT "/*!*/"', "allow", "allow", None),
    ("comment-hash-line", "comment", "SELECT 1 # trailing", "allow", "allow", None),

    # ---- whitespace variants --------------------------------------------
    ("space-lead", "space", "\n\t SELECT 1", "allow", "allow", None),
    ("space-trail", "space", "SELECT 1   ", "allow", "allow", None),
    ("space-only", "space", "   \t\n", "reject", "reject", "SQL is empty"),
    ("space-nbsp-lead", "space", " SELECT 1", "reject", "reject", "not permitted"),
    ("space-nbsp-after-keyword", "space", "SELECT 1", "allow", "allow", None),
    ("space-formfeed", "space", "SELECT 1\f", "allow", "allow", None),

    # ---- leading parentheses ---------------------------------------------
    ("paren-select", "paren", "(SELECT 1)", "allow", "allow", None),
    ("paren-select-nested", "paren", "((SELECT 1))", "allow", "allow", None),
    ("paren-set-operation", "paren", "(SELECT 1) UNION (SELECT 2)", "allow", "allow", None),
    ("paren-insert", "paren", "(INSERT INTO t VALUES (1))", "reject", "reject", "not permitted"),
    ("paren-delete", "paren", "(DELETE FROM t)", "reject", "reject", "not permitted"),
    ("paren-update", "paren", "(UPDATE t SET a = 1)", "reject", "reject", "not permitted"),

    # ---- semicolon-separated batches -------------------------------------
    ("batch-two", "batch", "SELECT 1; SELECT 2", "reject", "reject", "exactly one SQL statement"),
    ("batch-trailing-semicolon", "batch", "SELECT 1;", "allow", "allow", None),
    ("batch-trailing-semicolon-space", "batch", "SELECT 1 ; ", "allow", "allow", None),
    ("batch-semicolon-only", "batch", ";", "reject", "reject", "SQL is empty"),
    ("batch-double-semicolon", "batch", "SELECT 1;; SELECT 2", "reject", "reject", "exactly one SQL statement"),
    ("batch-semicolon-in-string", "batch", "SELECT 'a;b'", "allow", "allow", None),

    # ---- quoted identifiers and string literals that contain keywords ----
    ("quote-string-drop", "quote", "SELECT 'DROP TABLE t'", "allow", "allow", None),
    ("quote-double-drop", "quote", 'SELECT "DROP TABLE t"', "allow", "allow", None),
    ("quote-backtick-drop", "quote", "SELECT `DROP TABLE t`", "allow", "allow", None),
    ("quote-string-semicolon", "quote", 'SELECT "a;b"', "allow", "allow", None),
    ("quote-denied-in-string", "quote", "SELECT 'fractal_audit_log('", "allow", "allow", None),
    ("quote-denied-in-double", "quote", 'SELECT "fractal_audit_log("', "allow", "allow", None),
    ("quote-backtick-column", "quote", "SELECT `col` FROM `tbl`", "allow", "allow", None),
    ("quote-escaped-quote", "quote", "SELECT 'a''b'", "allow", "allow", None),
    ("quote-backslash", "quote", "SELECT 'a\\'b'", "allow", "allow", None),

    # ---- dollar quoting --------------------------------------------------
    ("dollar-plain", "dollar", "SELECT $$abc$$", "allow", "allow", None),
    ("dollar-tagged", "dollar", "SELECT $tag$abc$tag$", "allow", "allow", None),

    # ---- unicode look-alikes ---------------------------------------------
    ("unicode-nbsp-only", "unicode", " ", "reject", "reject", "not permitted"),
    ("unicode-cyrillic-e", "unicode", "SЕLECT 1", "reject", "reject", "not permitted"),
    ("unicode-fullwidth", "unicode", "ＳＥＬＥＣＴ 1", "reject", "reject", "not permitted"),

    # ---- very long statements --------------------------------------------
    ("long-columns", "long", "SELECT " + "a," * 3000 + "b FROM t", "allow", "allow", None),
    ("long-parens", "long", "SELECT " + "(" * 200 + "1" + ")" * 200, "allow", "allow", None),
    ("long-keyword", "long", "SELECT" + " " * 5000 + "1", "allow", "allow", None),
    ("long-comment", "long", "/*" + "x" * 10000 + "*/ SELECT 1", "allow", "allow", None),

    # ---- embedded NULs ----------------------------------------------------
    ("nul-after-select", "nul", "SELECT 1\x00DROP TABLE t", "allow", "allow", None),
    ("nul-only", "nul", "\x00", "reject", "reject", "not permitted"),

    # ---- the statements that start with something -------------------------
    ("lead-with", "lead", "WITH x AS (SELECT 1) SELECT * FROM x", "allow", "allow", None),
    ("lead-with-recursive", "lead", "WITH RECURSIVE r AS (SELECT 1) SELECT * FROM r", "allow", "allow", None),
    ("lead-with-dml", "lead", "WITH c AS (SELECT 1) DELETE FROM t", "reject", "reject", "not permitted"),
    ("lead-with-insert", "lead", "WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c", "reject", "allow", None),
    ("lead-with-update", "lead", "WITH c AS (SELECT 1) UPDATE t SET a = 1", "reject", "allow", None),
    ("lead-with-malformed", "lead", "WITH", "reject", "reject", "does not parse"),
    ("lead-with-unbalanced", "lead", "WITH x AS (SELECT 1", "reject", "reject", "does not parse"),
    ("lead-explain", "lead", "EXPLAIN SELECT 1", "reject", "reject", "not permitted"),
    ("lead-values", "lead", "VALUES (1)", "reject", "reject", "not permitted"),
    ("lead-table", "lead", "TABLE t", "reject", "reject", "not permitted"),
    ("lead-show", "lead", "SHOW TABLES", "reject", "reject", "not permitted"),
    ("lead-describe", "lead", "DESCRIBE t", "reject", "reject", "not permitted"),
    ("lead-set", "lead", "SET @a = 1", "reject", "reject", "not permitted"),
    ("lead-use", "lead", "USE db", "reject", "reject", "not permitted"),
    ("lead-lock", "lead", "LOCK TABLES t READ", "reject", "reject", "not permitted"),
    ("lead-call", "lead", "CALL p()", "reject", "reject", "not permitted"),
    ("lead-grant", "lead", "GRANT ALL ON *.* TO x", "reject", "reject", "not permitted"),
    ("lead-create", "lead", "CREATE TABLE t(a int)", "reject", "reject", "not permitted"),
    ("lead-alter", "lead", "ALTER TABLE t ADD b int", "reject", "reject", "not permitted"),
    ("lead-truncate", "lead", "TRUNCATE TABLE t", "reject", "reject", "not permitted"),
    ("lead-drop", "lead", "DROP TABLE t", "reject", "reject", "not permitted"),
    ("lead-replace", "lead", "REPLACE INTO t VALUES (1)", "reject", "reject", "not permitted"),
    ("lead-delete", "lead", "DELETE FROM t", "reject", "reject", "not permitted"),
    ("lead-update", "lead", "UPDATE t SET a = 1", "reject", "allow", None),
    ("lead-insert", "lead", "INSERT INTO t VALUES (1)", "reject", "allow", None),

    # ---- the denied calls, in every spelling the code handles -------------
    ("denied-audit-log", "denied", "SELECT fractal_audit_log('x', '{}')", "reject", "reject", "changes state"),
    ("denied-audit-log-upper", "denied", "SELECT FRACTAL_AUDIT_LOG('x')", "reject", "reject", "changes state"),
    ("denied-audit-log-mixed", "denied", "SELECT Fractal_Audit_Log('x')", "reject", "reject", "changes state"),
    ("denied-ledger-prefix", "denied", "SELECT fractal_ledger_flush(1)", "reject", "reject", "changes state"),
    ("denied-ledger-verify", "denied", "SELECT fractal_ledger_verify(1)", "reject", "reject", "changes state"),
    ("denied-lock", "denied", "SELECT fractal_lock_destructive()", "reject", "reject", "changes state"),
    ("denied-diversify", "denied", "SELECT fractal_diversify_enable(1)", "reject", "reject", "changes state"),
    ("denied-feedback", "denied", "SELECT fractal_feedback_report(1, 1, 'x')", "reject", "reject", "changes state"),
    ("denied-isolate", "denied", "SELECT fractal_isolate_background(1)", "reject", "reject", "changes state"),
    ("denied-sql-agent", "denied", "SELECT fractal_sql_agent('x')", "reject", "reject", "changes state"),
    ("denied-agent-prefix", "denied", "SELECT fractal_agent_foo()", "reject", "reject", "changes state"),
    ("denied-store-prefix", "denied", "SELECT fractal_store_x()", "reject", "reject", "changes state"),
    ("denied-vectorizer-prefix", "denied", "SELECT fractal_vectorizer_x()", "reject", "reject", "changes state"),
    ("denied-daemon-config-set", "denied", "SELECT fractal_daemon_config_set('a', 'b')", "reject", "reject", "changes state"),
    # Druid SQL's way out of the cluster: TABLE(EXTERN(...)) reads external data (any Druid input source) in a SELECT on
    # the MSQ engine, and writes to an external location as the target of INSERT or REPLACE.
    ("denied-extern", "denied", "SELECT * FROM TABLE(EXTERN('{}', '{}', '[]'))", "reject", "reject", "changes state"),
    ("denied-extern-lower-space", "denied", "SELECT * FROM TABLE(extern ('{}'))", "reject", "reject", "changes state"),
    ("denied-extern-quoted", "denied", "SELECT * FROM TABLE(\"EXTERN\"('{}'))", "reject", "reject", "changes state"),
    ("denied-extern-insert", "denied", "INSERT INTO t SELECT * FROM TABLE(EXTERN('{}', '{}', '[]'))", "reject", "reject", None),
    ("denied-extern-nested", "denied", "SELECT * FROM (SELECT * FROM TABLE(EXTERN('{}'))) x", "reject", "reject", "changes state"),
    ("extern-name-without-call", "denied", "SELECT extern_notes FROM t", "allow", "allow", None),
    # The MySQL names are not Druid functions: the planner refuses them ("no match found for function signature"),
    # so the allowlist does not need to, and they are not on its list.
    ("mysql-sleep-is-not-druid", "denied", "SELECT SLEEP(5)", "allow", "allow", None),
    ("mysql-load-file-is-not-druid", "denied", "SELECT LOAD_FILE('/etc/passwd')", "allow", "allow", None),
    ("denied-prefix-extended", "denied", "SELECT fractal_ledger_anything(1)", "reject", "reject", "changes state"),
    ("denied-comment-before-paren", "denied", "SELECT fractal_audit_log/**/('x')", "reject", "reject", "changes state"),
        ("denied-line-comment-after-name", "denied", "SELECT fractal_audit_log -- c\n ('x')", "reject", "reject", "changes state"),
    # In Druid SQL (Calcite) "--" starts a comment with no whitespace needed, so this is "SELECT 1" and a comment.
    # (In a dialect where "--" needs whitespace after it, the same text is a call and is rejected.)
    ("denied-double-dash-no-space", "denied", "SELECT 1--fractal_audit_log('x')", "allow", "allow", None),
    ("comment-slash-slash", "denied", "SELECT 1 // fractal_audit_log('x')", "allow", "allow", None),
    ("denied-after-slash-slash-line", "denied", "SELECT 1 // c\nfractal_audit_log('x')", "reject", "reject", "changes state"),
    ("denied-quoted-identifier", "denied", "SELECT \"fractal_audit_log\"('x')", "reject", "reject", "changes state"),
    ("denied-quoted-identifier-upper", "denied", "SELECT \"FRACTAL_AUDIT_LOG\" ('x')", "reject", "reject", "changes state"),
    ("denied-quoted-identifier-comment", "denied", "SELECT \"fractal_audit_log\"/**/('x')", "reject", "reject", "changes state"),
    ("denied-backtick-identifier", "denied", "SELECT `fractal_audit_log`('x')", "reject", "reject", "changes state"),
    ("quoted-identifier-not-a-call", "denied", "SELECT \"fractal_audit_log\" FROM t", "allow", "allow", None),
    # A backslash is an ordinary character in Druid SQL, so this string ends at the second quote and the call is code.
    ("denied-after-backslash-string", "denied", "SELECT 'a\\' , fractal_audit_log('x') --'", "reject", "reject", "changes state"),
    ("statements-after-backslash-string", "statements", "SELECT 'a\\'; DELETE FROM t; --'", "reject", "reject", "exactly one"),
    ("denied-hash-comment", "denied", "SELECT 1 # c\nfractal_audit_log('x')", "reject", "reject", "changes state"),
    ("denied-block-comment-in-name", "denied", "SELECT fractal_audit_/**/log('x')", "reject", "reject", "changes state"),
    ("denied-nested-in-from", "denied", "SELECT * FROM t WHERE a IN (SELECT fractal_audit_log('x'))", "reject", "reject", "changes state"),
    ("denied-not-a-call", "denied", "SELECT fractal_audit_log FROM t", "allow", "allow", None),

    # ---- INTO OUTFILE / DUMPFILE -----------------------------------------
    ("outfile", "outfile", "SELECT 1 INTO OUTFILE '/tmp/x'", "reject", "reject", "OUTFILE"),
    ("outfile-lower", "outfile", "select 1 into outfile '/tmp/x'", "reject", "reject", "OUTFILE"),
    ("dumpfile", "outfile", "SELECT 1 INTO DUMPFILE '/tmp/x'", "reject", "reject", "OUTFILE"),
    ("outfile-into-elsewhere", "outfile", "INSERT INTO t SELECT 1 INTO OUTFILE '/tmp/x'", "reject", "reject", ("not permitted", "OUTFILE")),
    ("outfile-in-string", "outfile", "SELECT 'INTO OUTFILE'", "allow", "allow", None),
    ("outfile-in-quoted", "outfile", 'SELECT "INTO OUTFILE"', "allow", "allow", None),
]


# The cases whose result differs from the documented rule, with the finding
# that explains the difference. A case that is NOT listed here and still
# differs is a new finding, and fails the gate.
KNOWN_DIFFERENCES = {}
