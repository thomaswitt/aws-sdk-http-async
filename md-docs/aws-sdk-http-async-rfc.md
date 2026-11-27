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

- Seahorse builds a new handler stack for every API call, so a cache owned by
  the handler would live for one call. Handlers therefore share the
  process-wide `Async::Aws::ClientCache.default` (like
  `Seahorse::Client::NetHttp::ConnectionPool` keeps a class-level registry).
  `Handler.new(client_cache:)` and `async_http_client_cache` override it. The
  handler's warn-once state and its Net::HTTP fallback handler are class-level
  for the same reason.
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

Cache injection (`async_http_client_cache`) replaces the default cache for that
AWS client. It is for explicit lifecycle control and isolation. Use it when you
want to:

- give some AWS clients a separate pool, isolated from the rest of the process,
- close pooled sockets deterministically in tests or short‑lived processes,
- or tune cache behavior independently of AWS client construction.

Operational notes:

- The cache is per reactor; entries aren’t gated on cold-start. If multiple
  fibers hit a completely cold cache at once, they may build duplicate clients;
  extra clients are closed immediately.
- An entry is dead once its reactor is collected **or closed**. A closing
  reactor stops the pool's gardener task, which closes the connections; the
  cache then drops the entry on the next insert or periodic sweep. A dead
  entry's client is closed only if its pool is idle: `Async::HTTP::Client#close`
  waits for the pool to drain, and nothing is left to release a busy
  connection of a finished reactor.
- Fork safety: the cache records its pid. In a forked child the inherited
  entries are dropped **without closing the clients**, because a close would
  write TLS close_notify / HTTP/2 GOAWAY onto sockets the parent still uses.
  The child only closes its own copies of the sockets, which writes nothing
  (on its first use of the cache; a child that never uses it keeps them):
  kept open, they would hold a connection open for the peer after the parent
  closed it. It finds them through a weak registry of every client that was
  built, which also covers a client that `clear!` took out of the cache and
  was still closing at the fork. Not covered: a socket that was still being
  connected (or in its TLS handshake) at the fork, which async-pool does not
  know yet; the child's copy stays open until it is garbage collected. The
  warn-once state is forgotten in a forked child too, so "once per process"
  holds for workers whose logs go elsewhere than the parent's.
- `async_http_connection_limit` defaults to 50 (per cached client, i.e. per
  reactor, endpoint and connection config). With one shared client the limit
  is finally effective, and 10 would queue the 32–64 call fan-outs that 0.1.0
  ran unbounded. A bounded pool can also starve nested calls made from
  streaming blocks while the outer responses hold every connection.
- async-pool opens one connection at a time by default and holds that guard
  even to hand out an idle connection, so with a shared client one slow connect
  would hold up every call to the endpoint. The pool therefore gets
  `concurrency: limit`. async-pool only keeps to its limit under concurrent
  creation while no more than `limit` callers use it at once, so each cache
  entry carries an `Async::Semaphore(limit)` that `with_client` acquires around
  the request. Calls beyond the limit wait at that semaphore, bounded by
  `async_http_header_timeout` (its own budget, separate from the wait for
  headers) and `async_http_total_timeout`; the handler maps that timeout to a
  networking error. Only public options of async-pool are used. `client_for`
  hands out the bare client without the semaphore, so concurrent first calls
  through it can briefly exceed the limit. The semaphore counts requests, so a
  connection still finishing an upload after an early response is not counted
  either.
- `http_idle_timeout` (SDK default 5 s) is honored through an async-pool
  `policy:` that runs in the pool's transient gardener task and retires
  connections unused for that long. async-pool expires nothing by itself, and
  its checkout probe only notices connections the peer closed, not flows a NAT
  gateway dropped silently, which otherwise feed every SDK retry another dead
  connection.
- Entries taken out of the cache are closed in a transient task that the
  caller waits for under `Task#defer_cancel`: a cancelled caller (even one
  cancelled twice) does not abandon them, and a caller's timeout is not
  swallowed by a close.
- `clear!` without a timeout waits for in-flight requests outside any rescue,
  so cancelling the caller or its own timeout ends the wait; what is left is
  closed without waiting, and an entry still in use is closed by its last
  request. The deadline of `clear!(timeout:)` uses its own exception class so
  that it cannot be confused with a caller's timeout.
- WebMock's client wrapper refuses to hand out its pool while real connections
  are disabled (with an error that is not a `StandardError`); such a client is
  treated as one whose pool cannot be inspected. It asks for the endpoint as a
  whole, so with a path-specific allowlist a real request can be in flight on
  a pool that is refused: `clear!(timeout:)` cannot close the connection under
  that request, and the client is closed when the request finishes.
- Ownership rule: a client is closed only by its own reactor, or after that
  reactor is gone. `clear!` therefore takes the calling reactor's entries plus
  dead ones and leaves other running reactors' entries cached, wherever it is
  called from. Closing a foreign pool stops its gardener task from the wrong
  thread, which async cannot do; the task is left non-transient and that
  reactor can no longer finish.
