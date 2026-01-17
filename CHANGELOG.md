Unreleased Changes
------------------
* Feature - Add Net::HTTP fallback for reactorless contexts with configurable modes (:net_http, :sync, :raise) and ENV override.
* Docs - Document fallback behavior, Sync vs Async guidance, and optional async setup for rake/CLI/tests.
* Fix - Join Set-Cookie headers with "\n" to preserve cookie boundaries.
* Fix - Improve retry guard error message for non-rewindable streaming bodies.
* Fix - Set default async_http_max_buffer_bytes to 50MB for safety.

0.1.0 (2026-01-17)
------------------

* Feature - Initial release of async-http handler plugin for aws-sdk-core.
* Breaking - Async reactor is required; reactorless mode removed.
* Breaking - Auto‑register async handler globally for all AWS clients.
* Feature - Add cache injection, body buffer warning, and accept-encoding configurability.
* Fix - Scope cache by reactor and include timeout/limit in cache key.
* Feature - Add async-rake wrapper and optional rake patch.
* Feature - Streaming uploads with :auto/:force/:off safety gates and retry guard.
* Feature - Event stream operations delegate to the SDK handler.
* Feature - ssl_ca_store and http_proxy support.
* Fix - Patcher unpatch rescans existing clients; NoReactorError required by component files.
* Fix - Enable TLS hostname verification when ssl_verify_peer is true.
* Fix - Proxy auth via userinfo and HTTPS proxy TLS context.
* Fix - Streaming body close/buffered support and nil-safe buffering.
* Fix - Add HTTP/2 + additional network errors for retry classification.
* Fix - Proxy auth decoding and stricter mTLS validation.
* Fix - Per-read timeout semantics and proxy endpoint timeout.
* Feature - ClientCache clear! timeout option.
* Feature - Add async_http_max_buffer_bytes hard cap for buffered bodies.
* Fix - Normalize headers case and guard empty-string EOF reads.
* Fix - Reduce client cache lock contention and improve unpatch tracking.
* Fix - Raise unexpected errors instead of masking with StandardError rescue.
