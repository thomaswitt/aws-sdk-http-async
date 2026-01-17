# aws-sdk-http-async RFC

## Summary
Introduce `aws-sdk-http-async`, a new HTTP handler plugin for the AWS SDK for Ruby that uses `async-http` for non-blocking, fiber-friendly I/O. This plugin replaces the SDK's Net::HTTP send handler and is optimized for Falcon and Async runtimes. The handler is registered globally when the gem is required.

## Motivation
Net::HTTP blocks fibers, which defeats Falcon's concurrency model. For high-throughput AWS APIs (DynamoDB, STS, IAM, Lambda), we need an async-compatible transport to restore concurrent I/O without threads.

## Goals
- Provide a production-grade async HTTP handler for common JSON/Query APIs.
- Preserve existing AWS SDK behavior for retries, logging, and telemetry.
- Enable connection reuse and fiber-safe concurrency.
- Keep the change opt-in and low-risk.

## Non-Goals (V1)
- Streaming uploads
- Event stream APIs
- S3 multipart streaming

These are explicitly deferred to V2.

## Runtime Contract (Decision)
- Async reactor required for **async-http** path (Falcon provides this).
- If no reactor exists, default to Net::HTTP fallback.
- Fallback mode is configurable: `:net_http` (default), `:sync`, `:raise`.

## Design Overview

### Plugin
- `Async::Aws::HttpPlugin` replaces the `:send` handler.
- Inherits standard Net::HTTP options (timeouts, SSL options, logger) for parity.
- Adds plugin-specific options:
  - `async_http_connection_limit` (Integer)
  - `async_http_force_accept_encoding` (Boolean)
  - `async_http_body_warn_bytes` (Integer)
  - `async_http_max_buffer_bytes` (Integer, nil disables)
  - `async_http_max_cached_clients` (Integer, nil/0 disables LRU eviction)
  - `async_http_streaming_uploads` (Symbol: :auto, :force, :off)
  - `async_http_fallback` (Symbol: :net_http, :sync, :raise)
  - `async_http_client_cache` (Async::Aws::ClientCache or compatible)

### Handler (Async::Aws::Handler)
- Builds a `Protocol::HTTP::Request` from the SDK request.
- Uses `Async::HTTP::Client` with a per-endpoint cache.
- Streams response body into `Seahorse::Client::Http::Response` (`signal_data`).
- Validates `content-length` and raises `TruncatedBodyError` on mismatch.
- Maps network errors to `Seahorse::Client::NetworkingError` for retry classification.
- Emits AWS telemetry spans.

### Client Cache
- Cache key includes:
  - current reactor id
  - `scheme`, `host`, `port`
  - `async_http_connection_limit`
  - `http_open_timeout`
  - `http_proxy`
  - `ssl_verify_peer`
  - `ssl_ca_store`
  - `ssl_ca_bundle`
  - `ssl_ca_directory`
  - `ssl_cert`
  - `ssl_key`

This avoids connection reuse across incompatible TLS settings.

### Retry Behavior
- Disable async-http retries (`retries: 0`).
- AWS SDK retry logic remains authoritative.

## Request Body Handling (V1)
- Request bodies are buffered in memory.
- Bodies are rewound when possible to allow SDK retries.
- Streaming uploads are a V2 follow-up.
- Large buffered bodies emit a warning (configurable).

## V2 Design Adjustments (Agreed)

### Streaming Uploads (Auto-Detect + Safety Gates)
- **Default mode**: `:auto` streams only when the body is rewindable **and** size is known.
- If size is unknown or body is non‑rewindable:
  - `:auto` buffers and warns.
  - `:force` streams but **disables retries or raises** if retries are enabled.
- Bodies with known size are wrapped in `Protocol::HTTP::Body::Readable`.

### Retry Behavior (Explicit)
- Non‑rewindable streaming bodies **must not** be retried.
- For `:force`, either:
  - set retry limit to 0 (best effort), or
  - raise if retry limit > 0.
- SDK retry logic remains authoritative for buffered bodies.

### Event Streams (Delegate)
- Event stream operations should **bypass** this handler and delegate to the SDK's native HTTP/2 handler.
- Do not skip handler registration globally; detect and delegate per request to preserve load‑order safety.
- Event streams require Async clients (Seahorse::Client::AsyncBase); standard clients should raise a clear error.

### Implementation Order
1. Streaming uploads + retry guard
2. Event stream delegation
3. `ssl_ca_store`
4. `http_proxy`
5. Tests (including S3 multipart streaming)

## V2 Decisions (Documented Limitations)
- Auto-mode buffers non‑rewindable or unknown-size bodies to preserve retry safety.
- `:force` streaming raises if retries are enabled for non‑rewindable bodies (fail-fast).
- Event streams delegate to the SDK's native HTTP/2 handler (Async clients only).
- Multipart streaming requires rewindable bodies with a known size (or Content-Length).
- Set-Cookie/Set-Cookie2 values are joined with "\n" to preserve cookie boundaries.

## Error Mapping
Map the following to `Seahorse::Client::NetworkingError`:
- `Async::TimeoutError`
- Socket errors: `SocketError`, `Errno::ECONNREFUSED`, `Errno::ECONNRESET`, `Errno::ETIMEDOUT`, etc.
- TLS errors: `OpenSSL::SSL::SSLError`
- DNS errors should include host context in the message.

## Options Parity
Supported:
- `http_open_timeout`
- `http_read_timeout`
- `http_idle_timeout` (ignored; async-http manages internally)
- `ssl_verify_peer`
- `ssl_ca_store`
- `ssl_ca_bundle`
- `ssl_ca_directory`
- `ssl_cert`
- `ssl_key`
- `http_proxy`

Unsupported (warn via logger):
- `http_continue_timeout`
- `http_wire_trace`

## Tests

### Unit Tests
- Handler request normalization (headers/body)
- Response streaming and content-length verification
- Error mapping
- Plugin registration and handler replacement

### Integration Tests
- Use `Async::HTTP::Server` (real network IO)
- Validate concurrency with multiple fibers
- Test timeouts and response handling (content-length verification covered by unit tests)

### Plugin Order Test
- Ensure `stub_responses: true` still short-circuits without errors.

## Benchmarking
Measure in a fiber scheduler:
- Net::HTTP sequential vs async-http sequential
- async-http with 10 concurrent fibers
- Track p50/p95, req/s, and connection reuse

## Rollout Plan
1. Ship as an opt-in plugin gem in the repo.
2. Document Falcon-specific usage and limitations.
3. Add sample configuration in README.
4. Iterate on V2 streaming uploads after V1 stabilization.

## Risks
- Incorrect error mapping can break retries.
- Connection cache bugs could mix TLS settings.
- If no reactor is present and fallback is set to :raise, adoption will fail without clear guidance.

## V2 Roadmap
- Streaming uploads (auto‑detect with safety gates)
- Event streams (delegate to SDK HTTP/2 handler)
- S3 multipart streaming
- `ssl_ca_store` support
- `http_proxy` support

## Next Steps
1. Cut a 0.1.x release from the standalone repo.
2. Add streaming uploads (non-buffered request bodies) for V2.
3. Add event stream support (Async::HTTP/2).
4. Upstream a PR to aws-sdk-ruby once stable.
- Advanced retry/backpressure integration
