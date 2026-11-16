#!/usr/bin/env python3
"""Run a FractalSQL demo against Apache Druid.

FractalSQL's demos are SQL scripts. Druid has no command-line client, so
this is the client: it reads a demo file, splits it into statements, runs
each against the Druid SQL API, and prints the results tab-separated, with
no header, so the gate that checks the demos can assert on them.

Three Druid-specific behaviours:

* **A statement that writes is a task.** ``INSERT INTO`` / ``REPLACE
  INTO`` go to the SQL task endpoint and the runner *waits* for the task
  to finish, so the next statement sees the rows. A SELECT goes to the
  ordinary SQL endpoint and comes back immediately.
* **A failed statement does not stop the file.** Like the other hosts'
  ``--force``, the runner prints ``ERROR ...`` and carries on, so one
  broken step does not hide the rest of the demo. The exit status is
  non-zero if anything failed.
* **There is no DDL.** Druid has no ``CREATE TABLE`` and no ``DROP
  TABLE``. A demo that needs fixtures creates them with MSQ
  ``INSERT INTO ... SELECT ... FROM UNNEST(...) PARTITIONED BY ALL``,
  which is ordinary SQL and needs no special handling here.

Standard library only, Python 3.8+.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8888/druid/v2/sql"
DEFAULT_TASK_URL = "http://127.0.0.1:8888/druid/v2/sql/task"
# The extension's own endpoints. They live on the nodes that load the
# extension -- the broker in the demo stack -- and not on the router,
# which forwards only Druid's own routes.
DEFAULT_SERVICE_URL = "http://127.0.0.1:8082"

# The fixture column that carries the row's timestamp. Druid's rows are
# timestamped by __time, so the fixture's timestamp column becomes it.
TIMESTAMP_COLUMN = "ts"

# A statement that writes. These are submitted as MSQ tasks.
WRITE_RE = re.compile(r"^\s*(INSERT|REPLACE)\b", re.IGNORECASE)

# A service call -- the steps that are not SQL.
#
# A directive sits in the demo file as a comment, so it must start its
# own line: prose that merely mentions "@fixture" is not a directive.
CALL_RE = re.compile(r"(?m)^[ \t]*(?:--[ \t]*)?@call\s+(?P<path>[A-Za-z0-9_/-]+)")

# A fixture: the rows of a datasource. Druid has no DDL, no VALUES and no
# UNNEST ordinality, so a multi-column fixture has no SQL form -- the
# ingestion path is the one that takes real rows.
FIXTURE_RE = re.compile(r"(?m)^[ \t]*(?:--[ \t]*)?@fixture\s+(?P<name>[A-Za-z0-9_]+)")


def directives(statement):
    """The directives in a chunk, in the order they appear.

    A chunk may hold several: a fixture, then a service call, then
    another. Each is (kind, match); the match's end is where the body's
    braces start.
    """
    found = [("call", m) for m in CALL_RE.finditer(statement)]
    found += [("fixture", m) for m in FIXTURE_RE.finditer(statement)]
    found.sort(key=lambda item: item[1].start())
    return found


def extract_json_span(text, start):
    """The JSON object at or after `start`, matched by brace depth.

    Returns (body, end) where `end` is just past the closing brace, so
    the caller knows where the directive ends and the SQL resumes. A
    body may span several comment lines and contain nested objects, so
    the braces have to be counted rather than matched by a non-greedy
    pattern.
    """
    begin = text.find("{", start)
    if begin < 0:
        return None, start
    depth = 0
    in_string = False
    escaped = False
    for index in range(begin, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[begin:index + 1], index + 1
    return None, begin


def extract_json_object(text, start):
    """The JSON object at or after `start`, or None."""
    body, _ = extract_json_span(text, start)
    return body


def clean_body(raw):
    """The body with the comment markers taken off its lines.

    A directive's body is written across comment lines, so each line
    after the first carries a "--" prefix. The prefix is the demo
    file's formatting, not part of the JSON.

    A newline that falls *inside* a JSON string is escaped: a prompt
    written across several comment lines would otherwise be invalid
    JSON.
    """
    if raw is None:
        return None
    body = re.sub(r"(?m)^[ \t]*--[ \t]?", "", raw)
    return escape_newlines_in_strings(body)


def escape_newlines_in_strings(body):
    """Escape the raw control characters that fall inside a JSON string."""
    out = []
    in_string = False
    escaped = False
    for char in body:
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            elif char == "\n":
                out.append("\\n")
                continue
            elif char == "\r":
                out.append("\\r")
                continue
            elif char == "\t":
                out.append("\\t")
                continue
        elif char == '"':
            in_string = True
        out.append(char)
    return "".join(out)


def candidate_of(previous):
    """The statement the previous step generated, for "$candidate".

    A service step's result may carry the SQL it produced; a later
    step that wants to talk about that statement -- a reviewer, a
    validator -- refers to it by the placeholder rather than embedding
    it in the directive's JSON, where the quoting would be a trap.
    """
    if isinstance(previous, dict):
        for key in ("generated_sql", "sql_text", "candidate"):
            value = previous.get(key)
            if isinstance(value, str):
                return value
    return ""


def previous_context(previous):
    """The text of the previous step's result, for "$previous".

    A service step's result is a document; what a later step wants is
    the answer in it -- the search result, the reasoning text -- not the
    whole envelope.
    """
    if isinstance(previous, str):
        return previous
    if isinstance(previous, dict):
        for key in ("result", "answer", "text"):
            value = previous.get(key)
            if isinstance(value, str):
                return value
    return json.dumps(previous)

# A statement Druid cannot run at all. Reported clearly rather than as a
# generic planning error.
DDL_RE = re.compile(r"^\s*(CREATE|DROP|ALTER|ATTACH)\b", re.IGNORECASE)


class DruidError(Exception):
    """A statement failed."""


def split_statements(text):
    """Split a SQL script into statements.

    Handles line comments, block comments, single-quoted strings (with
    doubled-quote escapes), double-quoted identifiers, and semicolons
    inside all of them.
    """
    statements = []
    buf = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]

        # Line comment.
        if ch == "-" and text.startswith("--", i):
            j = text.find("\n", i)
            if j < 0:
                j = n
            buf.append(text[i:j])
            i = j
            continue

        # Block comment.
        if ch == "/" and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(text[i:j])
            i = j
            continue

        # Single-quoted string.
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            buf.append(text[i:j])
            i = j
            continue

        # Double-quoted identifier.
        if ch == '"':
            j = i + 1
            while j < n:
                if text[j] == '"':
                    if j + 1 < n and text[j + 1] == '"':
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            buf.append(text[i:j])
            i = j
            continue

        if ch == ";":
            statements.append("".join(buf))
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    statements.append("".join(buf))
    # A chunk of nothing but comments is dropped -- unless it holds a
    # directive, which is a comment too, and the step it describes is
    # the whole point of the chunk.
    return [
        s
        for s in (s.strip() for s in statements)
        if s and (not is_only_comments(s) or directives(s))
    ]


def is_only_comments(text):
    """Whether a chunk is nothing but comments and whitespace."""
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    stripped = re.sub(r"--[^\n]*", "", stripped)
    return not stripped.strip()


def strip_comments(text):
    """The statement's text without its comments -- what gets sent."""
    out = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    out = re.sub(r"--[^\n]*", " ", out)
    return out.strip()


