# OpenAI ChatGPT Codex Agent Instructions

## Project Overview

**aws-sdk-http-async** - A Ruby gem that replaces the AWS SDK for Ruby Net::HTTP
send handler with `async-http` to enable fiber-based concurrency (Falcon/Async).
It includes a global patcher and a configurable Net::HTTP fallback so
CLI/test/console use cases "just work".

All architecture docs and decisions live in `md-docs/`. Keep RFCs and plans
there.

## Repository Layout (Orientation)

- `lib/async/aws/handler.rb` - core Seahorse send handler, streaming + fallback
logic.
- `lib/async/aws/client_cache.rb` - per-reactor async-http client cache,
SSL/proxy config.
- `lib/async/aws/http_plugin.rb` - plugin options + registration.
- `lib/async/aws/patcher.rb` - global patch/unpatch utilities (ObjectSpace
scan).
- `spec/` - unit + integration tests (including proxy CONNECT harness).
- `md-docs/` - RFCs, decisions, roadmap.
- `bin/ci` + `Rakefile` - local CI/format/test tasks.

## Critical Constraints

- **Ruby 3.4+ only.** `aws-sdk-core >= 3.241.0`, `async-http >= 0.94.0`.
- **Pure gem** (no Rails/ActiveRecord).
- **Seahorse handler contract** must be preserved:
  - `signal_headers`, `signal_data`, `signal_done`, `signal_error`.
- **Public methods require YARD docs** (`@param`, `@return`).
- **No destructive git commands** (no add/commit/push/reset/checkout).

## Runtime Model (Key Decisions)

### Transport Selection

- **Async transport when reactor exists:** `Async::Task.current?` ->
`async-http`.
- **Fallback when no reactor:** default `:net_http` so CLI/tests/console work.
- Config options:
  - `Aws.config[:async_http_fallback] = :net_http | :sync | :raise`
  - ENV `AWS_SDK_HTTP_ASYNC_FALLBACK` overrides config.
  - ENV `AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP` forces Net::HTTP even if reactor
  exists.
- **Event streams** (Transcribe/Bedrock streaming) always require an Async
reactor and delegate to AWS native HTTP/2 handler.

### Streaming Uploads

- `async_http_streaming_uploads` modes:
  - `:auto` (default): stream **rewindable + known size** bodies; buffer
  otherwise.
  - `:force`: always stream; **raises if retries enabled and body
  non-rewindable**.
  - `:off`: always buffer.
- Size detection order: `Content-Length` header -> `#bytesize` -> `#length` ->
`#size`.
- **Memory safety:** `async_http_max_buffer_bytes` default **5MB**.
  - Applies to Strings, buffered bodies, and `StreamingBody#buffered`.
  - Unknown-size IOs are read in chunks; if chunked read unsupported and max set
  -> raises.
- `Transfer-Encoding` is stripped when body is buffered to avoid header/body
mismatch.

### Headers and Response Semantics

- Headers normalized to lowercase; `host` + `content-length` removed before
request.
- `accept-encoding` forced to empty **only if absent** and
`async_http_force_accept_encoding` true.
- Duplicate response headers merged with `,` (Net::HTTP parity).
- `Set-Cookie` and `Set-Cookie2` are joined with `\n` to preserve cookie
boundaries (RFC 6265).

### Timeouts

- `http_open_timeout` used for endpoint connect.
- `http_read_timeout` enforced **per read chunk** (not total request deadline).
- `async_http_total_timeout` applies to the full request lifecycle (upload +
headers + body).
- `async_http_idle_timeout` applies to idle sockets in async-http pools.
- `timeout <= 0` disables timeouts.

### Client Cache (Per Reactor)

- Per-reactor LRU cache, capped by `async_http_max_cached_clients` (default
100).
- Cache key includes endpoint, connection limit, open timeout, proxy + SSL
settings.
- Reactor binding tracked via `WeakRef` to avoid stale clients on GC.
- **Cold-start guard removed**: concurrent cold hits can build duplicate
clients; extras are closed. This avoids Async + Mutex deadlocks and keeps logic
simple.
- `clear!`/`close!` are shutdown-only; **call inside each reactor** to close on
owning reactor. If called outside a reactor, it force-closes (may interrupt
in-flight requests).

### SSL and Certificates

- `ssl_verify_peer` enforces hostname verification (`verify_hostname=true` when
supported).
- If no CA settings provided, a cached `OpenSSL::X509::Store` with
`set_default_paths` is used.
- `ssl_cert` / `ssl_key` accept OpenSSL objects or file paths (String /
`#to_path`).
  - Empty strings raise `ArgumentError`.
  - File reads are **blocking**; prefer preloading at boot and passing OpenSSL
  objects.
- Cache key uses string paths when provided; OpenSSL objects use `object_id`
(reuse objects to keep cache stable).

### Proxy Support

- `http_proxy` supports a full URL (incl. Basic auth).
- Uses CONNECT for HTTPS. No env proxy support, PAC, or auto-discovery.
- Proxy auth is Basic derived from `user:pass@` (userinfo is percent-decoded).
- Proxy credentials are hashed in cache keys to avoid leaking secrets.

## Patching and Activation

- `require 'aws-sdk-http-async'` auto-patches all AWS clients (retroactive via
ObjectSpace scan).
- `require 'aws-sdk-http-async/core'` loads without auto-patching for explicit
plugin usage.
- `Async::Aws::Patcher.patch(:all)` and `unpatch(:all)` available for test
isolation.
- Unpatch removes only classes tracked by the patcher (custom subclasses may
retain plugin).
- ObjectSpace scan is O(N) in loaded classes; require early in boot for best
performance.

## Development and CI

Commands:

```bash
bundle exec rake formatter
bundle exec rspec
bin/ci
```

`bin/ci` runs: bundle check -> rufo -> rubocop -> rspec -> bundler-audit ->
brakeman (skips if no Rails app). Formatting is Rufo + RuboCop (single quotes).

## Testing Notes

- Specs live in `spec/` with unit + integration coverage.
- Proxy CONNECT integration test uses an async-native proxy harness (no
`Timeout.timeout`).
- No special RSpec setup required; Net::HTTP fallback covers reactorless
contexts.
- Use `Sync { ... }` if you want tests to exercise async-http.

## Guardrails

- Avoid blocking I/O inside the reactor; use preloaded SSL objects.
- Avoid threads for I/O coordination; prefer fibers / Async primitives.
- Use `rg` for search (no `grep` / `find`).
- Keep changes small; add/adjust specs for behavior changes.

## Quick Debugging

```ruby
require 'aws-sdk-http-async'
client = Aws::DynamoDB::Client.new
client.list_tables
```