- `clear!(timeout:)` is one deadline for all clients. It waits for the pool
  that carries the requests, then retires the connections, because
  `Async::HTTP::Client#close` and `Async::Pool::Controller#close` both wait for
  the pool to drain.
- In-flight entries are never evicted, so the LRU bound is re-applied when an
  entry is released. A per-reactor flag (weak map) records that an insert could
  not evict enough, so releases do not scan the cache otherwise.
- An entry removed while in use (cleared, replaced) is closed again when its
  last request releases it: that request may have opened a connection after
  the first close.
- The in-flight counter is only changed by the owning reactor, so the release
  decrements it without the cache lock. Closes of entries already taken out of
  the cache run under `Task#defer_cancel`, so a cancelled request does not
  abandon them.
- The `:sync` fallback clears the entries of the reactor it created before the
  call returns (only `ClientCache` instances, and only when the handler created
  the reactor), so they do not stay in the cache.
- Proxy tunnels: async-http runs a CONNECT tunnel's writer as a non-transient
  child of whichever task opened it. Pooled, that tunnel would die with that
  request and would keep a short-lived reactor alive. `TunnelEndpoint` (the
  target endpoint of a proxied client) therefore opens every tunnel in a task
  of its own below a transient task at the reactor root. A caller that is
  stopped or times out while its tunnel is still opening takes that tunnel
  down; `ProxyClient#close` stops all tunnels and retires what is left in the
  proxy pool instead of waiting for it. A tunnel task cancels its remaining
  children when it ends, because a cancel that lands while async-http builds
  the tunnel's pipe would leave the pipe's transient tasks holding the proxy
  connection. The tunnel socket gets the endpoint's I/O timeout, and idle
  tunnels are retired after one to two thirds of the proxy socket timeout:
  that timeout ends an idle tunnel inside async-http without closing the
  connection on top of it.
- The handler records when the outcome of a request has been signalled. A
  timeout that fires afterwards can only have hit the release of the client
  (which may wait for the cache lock or for closes), and must not be signalled
  as an error: Seahorse would report a finished operation as failed and the
  SDK would retry it.
- `clear!` waits for the entry's in-flight count, not only for the pool: a
  request that is still opening its connection holds no pool resource yet.
- A client whose connections were closed under its requests is remembered
  (`force_closed?`), so the handler reports whatever the torn-down connection
  raises as a networking error.
- The cache key carries the identity of `Async::HTTP::Client`, because WebMock
  swaps that constant when it is enabled, and certificate paths as configured
  plus the working directory, without normalization: `..` after a symlink is
  not the lexical parent.
- The proxy pool's gardener (a transient task async-pool starts in whichever
  task opens a connection while the pool has none) is a child of a tunnel
  task. A tunnel task that ends therefore does not cancel it with its other
  children: a cancelled gardener waits for the whole proxy pool to drain and
  would keep the finished tunnel task in the tree, one more per tunnel
  turnover. It is recognised by async-pool's annotation (`... Gardener`);
  a regression example fails if that changes upstream.
- `Scheduler#stop` (SIGINT) cancels every direct child of the reactor, also
  the tunnels' parent task, but not requests that defer their cancel (what
  async-http's servers do around a request handler). The parent task therefore
  drains in its `ensure` like a pool's gardener does for direct connections:
  it waits for tunnels that are being opened, then `Controller#drain`s the
  target pool (idle tunnels close at once, a tunnel in use after its request).
  A second cancel, or `#close`, ends everything immediately. A parent task
  that is already cancelled gets no new tunnels.
- A process forked while a tunnel is open inherits the pipe's socket pair, so
  a plain close of the tunnel's end no longer reaches the pipe's writer while
  that process lives, and the tunnel would keep its proxy connection. The
  tunnel socket is therefore shut down when it is closed, only by the process
  that opened it.
- `clear!(timeout:)` closes the socket under a connection that is still in use
  before retiring it: closing the connection would otherwise wait for the
  stream's write lock, which a request blocked in an upload holds until the
  socket times out (several times under TLS). The interrupted request's
  `IOError` is delivered by the scheduler one turn later; a request that left
  its read in the same timer batch takes it at a yield inside `with_client`
  instead of in the caller's code.
- A tunnel that is stopped under its request (a second stop of the reactor,
  `Scheduler#close` after SIGTERM, `#close`) leaves the same late `IOError`:
  async-http closes the tunnel's socket from the tunnel's task, and the end of
  the stream wakes the request first. `TunnelEndpoint` counts such stops, and
  `with_client` takes the interrupt when the count changed during its request.
  A stop or timeout that arrives during that yield is held until the interrupt
  is taken; otherwise the `IOError` would replace it, or reach the task while
  it stops its children and end the reactor with the wrong exception.