def post_json(url, payload, timeout=300):
    """POST a JSON body and return (status, parsed body)."""
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            status = response.status
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        status = exc.code
    except urllib.error.URLError as exc:
        raise DruidError("cannot reach {}: {}".format(url, exc.reason))
    try:
        parsed = json.loads(body) if body else None
    except ValueError:
        parsed = body
    return status, parsed


def get_json(url, timeout=60):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            status = response.status
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        status = exc.code
    except urllib.error.URLError as exc:
        raise DruidError("cannot reach {}: {}".format(url, exc.reason))
    try:
        parsed = json.loads(body) if body else None
    except ValueError:
        parsed = body
    return status, parsed


def error_message(body):
    """The message out of a Druid error body."""
    if isinstance(body, dict):
        for key in ("errorMessage", "error", "message"):
            value = body.get(key)
            if isinstance(value, str) and value:
                return value
            if isinstance(value, dict):
                nested = value.get("message") or value.get("errorMessage")
                if isinstance(nested, str) and nested:
                    return nested
    if isinstance(body, str) and body.strip():
        return body.strip()
    return "unknown error"


# A kit's self-check verdict: "HEADLINE kit=<name> FAILED".
HEADLINE_FAILED_RE = re.compile(r"^HEADLINE\s.*\sFAILED$")


