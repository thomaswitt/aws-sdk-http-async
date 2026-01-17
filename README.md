# aws-sdk-http-async

Async HTTP handler plugin for the AWS SDK for Ruby, built on `async-http`.

Author: [Thomas Witt](https://thomas-witt.com)

## Requirements

- Ruby 3.4+
- aws-sdk-core >= 3.241.0
- async-http >= 0.94.0

No backwards compatibility is maintained for older Ruby/AWS SDK versions.

## Installation

Add to your Gemfile:

```ruby gem 'aws-sdk-http-async'```

## Activation / Usage

Requiring this gem auto‑registers the async handler **globally** for all AWS
service clients.

```ruby require 'aws-sdk-http-async'

client = Aws::DynamoDB::Client.new client.list_tables ```

This gem uses async-http when an Async reactor is present (Falcon provides
this). When no reactor is running, it falls back to Net::HTTP by default so CLI
tools, tests, and console sessions work without extra setup.

### Opt-out of auto-patching

If you want to load the handler without global patching:

```ruby require 'aws-sdk-http-async/core'

# Explicit plugin usage:
Aws::DynamoDB::Client.add_plugin(Async::Aws::HttpPlugin) # or client =
Aws::DynamoDB::Client.new(plugins: [Async::Aws::HttpPlugin]) ```

This registration is retroactive for already‑loaded AWS service clients. For
test isolation, you can undo it:

```ruby Async::Aws::Patcher.unpatch(:all) ```

Note: `unpatch(:all)` only removes the plugin from clients patched by the
patcher. If you define custom subclasses of AWS service clients, they will
inherit the plugin from their parent class and are not tracked for removal.

Note: patching scans existing classes at load time; require this gem early in
boot for best results.

## Fallback Behavior (No Reactor)

Fallback mode is configurable:

```ruby # Default: use Net::HTTP when no reactor exists
Aws.config[:async_http_fallback] = :net_http

# Run the async-http path inside a transient reactor
Aws.config[:async_http_fallback] = :sync

# Strict mode: raise if no reactor is running Aws.config[:async_http_fallback] =
:raise ```

You can also set `AWS_SDK_HTTP_ASYNC_FALLBACK=net_http|sync|raise`.

Event stream operations (e.g., Transcribe/Bedrock streaming) always require an
Async reactor and will raise `NoReactorError` when none is running.

### Sync vs Async

`Sync { }` is the recommended wrapper outside Falcon. It is more efficient than
`Async { }` and returns the block’s value directly.

## Advanced Configuration (Force Async Outside Falcon)

If you want the async-http path in rake/CLI/tests, wrap the code you run in
`Sync`:

```ruby require 'async'

Sync do client.list_tables end ```

To force async execution for all Rake tasks, add this line at the top of your
`Rakefile` (or directly in `bin/rake` before `require_relative
'../config/application'`):

```ruby require 'aws-sdk-http-async/rake' ```

## File Handle Limits (EMFILE)

If you see `Errno::EMFILE` or "Too many open files", raise your file descriptor
limit.

Recommended `bin/dev` snippet:

```sh if command -v ulimit >/dev/null; then current_limit=$(ulimit -n) if [
"$current_limit" -lt 4096 ]; then echo "Warning: ulimit -n is $current_limit.
Falcon/Propshaft may hit EMFILE. Trying to raise to 65536..." ulimit -n 65536 ||
echo "Warning: failed to raise ulimit. Set it manually (ulimit -n 65536) before
bin/dev." fi fi ```

## Configuration

Supported options (inherited from Net::HTTP plugin):

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

Plugin options:

- `async_http_connection_limit` (default: 10)
- `async_http_force_accept_encoding` (default: true)
- `async_http_body_warn_bytes` (default: 5_242_880)
- `async_http_max_buffer_bytes` (default: 5MB; raise if buffering exceeds this;
set to `nil` or `0` for unlimited)
- `async_http_total_timeout` (default: nil; total request deadline in seconds)
- `async_http_idle_timeout` (default: 30; idle socket timeout in seconds)
- `async_http_max_cached_clients` (default: 100; LRU eviction per reactor when
exceeded)
- `async_http_streaming_uploads` (default: :auto; values: :auto, :force, :off)
- `async_http_fallback` (default: :net_http; values: :net_http, :sync, :raise)
- `async_http_client_cache` (default: nil, injectable cache for lifecycle
control)

Example cache injection:

```ruby cache = Async::Aws::ClientCache.new client = Aws::DynamoDB::Client.new(
async_http_client_cache: cache) ```

The cache is capped by `async_http_max_cached_clients` using per‑reactor LRU
eviction. Set it to `nil` or `0` to disable eviction.

Cold‑start behavior: the cache is **not** gated. If multiple fibers hit a
totally cold cache for the same endpoint at the same time, they may build
duplicate clients; the extra client is closed immediately. This trades a tiny
one‑time overhead for simpler, more reliable concurrency.

Memory note: `async_http_max_buffer_bytes` is per request. For high‑concurrency
or memory‑constrained environments, consider lowering it further to avoid
aggregate spikes.

Unsupported (warning logged):

- `http_continue_timeout`
- `http_wire_trace`

## Limitations (V2)

- **Streaming uploads (`:auto`)** only stream rewindable bodies with known size.
Non‑rewindable or unknown‑size bodies are buffered for retry safety. Buffering
is capped by `async_http_max_buffer_bytes` (default: 5MB).
- **`:force` streaming** raises when retries are enabled for non‑rewindable
bodies.
- **Event streams** are delegated to the SDK's native HTTP/2 handler (Async
clients only).
- **Multipart uploads** stream when the body is rewindable and size is known
(File, StringIO, or explicit Content‑Length).
- **Duplicate headers** are merged with commas (Net::HTTP parity); Set‑Cookie
values are joined with "\n" to preserve cookie boundaries.

