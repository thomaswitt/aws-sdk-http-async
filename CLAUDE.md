# CLAUDE.md

## Project Overview

**aws-sdk-http-async** - Async HTTP transport for AWS SDK for Ruby using
`async-http`, built for fiber runtimes (Falcon/Async). It globally patches AWS
clients by default and falls back to Net::HTTP when no reactor is present.

All architectural decisions belong in `md-docs/`.

## Critical Constraints

- Ruby 3.4+ only (`aws-sdk-core >= 3.241.0`, `async >= 2.46.0`,
  `async-http >= 0.105.0`).
- Pure gem (no Rails/ActiveRecord).
- Preserve Seahorse handler contract and error semantics.
- YARD docs required for public methods.
- No destructive git commands.

## Key Architecture Decisions (Must-Knows)

### Fallback Modes

- Default: `:net_http` when no reactor exists.
- Configurable: `Aws.config[:async_http_fallback] = :net_http | :sync | :raise`.
- ENV override: `AWS_SDK_HTTP_ASYNC_FALLBACK`.
- ENV force: `AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP`.
- Event streams always require Async reactor and use SDK HTTP/2 handler.
- `require 'aws-sdk-http-async/core'` loads without auto-patching for explicit
plugin usage.

### Streaming Uploads

- `:auto` streams only rewindable + known-size bodies; buffers otherwise.
- `:force` streams all but raises if retries enabled and body non-rewindable.
- `:off` buffers always.
- Size order: `Content-Length` -> `#bytesize` -> `#length` -> `#size`.
- `async_http_max_buffer_bytes` default 5MB and enforced everywhere (Strings,
buffers, `StreamingBody#buffered`).

### Client Cache

- Handlers share the process-wide `ClientCache.default` (Seahorse builds a new
handler per API call); `async_http_client_cache` overrides it.
- Per-reactor LRU (default 100) with `WeakRef` to avoid stale reactors.
- Entries of closed reactors are dropped; a forked child drops inherited
entries without a protocol-level close (it only closes its own copies of the
sockets).
- `async_http_connection_limit` defaults to 50 per reactor and endpoint.
Connections open concurrently; a per-entry semaphore keeps to the limit.
- `http_idle_timeout` (default 5s) closes unused pooled connections.
- Closes of entries taken out of the cache run in a transient task, so a
cancelled request does not abandon them.
- Cold-start gate removed (simple double-checked insert); duplicate builds are
closed.
- `clear!`/`close!` closes the calling reactor's clients and those of finished
reactors; never another running reactor's.

### SSL + Proxy

- Hostname verification enforced if `ssl_verify_peer`.
- Default CA store cached via `OpenSSL::X509::Store#set_default_paths`.
- `ssl_cert` / `ssl_key` accept OpenSSL objects or file paths; empty strings
raise.
- File reads are blocking; prefer preloaded OpenSSL objects.
- `http_proxy` supports Basic auth, CONNECT for HTTPS; no env proxy/PAC.
- CONNECT tunnels are pooled and owned by the reactor (`TunnelEndpoint`), not by
the request that opened them.
- Proxy credentials hashed in cache key; percent-decoding preserves `+`.

### Headers + Timeouts

- Lowercase headers; strip `host`, `content-length`.
- Accept-Encoding forced empty only if absent.
- Set-Cookie + Set-Cookie2 joined with `\n`; other duplicates join with `,`.
- `http_open_timeout` = connect; `http_read_timeout` = per-chunk read timeout.
- `async_http_total_timeout` = total request deadline (upload + headers + body).
- `async_http_idle_timeout` is used as the endpoint timeout when
  `http_open_timeout` is unset.
- The transport's own deadlines raise `TransportTimeoutError` (mapped to a
  networking error); a caller's own `Async::TimeoutError` passes through.

## Development Commands

```bash
bundle exec rake formatter
bundle exec rspec
bin/ci
```

`bin/ci` runs rufo, rubocop, rspec, bundler-audit, and brakeman (skips if no
Rails app).

## Testing Notes

- Proxy CONNECT integration test uses async-native harness (no
`Timeout.timeout`).
- No special RSpec setup needed; Net::HTTP fallback covers reactorless contexts.
- Use `Sync {}` in tests to exercise async-http path.

## Guardrails

- Avoid blocking I/O inside reactor.
- Avoid threads for I/O; use Async primitives.
- Use `rg` for search.

## Quick Debug

```ruby
require 'aws-sdk-http-async'
client = Aws::DynamoDB::Client.new
client.list_tables
```