- `async_http_connection_limit`: `nil`, zero, negative or infinite means no
  limit (no semaphore, unbounded connect concurrency); a Float is rounded up;
  anything that is not a number raises `ArgumentError`.
- Known limits, not addressed: stopping a batch of calls larger than the limit
  lets each stopped call hand its turn to a queued one before that is stopped
  as well; and io-endpoint closes a socket whose TLS handshake is cancelled
  only for a `StandardError`, so a request stopped mid-handshake leaves that
  socket to the GC (upstream). async-http's pipe half-closes a tunnel's
  socket only when the proxy ends the stream cleanly (FIN): a pooled tunnel
  the proxy reset while idle still looks usable and costs its next request
  one failed attempt. Turning the failed read into an end of stream was
  tried and dropped: a response body delimited by the end of the connection
  would then end cleanly in the middle of a reset download. Two upstream
  behaviours can still lose a timeout, as in 0.1.0: io-stream's
  `Generic#close` flushes under a bare `rescue`, so a caller's timeout raised
  while async-http closes the connection of an upload that is blocked on a
  peer that stopped reading (after a transport deadline fired) is discarded,
  and the close itself lasts until the socket timeout; and io-endpoint's
  `HostEndpoint#connect` takes a timeout raised during the connect to one
  address for a failure of that address and goes on with the next one.
- The cache key is an Array of the values, with certificate/CA paths made
  absolute, so settings that differ in effect or in type never share a
  client and no value can run into the next one.
- `async_http_total_timeout` is raised as a copy of a `TransportTimeoutError`
  instance that carries the handler invocation as its scope. A call made from
  a streaming block of that invocation sees the outer deadline as a foreign
  timeout and lets it through, instead of reporting a network error of its
  own that the SDK would retry. The deadline is cancelled once the response
  is complete, before Seahorse runs its `on_done` listeners: fired inside a
  listener it would turn a completed request into a retried one. It is also
  cancelled when the request ends in any other way, before its cleanup:
  giving up the turn switches to the call that waits for it, and a deadline
  due in that pass of the event loop would replace a stop or timeout of the
  caller and be retried as a network error.
- Only errors raised while the connection is used are reported as network
  errors after a forced close; an error of a response listener stays what it
  is, unless it is of a network error class itself (`IOError`,
  `SystemCallError`, ...): that one is reported as a networking error, as by
  the SDK's Net::HTTP handler.
- The total deadline is also cancelled before an error is signalled (also the
  error of a call that timed out waiting its turn), so that it does not cut
  off the `on_error` listeners. A call keeps its turn until
  its listeners have run, as the Net::HTTP handler keeps its session: a
  listener that calls the same endpoint needs a second turn.
- Known limit: a tunnel that is stopped under its request (second stop of the
  reactor, `#close`) ends the stream like the peer would, so a response that
  is delimited by the end of the connection (no `content-length`, not
  chunked; AWS services do not send these) ends there as if complete. Failing
  every request of the client whenever one of its tunnels is stopped was
  tried and dropped: stopping a call while its tunnel is handed over would
  fail, and retry, an unrelated call that had succeeded.
- The key and the client read the working directory and the client class
  (WebMock swaps `Async::HTTP::Client`) at different moments. After a build
  the key is computed again; if it changed, the client is closed and built
  once more, so no client is cached under a key that names other settings.
- Closes of entries taken out of the cache are waited for, except for a
  client whose pool is busy although no request counts as using it (an
  upload that goes on after an early response): that close waits for the
  upload and is left to its transient task, so that a call to another
  endpoint that evicted the client is not held up.
- Strings in the cache key are frozen copies, so a caller that changes a
  config string in place cannot change the hash of a stored key. Relative
  `ssl_ca_bundle`/`ssl_ca_directory` paths are handed to OpenSSL as absolute
  paths: OpenSSL reads them when the context is first used, which can be
  after the working directory changed.
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

- `Async::Aws::TransportTimeoutError` (the transport's own deadlines:
  `http_read_timeout`, `async_http_header_timeout`, `async_http_total_timeout`,
  the wait for a free connection). Any other `Async::TimeoutError` is the
  caller's own `with_timeout` around the call and is re-raised untouched, as
  the SDK's Net::HTTP handler does; mapping it to a networking error made the
  SDK retry without the caller's deadline. WebMock's `to_timeout` (a plain
  `Async::TimeoutError` with its own message) still counts as a network
  timeout; `to_raise(Async::TimeoutError)` cannot be told from a caller's
  timeout and is re-raised.
- Socket errors: `SocketError`, `Errno::ECONNREFUSED`, `Errno::ECONNRESET`, `Errno::ETIMEDOUT`, etc.
- TLS errors: `OpenSSL::SSL::SSLError`
- DNS errors include host context in the message.

## Options Parity

Supported:

- `http_open_timeout`
- `http_read_timeout`
- `http_idle_timeout` (unused pooled connections are closed after this long)
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
