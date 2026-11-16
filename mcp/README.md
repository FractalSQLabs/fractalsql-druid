<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL MCP Server for Apache Druid

`fractalsql-druid-mcp` is an MCP (Model Context Protocol) server for
**FractalSQL for Apache Druid**: one clean tool per FractalSQL SQL function, so an
external agent (Claude Desktop, Cursor, Windsurf, Claude Code, LangChain,
LlamaIndex, CrewAI, ...) can call a primitive or one of the sixteen
installable agents without ever speaking SQL.

The full user documentation (quickstart, per-tier tool catalog, resources and
prompts, operational caveats, troubleshooting) lives in
**[docs/mcp-plugin.md](../docs/mcp-plugin.md)**. This README covers building,
running, and deploying the server.

## What's in this directory

    mcp/
      Makefile                    POSIX build (g++ or clang, make)
      .mcp-schema-lock            committed tool-surface integrity hash
      .mcp-safety-annotations-lock  committed safety-annotation hash
      manifest.json               distribution manifest
      RUN.txt                     how to start the server: where it is, its settings, stdio and HTTP(S)
      src/                        C++17 sources
        main.cpp                  CLI flags, configuration from the environment
        jsonrpc_server.cpp        JSON-RPC dispatch, cancellation, shutdown
        db.h                      per-session connections, bootstrap, version guard
        tool_registry.cpp         tool table and the shared error taxonomy
        adapters/                 discovery | cognition | agency | analytics |
                                  enterprise | vectorizer | admin
        resources.cpp             the fractalsql:// read-only resources
        prompts.cpp               the eleven starter-kit prompts
        transport_stdio.cpp      default transport (newline-delimited JSON-RPC)
        transport_http.cpp        optional HTTP transport (Bearer token + probes)
        schema_lock.cpp           lock creation and startup verification
        vectors.cpp               vector-argument normalization
        rows.h                    row ceiling and truncation annotation
      vendor/json.hpp             nlohmann::json, vendored
      tests/druid_mcp_offline.py  protocol checks that need no cluster
      tests/druid_mcp_e2e.py      every tool family against a live Druid
      tests/mcp_conformance.py    protocol eras, authentication, framing, switches and the catalog's shape

The server talks to Druid over HTTP, so the binary has no database client
dependency beyond OpenSSL: install or copy it and point it at Druid.

`RUN.txt`, next to this file, is the short version: where the binary is, the settings it needs, and how to start it
over stdio, HTTP or HTTPS.

## Build and run

```bash
# Linux/macOS: g++ or clang >= 11, OpenSSL dev headers, make
make -C mcp                                   # -> mcp/fractalsql-druid-mcp
```

Stdout carries the MCP wire (stdio transport); **all logging goes to stderr**
as structured JSON lines, so the wire protocol is never polluted.

```bash
DRUID_URL=http://localhost:8888 \
DRUID_FRACTALSQL_URL=http://localhost:8082 \
  ./fractalsql-druid-mcp                     # stdio (default)

./fractalsql-druid-mcp --version             # release banner
./fractalsql-druid-mcp --list-tools          # the tool table
./fractalsql-druid-mcp --http 8765           # optional HTTP transport
./fractalsql-druid-mcp --https 8765 \
  --tls-cert cert.pem --tls-key key.pem       # HTTP transport, direct TLS
```

Configuration is environment-only (`DRUID_URL`, `DRUID_FRACTALSQL_URL`,
`DRUID_USER` / `DRUID_PASSWORD` or `DRUID_TOKEN`, `FSQL_MCP_*`) plus
the narrow flag set `--help` prints. The full environment table is in
[docs/mcp-plugin.md](../docs/mcp-plugin.md).

## Keep data access least-privilege

The MCP server inherits whatever its Druid identity can touch and adds **no
second auth layer**. The boundary is how you deploy:

- Give the server a Druid user whose permissions cover only the datasources the
  MCP client should see. Druid's authorizer enforces it.
- Need per-tenant isolation? Run one MCP server instance per tenant, each with
  its own Druid identity.
- Run admin/config tools (`fractal_config_set`,
  `fractal_configure_reasoning`) against a separately-scoped server
  instance from ordinary tool traffic.