def run_select(sql, url, context):
    """Run a SELECT and return its rows."""
    payload = {"query": sql, "resultFormat": "array", "header": False}
    if context:
        payload["context"] = context
    status, body = post_json(url, payload)
    if status != 200:
        raise DruidError(error_message(body))
    rows = body if isinstance(body, list) else []
    # Every kit ends with a self-check row, "HEADLINE kit=<name> ok" or "... FAILED". A failed check is a failed kit, whatever
    # statements ran cleanly before it.
    for row in rows:
        for cell in (row if isinstance(row, list) else [row]):
            if isinstance(cell, str) and HEADLINE_FAILED_RE.match(cell.strip()):
                raise DruidError("the kit's own headline check failed: {}".format(cell.strip()))
    return rows


def run_write(sql, url, task_url, context, poll_timeout=600):
    """Submit a write as an MSQ task and wait for it to finish."""
    payload = {"query": sql}
    # Wait for the new segments to be loaded before the task reports success. Without it, a REPLACE over a datasource
    # that already exists can finish while the broker still serves the old segments, and the next query reads stale rows.
    payload["context"] = dict({"waitUntilSegmentsLoad": True}, **(context if isinstance(context, dict) else {}))
    status, body = post_json(task_url, payload)
    # The task API answers 202 with the task id.
    if status not in (200, 201, 202):
        raise DruidError(error_message(body))
    task_id = None
    if isinstance(body, dict):
        task_id = body.get("taskId") or body.get("id")
    if not task_id:
        raise DruidError("the task API returned no task id: {}".format(body))

    base = task_url.rsplit("/druid/v2/sql/task", 1)[0]
    deadline = time.time() + poll_timeout
    while time.time() < deadline:
        _, status_body = get_json(
            "{}/druid/indexer/v1/task/{}/status".format(base, task_id)
        )
        state, error = task_state(status_body)
        if state in ("SUCCESS", "FAILED", "CANCELED"):
            if state != "SUCCESS":
                raise DruidError("the task {} ended {}: {}".format(task_id, state, error))
            wait_for_datasource(sql, base)
            return
        time.sleep(1)
    raise DruidError("the task {} did not finish within {} seconds".format(task_id, poll_timeout))


# The datasource a write targets: REPLACE INTO <name> / INSERT INTO <name>.
#
# The datasource a @call names: "... AS <name>".
AS_TARGET_RE = re.compile(r"^AS\s+([A-Za-z0-9_]+)[^A-Za-z0-9_]|$")
TARGET_RE = re.compile(r"^\s*(?:REPLACE|INSERT)\s+INTO\s+\"?([A-Za-z0-9_]+)\"?", re.IGNORECASE)

# The column aliases a write projects: `... AS "name"` or `... AS name`.
# The wait for a datasource to become queryable uses them, so that it
# waits for the SCHEMA and not just for the object.
COLUMN_ALIAS_RE = re.compile(r'\bAS\s+(?:"([^"]+)"|([A-Za-z0-9_]+))\s*$')

# A term that is a plain column reference, with or without a qualifier:
# `"conn_rate"`, `x.channel`. The column it produces is named after the
# reference's last part.
COLUMN_REFERENCE_RE = re.compile(
    r'^(?:[A-Za-z0-9_]+\.)?(?:"([^"]+)"|([A-Za-z0-9_]+))$')

