<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL for Apache Druid -- packaging notes

FractalSQL for Druid has three parts, and the packages carry all three:

- **The extension** (`fractalsql-druid.jar`): the SQL functions, the `FRACTAL_SEARCH` aggregate and the
  `/fractalsql` service endpoints. It is a Druid extension, so it goes into Druid's extensions directory and is
  named in `druid.extensions.loadList`. Nothing registers it with the operating system.
- **`fractalsqld`** (with its CLI, `fsqlctl`): the reasoning, embedding and enterprise service. It runs beside the
  Druid brokers and serves the extension over a Unix socket, so model calls, third-party code and licensed code
  stay out of Druid's processes. It runs on a JVM and wraps the native adapter.
- **`fractalsql-druid-mcp`**: a Model Context Protocol server for agents. It is a client of Druid's SQL endpoint
  and of the extension's endpoints, and it needs nothing beyond OpenSSL.

`scripts/package.sh` is the only builder. Artifacts are built and uploaded by a tag push (`v<X.Y.Z>`) through
`.github/workflows/release.yml`.

## Release assets

The file names carry no version, so `.../releases/latest/download/<name>` always points at the newest release;
the version is inside the package. `<arch>` is `amd64` or `arm64`.

| Release asset | What it is |
| --- | --- |
| `fractalsql-druid-linux-<arch>.tar.gz` | The bundle for Linux. |
| `fractalsql-druid-macos-<arch>.zip` | The bundle for macOS. |
| `fractalsql-druid-<arch>.deb` | Debian and Ubuntu package: files in place, a `fractalsql` service account, a systemd unit and a generated signing key. |
| `fractalsql-druid-<arch>.rpm` | The same for Red Hat style systems. |
| `SHA256SUMS` | The SHA-256 of every asset above. `easy_install.sh` verifies what it downloads against it and refuses a file that is not listed. |
| `easy_install.sh` | The installer, stamped with the release version. |

Inside a bundle (`fractalsql-druid-<version>/`):

| Path | What it is |
| --- | --- |
| `extensions/fractalsql-druid/fractalsql-druid.jar` | The Druid extension. |
| `fractalsqld/` | The service (`fractalsqld.jar` and its native library), and the optional reasoning plugin with its detached `.sig`. The plugin loads only with its `.sig` beside it. |
| `bin/` | `fractalsqld` (launcher), `fsqlctl`, `fractalsql-druid-mcp` and its two lock files, and the ledger tools `fractalsql-ledger-collect` and `fractalsql-ledger-check`. |
| `mcp/` | The MCP server's manifest, `README.md` and `RUN.txt` (how to start it). |
| `conf/` | `fractalsqld.conf.example` and the systemd unit. |
| `docs/` | The documentation. |
| `install.sh` | Installs the bundle (below). |
| `LICENSE`, `THIRD-PARTY-NOTICES.md` | This project's licence (Apache-2.0) and the third-party notices. |

The MCP server's two `.mcp-*-lock` files must stay beside its executable: the server refuses to start without them.
Every package puts them there.

## Installing

**Packages.** `dpkg -i` or `rpm -i` places everything. The extension then goes into Druid's extensions directory
(copy `/usr/lib/fractalsql-druid/extensions/fractalsql-druid`), `fractalsql-druid` is added to
`druid.extensions.loadList`, `/etc/fractalsql/fractalsqld.conf` is edited for your provider, and the service is
started with `systemctl enable --now fractalsqld`. The signing key at `/etc/fractalsql/hmac.key` is created on
install if it does not exist, readable by the `fractalsql` group only. The user that runs Druid must be in that
group (to read the key) and listed in `allowed_uids` in the configuration (to connect).

**Bundle.** Unpack it and run `./install.sh --druid-home /opt/druid`. It copies the extension into that Druid, puts
the daemon, `fsqlctl` and the MCP server under a prefix, writes the configuration and a random signing key unless
they already exist, and prints the Druid runtime properties to add. It does not edit your Druid configuration and
it does not start anything. `--dry-run` prints what it would do.

**One command.** `scripts/easy_install.sh` downloads the matching release, verifies it against `SHA256SUMS` and
installs it; see `--help`.

## Requirements

| On the host | Needs |
| --- | --- |
| Druid | Druid 37 or 38 (built against 38, tested on both). |
| `fractalsqld` | A Java 17 or newer runtime (17, 21 or 25). The reasoning plugin links libcurl from the host. |
| MCP server | OpenSSL's runtime library (`libssl.so.3` on Linux, Homebrew's `openssl@3` on macOS). |

The extension itself needs only the Java runtime Druid already has. The Linux binaries are built on Rocky Linux 9
(glibc 2.34), so they run on anything at least that new. Platforms: Linux and macOS, on amd64 and arm64.

## Version table (v2.0.0)

| Component | Version |
| --- | --- |
| FractalSQL for Druid extension (Community) | 2.0.0 (`SELECT fractal_version();`) |
| Edition reported by `fractal_edition()` | `Community` |
| `fractalsql-druid-mcp` | 2.0.0 (`fractalsql-druid-mcp --version`) |
| Vendored reasoning plugin (`fractalsql-reasoning-http`) | see `include/REASONING_VERSION` |
| FractalSQL core archive inside the native library | see `include/VERSION` |
| Druid | built against 38, tested on 37 and 38 |

## Reasoning plugin

The optional Cognition-tier plugin (`fractalsql-reasoning-http.so` / `.dylib`) is vendored per platform under
`include/` and ships inside each bundle with its detached signature. A plugin is a shared object mapped into the
service process, so the daemon will not load one that lacks a `.sig` verifying against the FractalSQLabs signing key
built into it. Keep the two files together. Configuration is described in
[docs/reasoning-setup.md](../docs/reasoning-setup.md).

## Enterprise tier

The enterprise library is licensed and is never part of the repository or of a public release. To enable the tier in a
build you make yourself, drop `libfractalsql-enterprise-sovereign-c.so` and its `.sig` into `include/<platform>/`, beside the
community core, the same place the reasoning plugin lives. `scripts/package.sh` then puts the pair under
`fractalsqld/enterprise/` in the bundle, and the Docker build picks it up the same way. Point `enterprise_lib` in
`fractalsqld.conf` at it (the example file has the path); the signature beside it is verified before it is loaded.

## MCP server

The MCP server (`mcp/`, see [docs/mcp-plugin.md](../docs/mcp-plugin.md)) ships in every package; no separate download
is needed. `mcp/RUN.txt` is the short version of how to start it, and `mcp/README.md` has every setting.

Apache Druid and the Druid logo are trademarks of the Apache Software Foundation. FractalSQL is not affiliated with
or endorsed by the Apache Software Foundation.