- `auto_execute` defaults to false on the SQL-writing agents and requires an
  explicit client-set parameter to enable. `FSQL_MCP_READ_ONLY=true` is the
  deployment-wide stop switch: every `destructiveHint` tool is refused
  outright, before the call reaches the engine. It keys on
  `destructiveHint`, so it stops every tool the safety-annotation lock marks
  destructive — not every write; the real no-write boundary is the Druid
  identity's permissions.

## Regenerating the integrity locks

After any reviewed change to a tool's name, description, or schema, to safety
annotations, or to catalog membership, regenerate the committed checks and
commit them alongside your change:

```bash
fractalsql-druid-mcp --write-schema-lock
fractalsql-druid-mcp --write-safety-annotations-lock
fractalsql-druid-mcp --write-manifest
git add .mcp-schema-lock .mcp-safety-annotations-lock manifest.json
```

The server verifies both locks at startup. A stale lock is a hard startup failure by default;
set `FSQL_MCP_STRICT_SCHEMA_HASH=false` to downgrade it to a warning.

## Hardening switches

| Variable | Effect |
|---|---|
| `FSQL_MCP_READ_ONLY` | `true` / `1` / `on` / `yes` (any case). Refuses every tool that writes state, and applies the engine-side backstop where the engine has one. |
| `FSQL_MCP_ALLOW_MISSING_LOCKS` | Off by default. A missing schema or safety-annotation lock file stops startup; set `true` to run without the drift check (development only). An explicit `FSQL_MCP_REQUIRE_LOCKS=false` has the same effect. Lock files are looked up in the working directory first, then next to the executable. |
| `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` | Off by default. The HTTP transport refuses to bind a non-loopback address without TLS (enable TLS with `FSQL_MCP_HTTPS=true` and a certificate/key); set this to `true` to accept a plaintext bind on a network you control. |
| `FSQL_MCP_ALLOW_AUTO_EXECUTE` | Off by default. A model may only ask for `auto_execute` on the two tools that take it when the operator has turned this on. |
| `FSQL_MCP_CONFIG_WRITES` | `safe` by default: the config-writing admin tools may change only the model names and the think mode. `off` refuses every write, `all` allows any key the build knows. |
| `FSQL_MCP_PROTOCOL_ERA` | `dual` by default: both protocol eras are served. `modern` serves the modern era only. |
| `FSQL_MCP_TOKEN_POLICY_FILE` | Per-client credentials: a JSON file naming clients, each with the SHA-256 of its token, an optional expiry and an optional tool allowlist. |
| `FSQL_MCP_ALLOWED_ORIGINS` | Comma-separated browser origins allowed to make cross-origin requests. An `Origin` header that is not on the list is refused with `403`, before the token is even checked. |
| `FSQL_MCP_SESSION_TTL_SECS` / `FSQL_MCP_MAX_SESSIONS` | How long an idle session-state handle survives (default 3600) and how many may exist at once (default 64). A handle belongs to the credential that created it. |

Every state-changing tool is reported with `destructiveHint: true`, so a client that honours the annotation asks before calling it and read-only mode refuses it. Each `tool_call` log line carries a short `client` digest identifying the session or token that made the call.

## Audit data at rest

The audit chain lives in the ledger file `fractalsqld` keeps (see
[docs/fractalsql-daemon.md](../docs/fractalsql-daemon.md))
(`enterprise_ledger_path`), so that file's permissions, backups and volume
encryption are what protect it at rest.

Two settings, read from the `fractalsqld` environment, shape what the chain keeps and how a truncated chain
is noticed:

- `FSQL_AUDIT_REDACT` (`none` by default, or `hash` / `truncate`) keeps a
  fingerprint of the question, the generated SQL, the analysis and the
  rows instead of the text itself. The values returned to the caller are
  never redacted.
- `FSQL_LEDGER_ANCHOR_LOG` (`off` by default, or `stderr` / `syslog`)
  publishes one JSON line per append — `{"event":"ledger_head","kind":K,"rows":N,"hash":"<hex>"}` —
  so a chain whose tail was deleted no longer matches the last line
  published and the truncation is visible off-host.