# A write's outer projection: `REPLACE INTO "x" OVERWRITE ALL SELECT
# <list> FROM ...`. The columns the write produces are the OUTPUT names
# of that list -- the alias of each term, or the term itself when it
# has no alias.
WRITE_PREFIX_RE = re.compile(
    r'^\s*(?:REPLACE|INSERT)\s+INTO\s+"?([A-Za-z0-9_]+)"?\s+OVERWRITE\s+ALL\s+SELECT\s',
    re.IGNORECASE | re.S)

# A bare quoted identifier.
QUOTED_IDENT_RE = re.compile(r'"([A-Za-z0-9_]+)"')


def split_projection(projection):
    """The write's outer SELECT list, one term at a time.

    The commas inside a term's parentheses -- a function call's own
    arguments, or a subquery's -- do not split it. Nor does a comma
    inside a quoted string, which is where a JSON path's arguments
    live.
    """
    projection = strip_comments(projection)
    terms = []
    depth = 0
    in_string = False
    start = 0
    i = 0
    n = len(projection)
    while i < n:
        c = projection[i]
        if in_string:
            if c == "'":
                in_string = False
        elif c == "'":
            in_string = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        elif c == "," and depth == 0:
            terms.append(projection[start:i])
            start = i + 1
        i += 1
    terms.append(projection[start:])
    return [t.strip() for t in terms if t.strip()]


def write_projection(sql):
    """The write's outer SELECT list, and the datasource it writes.

    The list ends at the FROM, at the PARTITIONED BY, or at the end of
    the statement -- but the FROM that ends it is the OUTER one. A
    write whose projection holds a subquery
    (`SELECT FRACTAL_OPTIMIZE_PORTFOLIO((SELECT "mu" FROM "m"), ...)
    AS "rj" FROM "rows"`) has a FROM inside the subquery too, and
    stopping at that one would read the subquery's columns as the
    write's output.

    Returns (datasource, projection), or (None, "") if the statement is
    not a write of that shape.
    """
    # The comments go first. An apostrophe inside a comment -- in
    # "ARRAY_AGG's size guardrail", say -- would otherwise open a
    # string literal that never closes, and every parenthesis after it
    # would be counted at the wrong depth.
    sql = strip_comments(sql)
    match = WRITE_PREFIX_RE.match(sql)
    if not match:
        return None, ""
    start = match.end()
    depth = 0
    in_string = False
    i = start
    n = len(sql)
    while i < n:
        c = sql[i]
        if in_string:
            if c == "'":
                in_string = False
        elif c == "'":
            in_string = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        elif depth == 0 and (i == 0 or sql[i - 1].isspace()):
            for terminator in ("FROM", "PARTITIONED BY"):
                if sql[i:i + len(terminator)].upper() == terminator:
                    return match.group(1), sql[start:i]
            if c == ";":
                return match.group(1), sql[start:i]
        i += 1
    return match.group(1), sql[start:]


def written_columns(sql):
    """The columns a write produces.

    Each term of the write's outer SELECT list contributes its OUTPUT
    name: the alias when it has one, and the bare quoted identifier
    when it does not. Both cases matter -- a fixture aliases every
    column, and a hand-written write often does not -- and the probe
    has to ask for the columns that are actually produced, or it comes
    back before the last one has landed.

    The distinction between an alias and its expression matters too.
    A write that projects `FRACTAL_DIMENSION_DRIFT("series", 32) AS
    "d"` produces the column "d"; "series" is an INPUT to the
    expression, and the datasource does not have it. Asking for it
    would fail forever, and the wait would burn its whole timeout on
    every such write.
    """
    _, projection = write_projection(sql)
    if not projection:
        return []
    columns = []
    for term in split_projection(projection):
        alias = COLUMN_ALIAS_RE.search(term)
        if alias:
            names = [alias.group(1) or alias.group(2)]
        else:
            reference = COLUMN_REFERENCE_RE.match(term)
            if reference:
                # A plain column reference: the column it produces is
                # named after the reference's last part.
                names = [reference.group(1) or reference.group(2)]
            else:
                # A computed term with no alias: its output name is
                # whatever the engine calls it, and the probe cannot
                # know. Ask for nothing rather than for the wrong
                # thing.
                names = []
        for name in names:
            if name not in columns:
                columns.append(name)
    return columns



