Unreleased Changes
------------------

0.1.2 (2026-11-27)
------------------

* Issue - Maintenance release; the gem's code and runtime dependencies are unchanged from 0.1.1.

* Issue - Fix CI: the `minio/minio` image can no longer be pulled from Docker Hub. The S3 integration tests now run against RustFS (`rustfs/rustfs`), and every Docker image in `docker-compose.yml` is pinned to a release instead of `:latest`. Dependabot now updates those images.

* Issue - Test on Ruby 3.4 and 4.0 in CI, update `actions/checkout` to v7, and update development dependencies to their latest versions.

0.1.1 (2026-11-26)
------------------

* Issue - Fix a connection leak: Seahorse builds a new handler for every API call, and each handler created its own client cache, so every call inside a reactor built a new `Async::HTTP::Client`, opened a new connection and never closed it. Handlers now share the process-wide `Async::Aws::ClientCache.default` (thread-safe and fork-safe), which reuses one client per reactor, endpoint and config. `async_http_client_cache` still overrides it.

* Issue - Drop cache entries whose reactor has finished, without waiting for the reactor to be garbage collected, and never wait on a busy pool that no fiber is left to release.

* Issue - `ClientCache#clear!` now closes only the clients of the calling reactor and of finished reactors. It no longer closes the clients of other running reactors from the wrong thread, which could leave those reactors unable to finish. `clear!(timeout:)` is one deadline for all clients and closes the connections of in-flight requests once it expires, instead of waiting for them again.

* Issue - Fix calls through `http_proxy` in short-lived reactors: a `Sync { }` block and the `:sync` fallback no longer hang after the call, also when the proxy never answers `CONNECT`. A CONNECT tunnel now belongs to its reactor instead of the request that opened it, so cancelling that request no longer breaks the pooled tunnel for other calls. Idle tunnels are retired before the proxy socket timeout breaks them, and a tunnel the proxy dropped fails the request after `http_open_timeout` instead of leaving it waiting.

* Issue - Let a timeout the caller puts around a call (`task.with_timeout { client.get_item(...) }`) reach the caller as `Async::TimeoutError`. It was reported as a networking error, so the SDK sent the request again without a deadline. The transport's own timeouts (`http_read_timeout`, `async_http_header_timeout`, `async_http_total_timeout`, the wait for a free connection) raise `Async::Aws::TransportTimeoutError` internally and are still reported as `Seahorse::Client::NetworkingError`. The total timeout of a call no longer fails (and retries) another call made from its streaming block, and it ends once the response is complete instead of interrupting response listeners. In tests, a stub that raises a plain `Async::TimeoutError` (`to_raise(Async::TimeoutError)`) now counts as the caller's timeout; stub a network timeout with WebMock's `to_timeout`.

* Issue - Treat `async_http_connection_limit: 0` or a negative value as no limit, like `nil`, instead of waiting forever for a connection that is never opened. A Float is rounded up; a value that is not a number raises `ArgumentError`.

* Issue - Because connections are now reused, a call can fail with `Seahorse::Client::NetworkingError` (`EOFError`/`Errno::ECONNRESET`) when the server closes a kept-alive connection at the moment it is reused, as with the SDK's Net::HTTP pool. The SDK's default retries absorb it; clients with retries disabled (`max_attempts: 1`; `retry_limit: 0` only in the `legacy` retry mode) see the error.

* Issue - Trim the client cache back to `async_http_max_cached_clients` when a burst of in-flight clients is released, close a client that was cleared while a request was still using it once that request finishes, and keep the cache consistent when a task is cancelled during checkout, eviction or release.

* Issue - Keep TLS settings that differ in effect apart in the client cache: relative certificate paths under different working directories, and `ssl_verify_peer` values of different types.

* Issue - Because clients are now reused, `ssl_cert`, `ssl_key` and `ssl_ca_bundle` files are read once per cached client instead of on every call (as they already were with an injected `async_http_client_cache`). After rotating such a file in place, call `Async::Aws::ClientCache.default.clear!` inside each reactor, or restart, so new connections use the new file.

* Issue - Raise the promised `ArgumentError` for an empty `ssl_cert`/`ssl_key` even when a client for the same endpoint is already cached.

* Issue - Keep WebMock-stubbed calls working across reactors: closing a finished reactor's client no longer raises `WebMock::NetConnectNotAllowedError` out of the next call.

* Issue - Log the invalid `async_http_fallback` and `async_http_streaming_uploads` warnings once per process and value (for the first 100 distinct values) instead of once per call, and share one Net::HTTP fallback handler.

* Feature - Raise the default `async_http_connection_limit` from 10 to 50. The limit is now effective per reactor and endpoint; before, every call had its own pool unless a shared cache was injected (those setups go from 10 to 50). Set `Aws.config[:async_http_connection_limit]` to tune it; see "Connection limit" in the README for queueing and nested calls from streaming blocks.

* Feature - Honor `http_idle_timeout` (default 5 seconds): a pooled connection is closed once it has been unused for one to two times that long, instead of being reused indefinitely.

* Feature - Open the connections of a shared client concurrently, so one slow connect does not hold up other calls to the same endpoint. Calls beyond `async_http_connection_limit` wait their turn before a connection is requested; that wait is bounded by `async_http_header_timeout` and `async_http_total_timeout`, and a call that gives up fails with a networking error.

* Feature - Add `Async::Aws::ClientCache.default` and `Async::Aws::ClientCache#size`.

* Feature - Require `async-http >= 0.105.0` and `async >= 2.46.0`. Connection reuse relies on async-http's idle-connection check before a pooled HTTP/1 connection is reused and on `Async::Task#defer_cancel`; older versions are not supported.

0.1.0 (2026-01-19)
------------------

* Feature - Initial release of async-http handler plugin for aws-sdk-core.