If you inject a cache, call `clear!`/`close!` during shutdown to close pooled
connections. For cross‑reactor apps, call it inside each reactor to ensure
clients are closed on their owning reactor. Calling `clear!` outside any reactor
will force‑close clients, which can interrupt in‑flight requests.

## SSL and certificates

If you pass file paths for `ssl_cert` / `ssl_key`, this gem loads them with
`File.read`, which is **blocking I/O**. For production, prefer pre‑loading at
boot and passing OpenSSL objects instead:

```ruby Aws::DynamoDB::Client.new( ssl_cert:
OpenSSL::X509::Certificate.new(File.read('/path/to/cert.pem')), ssl_key:
OpenSSL::PKey.read(File.read('/path/to/key.pem'))) ```

Tip: Reuse OpenSSL certificate/key objects across client instances to keep cache
keys stable.

## Timeout semantics

`http_open_timeout` applies to the connection phase. `http_read_timeout` is
enforced **per read chunk**, not as a total request deadline. For streaming
uploads, the request body is **not** wrapped by `http_read_timeout` to avoid
premature upload timeouts. A slow‑loris response that sends a byte before each
timeout can remain open indefinitely; add your own total deadline if needed. Use
`async_http_total_timeout` to enforce an overall deadline (upload + headers +
body).

## Proxy Support Notes

`http_proxy` accepts a full URL, e.g.:

```ruby Aws::DynamoDB::Client.new(http_proxy:
'http://user:pass@proxy.local:8080') ```

Limitations:

- Does **not** read `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` env vars.
- No PAC or proxy auto‑discovery.
- HTTPS uses CONNECT; proxy auth must be embedded in the URL.
- Proxy auth uses HTTP Basic based on `user:pass@` in the proxy URL.
- HTTPS proxies reuse the same SSL verification options as the target (CA
store/bundle/dir).
- All requests for the client go through the configured proxy.

## Timeout Semantics

- `http_open_timeout` is used for the initial request/connection phase.
- `http_read_timeout` applies per body read (idle timeout), not total request
time.

## WebMock Notes

WebMock works for unit tests, but connection pooling can keep sockets open. Use
`WebMock.disable_net_connect!(allow_localhost: true)` and isolate tests that
rely on real IO.

## Docker integration tests

Integration tests run against DynamoDB Local + MinIO, and proxy tests use
tinyproxy + toxiproxy. Start services with:

```bash
docker compose up -d
```

Run docker-tagged specs:

```bash
bundle exec rspec --tag docker
```

Stop services when finished:

```bash
docker compose down
```

## RSpec/rails test setup

No special setup is required. When no reactor is present, the gem uses Net::HTTP
by default. Use `Sync { }` if you want tests to exercise the async-http path.

## Next Steps

- Native event stream support on async-http HTTP/2
- Smarter proxy support (env vars, PAC)
- Optional total-request deadlines

See `md-docs/aws-sdk-http-async-rfc.md` for the full plan and roadmap.

## Development

```bash bundle install bundle exec rake formatter bundle exec rake rufo:check
bundle exec rubocop --format simple bundle exec rspec bin/ci ```

`bin/ci` includes a Brakeman step and skips it automatically when no Rails app
is present.
