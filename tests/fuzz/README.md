<p align="center">
  <img src="../../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Fuzzing

libFuzzer targets for the two places that parse bytes they do not control:
the MCP server's request handling, and the daemon's own parsers. No
target needs a Druid cluster.

## The MCP server's targets

| Target | Entry point | Seeds |
| --- | --- | --- |
| `fuzz_mcp_vectors.cpp` | Argument coercion (`mcp/src/vectors.cpp`) and error-text secret redaction (`sanitizeSecrets`). The first input byte selects the function. | `corpus_mcp_vectors/` |
| `fuzz_mcp_jsonrpc.cpp` | `JsonRpcServer::handleLine`, the function both transports hand each client line to, with two stub tools. | `corpus_mcp_jsonrpc/` |

A `ToolError` is the server's documented rejection and is not a finding. A
crash, hang or sanitizer report is.

## The daemon's targets

The daemon's adapter is in the shipped path: it turns text it did not
choose (a vector, a series, a JSON payload, a statement, a frame, a
config file, a library file) into structures. These targets are built
from the adapter's own sources, so the code under test is the code that
ships.

| Target | What it reaches | Seeds |
| --- | --- | --- |
| `fuzz_svc_udf.c` | The whole UDF layer: a function from the registry, its `_init`, its body and its `_deinit`, called exactly as the daemon's dispatcher calls them. One harness, every function. | `corpus_svc_udf/` |
| `fuzz_svc_parse.c` | The vector, corpus and index text parsers, and the vector text formatter the parsed vector goes back through. | `corpus_svc_parse/` |
| `fuzz_svc_redact.c` | The audit redactor, in all three of its modes (none, hash, truncate). | `corpus_svc_redact/` |
| `fuzz_svc_t2s.c` | The text-to-SQL policy: the statement counter, the leading-statement classifier, the denied-call scan, the OUTFILE scan, the versioned-comment scan -- and a second, independent implementation of two of them, which must agree. | `corpus_svc_t2s/` |
| `fuzz_svc_ledger.c` | The ledger reader and verifier: the record header reader, the scan, the tip check, the full verification walk, an append against a damaged file, the head-file parser, the JSON well-formedness test. | `corpus_svc_ledger/` |
| `fuzz_svc_frame.c` | The FSQ frame reader with the tag check on: almost every input must be rejected, and the rejection must be clean. | `corpus_svc_frame/` |
| `fuzz_svc_frame_auth.c` | The same reader with a VALID tag, so the fuzzer reaches the payload parsing: the TLV decoder, the function lookup, the handle registry. | `corpus_svc_frame_auth/` |
| `fuzz_svc_config.c` | The daemon's configuration file parser, and the validation a configuration goes through before it is accepted. | `corpus_svc_config/` |
| `fuzz_svc_sig.c` | The enterprise library's signature gate: the library bytes and the `.sig` beside it. Every input must be refused. | `corpus_svc_sig/` |

A harness that needs a function the product keeps `static` includes the
product's own source, so the code under test is the code that ships.

## Building and running

The daemon's targets are built and run by `build_test.sh --fuzz`, which
builds each one with ASAN and UBSAN, replays its corpus, and then fuzzes
it for `FSQL_FUZZ_SECS` (30 by default) seconds. Eleven targets, so the
mode takes about five minutes plus the build.

```
./build_test.sh --fuzz
FSQL_FUZZ_SECS=600 ./build_test.sh --fuzz      # ten minutes per target
```

A crash reproduces directly against the same binary:
`/path/to/fuzz_svc_udf <crash-file>`.

The MCP server's two targets are built by hand:

```
clang++-18 -std=c++17 -O1 -g -fsanitize=fuzzer,address -Imcp/src -Imcp/vendor \
    tests/fuzz/fuzz_mcp_vectors.cpp mcp/src/vectors.cpp mcp/src/errors.cpp \
    -o /tmp/fuzz_mcp_vectors
mkdir -p /tmp/fuzz_new
ASAN_OPTIONS=detect_leaks=0 /tmp/fuzz_mcp_vectors \
    -max_total_time=3600 /tmp/fuzz_new tests/fuzz/corpus_mcp_vectors/
```

`fuzz_mcp_jsonrpc` is built the same way from `fuzz_mcp_jsonrpc.cpp`,
`mcp_evp_stub.cpp` (it supplies the pieces that would need a cluster) and the
server's sources `jsonrpc_server.cpp`, `errors.cpp`, `logging.cpp`,
`prompts.cpp`, `resources.cpp` and `tool_registry.cpp`, linked with
`-lssl -lcrypto -lpthread`.

You need a clang with libFuzzer support: the `clang` package and its
runtime (`libclang-rt-<version>-dev` on Debian).

## Seed corpora

Each `corpus_<target>/` directory holds seed files, enough for libFuzzer to
start coverage-guided mutation from a real input instead of cold.

`tests/fuzz/make_corpus.py` writes the daemon's corpora: the vector and
series texts, the audit payloads, the statements the text-to-SQL policy has
opinions about, a real ledger and the ways one gets damaged, the protocol
frames, and the configuration file.

```
python3 tests/fuzz/make_corpus.py
```

The UDF corpus comes from the live daemon, which knows the registry better
than a script does. `service/tests/workout.py` writes it when
`FSQL_WORKOUT_DUMP_CORPUS` names a directory:

```
FSQL_WORKOUT_DUMP_CORPUS=tests/fuzz/corpus_svc_udf \
    python3 service/tests/workout.py SOCKET KEYFILE
```

libFuzzer writes the new inputs it discovers into the first directory it is
given. Point it at a scratch directory and pass the seed directory second, as
above, so the tracked seeds stay as they are.
