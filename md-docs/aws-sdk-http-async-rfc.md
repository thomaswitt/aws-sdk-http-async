# aws-sdk-http-async

## Summary

`aws-sdk-http-async` is an async HTTP handler plugin for the AWS SDK for Ruby. It uses `async-http` for non-blocking, fiber-friendly I/O and installs a send handler that replaces the SDK’s Net::HTTP handler. When no reactor is present, it falls back to Net::HTTP by default.

## Motivation

Net::HTTP blocks fibers, which defeats Falcon’s concurrency model. For high-throughput AWS APIs (DynamoDB, STS, IAM, Lambda), we need an async-compatible transport to restore concurrent I/O without threads.

## Goals

- Provide a production-grade async HTTP handler for common AWS APIs.
- Preserve AWS SDK behavior for retries, logging, and telemetry.
- Enable connection reuse and fiber-safe concurrency.
- Keep usage low-friction with a safe fallback when no reactor exists.

## Runtime Contract

- If an Async reactor is present, use async-http.
- If no reactor exists, fall back to Net::HTTP by default.
- Fallback mode is configurable: `:net_http` (default), `:sync`, `:raise`.
- Event stream operations delegate to the SDK’s native HTTP/2 handler and require Async clients.

## Design Overview

### Plugin

- `Async::Aws::HttpPlugin` replaces the `:send` handler.
- Inherits standard Net::HTTP options (timeouts, SSL options, logger) for parity.
- Adds plugin-specific options:
  - `async_http_connection_limit` (Integer)
  - `async_http_force_accept_encoding` (Boolean)
  - `async_http_body_warn_bytes` (Integer)
  - `async_http_max_buffer_bytes` (Integer, nil/0 disables)
  - `async_http_total_timeout` (Float, nil disables)
  - `async_http_idle_timeout` (Float, used as endpoint timeout when `http_open_timeout` is unset)
  - `async_http_header_timeout` (Float, nil disables; response header timeout)
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
  - `async_http_idle_timeout`
  - `http_proxy`
  - `ssl_verify_peer`
  - `ssl_ca_store`
  - `ssl_ca_bundle`
  - `ssl_ca_directory`
  - `ssl_cert`
  - `ssl_key`

This avoids connection reuse across incompatible TLS settings.

Cache injection (`async_http_client_cache`) is for explicit lifecycle control
and sharing. Use it when you want to:

- share a single pool across multiple AWS clients,
- close pooled sockets deterministically in tests or short‑lived processes,
- or tune cache behavior independently of AWS client construction.

Operational notes:

- The cache is per reactor; entries aren’t gated on cold-start. If multiple
  fibers hit a completely cold cache at once, they may build duplicate clients;
  extra clients are closed immediately.
- If you inject a cache, call `clear!`/`close!` during shutdown to close pooled
  connections. In cross‑reactor apps, call it inside each reactor to ensure
  clients are closed on their owning reactor.

### Retry Behavior

- Disable async-http retries (`retries: 0`).
- AWS SDK retry logic remains authoritative.

## Request Body Handling

- `async_http_streaming_uploads` controls streaming:
  - `:auto` streams only when the body is rewindable **and** size is known.
  - If size is unknown or body is non‑rewindable:
    - `:auto` buffers and warns.
    - `:force` streams but raises if retries are enabled.
  - `:off` buffers (Net::HTTP parity).
- Large buffered bodies emit a warning (configurable) and are capped by
  `async_http_max_buffer_bytes` (unless disabled).

## Event Streams

- Event stream operations bypass this handler and delegate to the SDK’s native
  HTTP/2 handler.
- Event streams require Async clients (Seahorse::Client::AsyncBase).

## Error Mapping

Map the following to `Seahorse::Client::NetworkingError`:

- `Async::TimeoutError`
- Socket errors: `SocketError`, `Errno::ECONNREFUSED`, `Errno::ECONNRESET`, `Errno::ETIMEDOUT`, etc.
- TLS errors: `OpenSSL::SSL::SSLError`
- DNS errors include host context in the message.

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

Ignored Net::HTTP options:

- `http_continue_timeout`
- `http_wire_trace`

## Timeout Semantics

- `http_open_timeout` applies to the connection phase.
- `http_read_timeout` is enforced per read chunk (idle timeout), not a total deadline.
- `async_http_header_timeout` applies to waiting for response headers.
- `async_http_total_timeout` is an overall deadline (upload + headers + body).

## Tests

### Unit Tests

- Handler request normalization (headers/body)
- Response streaming and content-length verification
- Error mapping
- Plugin registration and handler replacement

### Integration Tests

- `Async::HTTP::Server` (real network IO)
- Concurrency with multiple fibers
- Timeouts and response handling
- Docker-based tests for DynamoDB Local + MinIO
- Proxy tests with tinyproxy + toxiproxy

### Plugin Order Test

- Ensure `stub_responses: true` short-circuits without errors.