def wait_for_datasource(sql, base, timeout=120):
    """Wait until the datasource a write created is queryable.

    An MSQ task can finish before the coordinator has published the
    datasource, and a query that lands in that window is told the
    object does not exist. A trivial query against it is the honest
    test: it covers both the datasource not being there yet and its
    segments not being visible.
    """
    match = TARGET_RE.match(sql)
    if not match:
        return
    name = match.group(1)
    endpoint = base + "/druid/v2/sql"
    # The probe selects the COLUMNS the write produced, not a
    # constant. A datasource can exist and be queryable while the
    # broker's cached schema for it still lacks the column that was
    # just added -- and a query that lands in that window is told the
    # column does not exist. Probing with the columns themselves is
    # the honest test: it fails until the schema has caught up.
    columns = written_columns(sql)
    if columns:
        projection = ", ".join('"{}"'.format(c) for c in columns)
        probe = 'SELECT {} FROM "{}" LIMIT 1'.format(projection, name)
    else:
        probe = 'SELECT 1 FROM "{}" LIMIT 1'.format(name)
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, body = post_json(endpoint, {"query": probe})
        if status == 200:
            return
        time.sleep(1)


def task_state(body):
    """The state of a task, and its error message.

    Druid's task status nests the state: {"task": ..., "status": {"status":
    "SUCCESS", ...}}, so the state is two levels down.
    """
    if not isinstance(body, dict):
        return None, ""
    inner = body.get("status")
    if isinstance(inner, dict):
        return inner.get("status") or inner.get("statusCode"), inner.get("errorMsg") or ""
    return body.get("status") or body.get("statusCode"), body.get("errorMsg") or ""


def format_row(row):
    """One row as tab-separated values."""
    if isinstance(row, list):
        cells = row
    elif isinstance(row, dict):
        cells = list(row.values())
    else:
        cells = [row]
    out = []
    for cell in cells:
        if cell is None:
            out.append("")
        elif isinstance(cell, bool):
            out.append("1" if cell else "0")
        else:
            out.append(str(cell))
    return "\t".join(out)


def resolve_times(value):
    """Resolve a relative timestamp: "now", "now-55m", "now+2h"."""
    if not isinstance(value, str):
        return value
    text = value.strip().lower()
    if not text.startswith("now"):
        return value
    import datetime

    when = datetime.datetime.now(datetime.timezone.utc)
    rest = text[3:].strip()
    if rest:
        sign = 1
        if rest[0] in "+-":
            sign = -1 if rest[0] == "-" else 1
            rest = rest[1:].strip()
        if rest.endswith("m") and rest[:-1].isdigit():
            when += sign * datetime.timedelta(minutes=int(rest[:-1]))
        elif rest.endswith("h") and rest[:-1].isdigit():
            when += sign * datetime.timedelta(hours=int(rest[:-1]))
        elif rest.endswith("d") and rest[:-1].isdigit():
            when += sign * datetime.timedelta(days=int(rest[:-1]))
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def fixture_sql(name, body):
    """The MSQ write that loads a fixture.

    Druid has no DDL, no VALUES and no row-wise tuple source, so a
    fixture -- a set of rows -- has no direct SQL form. What it does
    have is an array of JSON documents and the extension's own JSON
    accessors, so the rows go in as one JSON document each and the
    columns come out of them:

        REPLACE INTO "demo_alerts" OVERWRITE ALL
        SELECT CAST(FRACTAL_JSON_TEXT(t.j, '$.ts') AS TIMESTAMP) AS "__time",
               FRACTAL_JSON_TEXT(t.j, '$.service') AS "service", ...
        FROM UNNEST(ARRAY['{"ts":"...","service":"..."}', ...]) AS t(j)
        PARTITIONED BY DAY;

    OVERWRITE ALL is what makes a demo re-runnable: a plain INSERT
    appends, and a second run would double the rows.
    """
    rows = body.get("rows") or []
    if not rows:
        raise DruidError("the fixture has no rows")

    columns = []
    for row in rows:
        for key in row:
            if key not in columns:
                columns.append(key)

    def sql_string(text):
        return "'" + str(text).replace("'", "''") + "'"

    projections = []
    for column in columns:
        path = "'$." + column.replace("'", "''") + "'"
        values = [row.get(column) for row in rows if row.get(column) is not None]
        numbers = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]
        alias = '"' + column.replace('"', '""') + '"'
        if column == TIMESTAMP_COLUMN:
            # The timestamp becomes the row's __time.
            projections.append(
                "CAST(FRACTAL_JSON_TEXT(t.j, {path}) AS TIMESTAMP) AS \"__time\"".format(path=path)
            )
        elif values and len(numbers) == len(values):
            projections.append(
                "FRACTAL_JSON_VALUE(t.j, {path}) AS {alias}".format(path=path, alias=alias)
            )
        else:
            projections.append(
                "FRACTAL_JSON_TEXT(t.j, {path}) AS {alias}".format(path=path, alias=alias)
            )

    documents = []
    for row in rows:
        record = {}
        for column in columns:
            value = row.get(column)
            if isinstance(value, str):
                value = resolve_times(value)
            record[column] = value
        documents.append(sql_string(json.dumps(record, separators=(",", ":"))))

    # A fixture with a timestamp column is time-partitioned; one without
    # is not, because Druid's MSQ wants a time column whenever the
    # granularity is not ALL.
    partitioned = "PARTITIONED BY DAY" if TIMESTAMP_COLUMN in columns else "PARTITIONED BY ALL"

    return (
        'REPLACE INTO "{name}" OVERWRITE ALL\n'
        "SELECT {projections}\n"
        "FROM UNNEST(ARRAY[{documents}]) AS t(j)\n"
        "{partitioned}"
    ).format(
        name=name.replace('"', '""'),
        projections=", ".join(projections),
        documents=", ".join(documents),
        partitioned=partitioned,
    )


# The extension refuses to register the same vectorizer twice. A kit that creates one stays safe to re-run only if
# "already registered" counts as the state it asked for, so the runner answers with the existing entry.
VECTORIZER_EXISTS_RE = re.compile(r"a vectorizer for .* already exists \(id (\d+)\)")


def existing_vectorizer(url, body, detail):
    """The registered entry a duplicate ``vectorizer create`` collided with, or None.

    Only a ``create`` whose refusal names an existing id qualifies; any other failure is the caller's to report.
    """
    found = VECTORIZER_EXISTS_RE.search(detail)
    if not found:
        return None
    try:
        if json.loads(body).get("action") != "create":
            return None
        status, listing = post_json(url, {"action": "list"})
    except (ValueError, DruidError, AttributeError):
        return None
    if status != 200 or not isinstance(listing, dict):
        return None
    for entry in listing.get("vectorizers", []):
        if str(entry.get("id")) == found.group(1):
            return entry
    return None


def run_service_call(match, body, service_url, previous=None):
    """Run a service call and return the parsed result.

    The directive is a comment line, so it sits inside the demo file
    without disturbing the SQL around it:

        -- @call search/explore {"datasource": "docs", "vectorColumn": "emb",
        --                     "query": "[1.0,0.0]", "k": 5}

    A body that carries "$previous" gets the previous call's result
    spliced in, which is how one service step feeds the next.
    """
    path = match.group("path").strip()
    if body is None:
        raise DruidError("the @call directive has no JSON body")
    body = clean_body(body)
    if previous is not None and "$previous" in body:
        body = body.replace('"$previous"', json.dumps(previous_context(previous)))
    if previous is not None and "$candidate" in body:
        body = body.replace('"$candidate"', json.dumps(candidate_of(previous)))
    url = service_url.rstrip("/") + "/fractalsql/" + path.lstrip("/")
    request = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("error", detail)
        except ValueError:
            pass
        if path.strip("/") == "vectorizer":
            entry = existing_vectorizer(url, body, str(detail))
            if entry is not None:
                return entry
        raise DruidError("the service call failed: {}".format(detail))
    except urllib.error.URLError as exc:
        raise DruidError("cannot reach the service at {}: {}".format(url, exc.reason))


def write_result(name, payload, url, task_url, context):
    """Write a service call's result into a datasource.

    A result that carries a "rows" array becomes one row per entry; any
    other result becomes a single row holding the whole document. The
    write is an MSQ write, so the datasource holds exactly this result.
    """
    if isinstance(payload, dict) and isinstance(payload.get("rows"), list):
        rows = payload["rows"]
    elif isinstance(payload, dict) and isinstance(payload.get("items"), list):
        rows = payload["items"]
    elif isinstance(payload, dict) and isinstance(payload.get("hits"), list):
        rows = payload["hits"]
    elif isinstance(payload, dict) and isinstance(payload.get("memories"), list):
        rows = payload["memories"]
    elif isinstance(payload, dict) and isinstance(payload.get("vectorizers"), list):
        rows = payload["vectorizers"]
    elif isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict):
        # A document with no rows of its own: its own fields become the
        # row's columns, so a caller can read them back.
        rows = [payload]
    else:
        rows = [{"result": json.dumps(payload)}]
    if not rows:
        # An empty result has no rows to write, and an MSQ write of
        # zero rows is not something Druid does. The call itself
        # succeeded and its result was printed; there is simply no
        # datasource to materialise, so say so rather than failing the
        # statement.
        print("-- nothing to write: {} was empty".format(name))
        return
    run_write(fixture_sql(name, {"rows": rows}), url, task_url, context)


def run_file(
    path,
    url,
    task_url,
    context,
    force=True,
    quiet=False,
    service_url=None,
):
    """Run one demo file. Returns (statements_run, failures)."""
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    statements = split_statements(text)
    failures = 0
    ran = 0
    previous = None
    for statement in statements:
        # A chunk may hold a directive (a fixture, a service call) and
        # then the SQL that follows it. The directives run first, in
        # order; the SQL after the last one runs last.
        found = directives(statement)
        resume = 0
        for kind, match in found:
            ran += 1
            raw, resume = extract_json_span(statement, match.end())
            try:
                if kind == "fixture":
                    if raw is None:
                        raise DruidError("the @fixture directive has no JSON body")
                    body = json.loads(clean_body(raw))
                    run_write(
                        fixture_sql(match.group("name").strip(), body),
                        url,
                        task_url,
                        context,
                    )
                    if not quiet:
                        print("-- loaded: {}".format(match.group("name").strip()))
                else:
                    # "AS <datasource>" asks for the result to be
                    # materialised, so a later statement can query it.
                    target = None
                    found = AS_TARGET_RE.match(statement[resume:].strip())
                    if found:
                        target = found.group(1)
                    payload = run_service_call(match, raw, service_url or url, previous)
                    previous = payload
                    if not quiet:
                        print(format_row([payload]))
                    if target:
                        write_result(target, payload, url, task_url, context)
            except (DruidError, ValueError) as exc:
                failures += 1
                print("ERROR {}".format(exc))
                if not force:
                    break
        if not force and failures:
            break

        sql = strip_comments(statement[resume:])
        # A directive's body is followed by the ";" that ended its chunk,
        # and by the "AS <datasource>" clause when the call asked for its
        # result to be materialised.
        sql = re.sub(r"^\s*;\s*", "", sql)
        sql = re.sub(r"^\s*AS\s+[A-Za-z0-9_]+\s*;?\s*", "", sql, flags=re.IGNORECASE)
        if not sql:
            continue
        ran += 1
        try:
            if DDL_RE.match(sql):
                raise DruidError(
                    "Druid has no DDL; a fixture must be created with "
                    "INSERT INTO ... SELECT ... FROM UNNEST(...) PARTITIONED BY ALL"
                )
            if WRITE_RE.match(sql):
                run_write(sql, url, task_url, context)
                if not quiet:
                    print("-- wrote: {}".format(sql.split("\n")[0][:100]))
            else:
                rows = run_select(sql, url, context)
                if not quiet:
                    for row in rows:
                        print(format_row(row))
        except DruidError as exc:
            # A write publishes a new segment, and the broker's cached
            # schema for the datasource lags it by a moment. A query
            # that lands in that window is told a column does not
            # exist; waiting for the schema and trying again is the
            # difference between a flaky demo and a broken one.
            message = str(exc)
            if ("not found" in message or "not be grouped" in message
                    or "Planning Failure" in message
                    or "no available brokers" in message):
                # The broker's cached schema for a datasource lags the
                # write that changed it; a few seconds and a retry is
                # usually all it takes.
                for attempt in range(5):
                    time.sleep(10)
                    try:
                        if WRITE_RE.match(sql):
                            run_write(sql, url, task_url, context)
                        else:
                            rows = run_select(sql, url, context)
                        if not quiet:
                            if WRITE_RE.match(sql):
                                print("-- wrote: {}".format(sql.split("\n")[0][:100]))
                            else:
                                for row in rows:
                                    print(format_row(row))
                        break
                    except DruidError:
                        continue
                else:
                    failures += 1
                    print("ERROR {}".format(exc))
                    if not force:
                        break
                continue
            failures += 1
            print("ERROR {}".format(exc))
            if not force:
                break
    return ran, failures


def demo_files(directory):
    """The demo files, in a stable order."""
    names = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".sql"):
            names.append(os.path.join(directory, name))
    return names


def main(argv=None):
    # A model's answer can hold characters the console's encoding cannot
    # represent (an em dash, a non-breaking hyphen). Write UTF-8.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    parser = argparse.ArgumentParser(description="Run FractalSQL demos against Apache Druid")
    parser.add_argument("--url", default=DEFAULT_URL, help="the Druid SQL endpoint")
    parser.add_argument("--task-url", default=DEFAULT_TASK_URL, help="the Druid SQL task endpoint")
    parser.add_argument(
        "--service-url",
        default=DEFAULT_SERVICE_URL,
        help="the extension's own HTTP endpoints (the service tier)",
    )
    parser.add_argument(
        "--file", action="append", default=[], help="a demo file to run (repeatable)"
    )
    parser.add_argument("--dir", default=None, help="a directory of demo files to run")
    parser.add_argument("--only", action="append", default=[], help="run only these (substring)")
    parser.add_argument("--skip", action="append", default=[], help="skip these (substring)")
    parser.add_argument("--list", action="store_true", help="list the demo files and exit")
    parser.add_argument("--quiet", action="store_true", help="do not print the result rows")
    parser.add_argument(
        "--strict", action="store_true", help="stop at the first failing statement"
    )
    parser.add_argument(
        "--context",
        default=None,
        help="a JSON object of Druid query-context values, e.g. '{\"arrayIngestMode\":\"array\"}'",
    )
    args = parser.parse_args(argv)

    context = json.loads(args.context) if args.context else {}

    files = list(args.file)
    if args.dir:
        files.extend(demo_files(args.dir))
    if not files:
        here = os.path.dirname(os.path.abspath(__file__))
        files = demo_files(here)

    if args.only:
        files = [f for f in files if any(s in os.path.basename(f) for s in args.only)]
    if args.skip:
        files = [f for f in files if not any(s in os.path.basename(f) for s in args.skip)]

    if args.list:
        for path in files:
            print(os.path.basename(path))
        return 0

    total_failures = 0
    for path in files:
        if not args.quiet:
            print("=== {}".format(os.path.basename(path)))
        _, failures = run_file(
            path,
            args.url,
            args.task_url,
            context,
            force=not args.strict,
            quiet=args.quiet,
            service_url=args.service_url,
        )
        total_failures += failures

    if total_failures:
        print("FAILED: {} statement error(s)".format(total_failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
