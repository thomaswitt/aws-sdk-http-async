# aws-sdk-http-async

Async HTTP handler plugin for the AWS SDK for Ruby, built on `async-http`.

Why:

The AWS SDK’s default HTTP transport uses Net::HTTP wrapped in a connection
pool. Contrary to what you might expect, Net::HTTP itself is fiber-friendly in
Ruby 3.0+—the fiber scheduler hooks into blocking I/O and yields to other fibers
automatically.

The problem is that the SDK's Net::HTTP transport is synchronous end-to-end and
relies on implicit scheduler hooks in Net::HTTP, OpenSSL, and DNS resolution. In
practice, these hooks don't yield reliably, so the single reactor thread gets
blocked often enough that all fibers serialize instead of overlapping.

For high-throughput AWS APIs (DynamoDB, STS, IAM, Lambda), we need an
async-compatible transport to restore concurrent I/O without threads.

More background in [my blog post](https://thomas-witt.com/blog/aws-sdk-http-async/).

## Installation

This gem uses async-http when an Async reactor is present (Falcon provides
this). When no reactor is running, it falls back to Net::HTTP by default so CLI
tools, tests, and console sessions work without extra setup.

Add to your Gemfile:

```ruby
gem 'aws-sdk-http-async'
```

That's it.

### Recommended AWS Client Initialization

Create AWS clients once per process and reuse them (singleton or dependency
injection). This keeps connection pooling effective and avoids rebuilding
clients for every request.

#### Singleton Repository Pattern

```ruby
require 'async/semaphore'
require 'async/task'

INIT_SEMAPHORE = Async::Semaphore.new(1)
INIT_MUTEX = Mutex.new

def client
  return @client if defined?(@client) && @client

  if Async::Task.current?
    INIT_SEMAPHORE.acquire do
      return @client if defined?(@client) && @client
      @client = Aws::DynamoDB::Client.new
    end
  else
    INIT_MUTEX.synchronize do
      return @client if defined?(@client) && @client
      @client = Aws::DynamoDB::Client.new
    end
  end

  @client
end
```

Initializer shortcut:

```ruby
# config/initializers/aws_clients.rb
DDB = Database::DynamodbRepository.instance unless defined?(DDB)
# or Rails.application.config.x.ddb = Database::DynamodbRepository.instance
```

Usage:

```ruby
DDB.client.list_tables
```

#### Dependency Injection Pattern

Alternative dependency injection example (ideal for tests or per‑context configs):

```ruby
class WorldDominationService
  def initialize(dynamodb:)
    @dynamodb = dynamodb
  end

  def list_tables
    @dynamodb.list_tables
  end
end

service = WorldDominationService.new(dynamodb: Aws::DynamoDB::Client.new)
# or Rails.application.config.x.dynamodb_client = Aws::DynamoDB::Client.new
```

### Advanced Configuration (Force Async Outside Falcon)

To force async execution for all Rake tasks, add this line at the very top of
your `Rakefile`, before any task definitions or Rails app loading:

```ruby
require 'aws-sdk-http-async/rake'
```

### File Handle Limits (EMFILE)

If you see `Errno::EMFILE` or "Too many open files", raise your file descriptor
limit. This commonly occurs when processing many records with concurrent AWS
calls, especially when combined with Redis, OpenSearch, or database connections.

Each AWS request can hold open multiple file descriptors (TCP sockets, SSL
contexts). Combined with Redis pub/sub, OpenSearch indexing, or database
connections, you can quickly exceed the default limit (256 on macOS, 1024 on
many Linux distros). Verify via `ulimit -n`.

#### Recommended Dev Env: Add to Your Shell Profile

Add to your `~/.zshrc` or `~/.bashrc`:

```sh
ulimit -n 65536 2>/dev/null || ulimit -n 4096 2>/dev/null || true
```

This applies to all terminal sessions (Falcon, rake tasks, console). Re-open
your terminal or run `source ~/.zshrc` for changes to take effect.

#### For Falcon/bin/dev

If you prefer per-project configuration, add to your `bin/dev`:

```sh
if command -v ulimit >/dev/null; then
  current_limit=$(ulimit -n)
  if [ "$current_limit" -lt 4096 ]; then
    echo "Warning: ulimit -n is $current_limit. Falcon/Propshaft may hit EMFILE. Trying to raise to 65536..."
    ulimit -n 65536 || echo "Warning: failed to raise ulimit. Set it manually (ulimit -n 65536) before bin/dev."
  fi
fi
```

#### For Docker

Add `ULIMIT_NOFILE=65536` to your environment and include in
`bin/docker-entrypoint`:

```sh
if command -v ulimit >/dev/null; then
  ulimit -n "${ULIMIT_NOFILE:-65536}" || echo "Warning: unable to raise ulimit -n"
fi
```

## Configuration

### Fallback Behavior (No Reactor)

Fallback mode is configurable:

```ruby
# Default: use Net::HTTP when no reactor exists
Aws.config[:async_http_fallback] = :net_http

# Run the async-http path inside a transient reactor
Aws.config[:async_http_fallback] = :sync

# Strict mode: raise if no reactor is running
Aws.config[:async_http_fallback] = :raise
```

You can also ENV set `AWS_SDK_HTTP_ASYNC_FALLBACK=net_http|sync|raise`.

Event stream operations (e.g., Transcribe/Bedrock streaming) always require an
Async reactor and will raise `NoReactorError` when none is running.

### Sync vs Async

If you want the async-http path in rake/CLI/tests, wrap the code you run in
`Sync`:

```ruby
Sync do
  client = Aws::DynamoDB::Client.new
  client.list_tables
end
```

`Sync { }` is the recommended wrapper outside Falcon. It is more efficient than
`Async { }` and returns the block’s value directly.

### Configuration options inherited from Net::HTTP plugin

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

Ignored Net::HTTP options:

- `http_continue_timeout`
- `http_wire_trace`

#### SSL and certificates

If you pass file paths for `ssl_cert` / `ssl_key`, this gem loads them with
`File.read`, which is **blocking I/O**. For production, prefer pre‑loading at
boot and passing OpenSSL objects instead:

```ruby
Aws::DynamoDB::Client.new(
  ssl_cert: OpenSSL::X509::Certificate.new(File.read('/path/to/cert.pem')),
  ssl_key: OpenSSL::PKey.read(File.read('/path/to/key.pem'))
)
```

Tip: Reuse OpenSSL certificate/key objects across client instances to keep cache keys stable.

#### Proxy Support Notes

`http_proxy` accepts a full URL, e.g.:

```ruby
Aws::DynamoDB::Client.new(http_proxy: 'http://user:pass@proxy.local:8080')
```

Limitations:

- Does **not** read `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` env vars.
- No PAC or proxy auto‑discovery.
- HTTPS uses CONNECT; proxy auth must be embedded in the URL.
- Proxy auth uses HTTP Basic based on `user:pass@` in the proxy URL.
- HTTPS proxies reuse the same SSL verification options as the target (CA
store/bundle/dir).
- All requests for the client go through the configured proxy.

### Plugin options

- `async_http_connection_limit` (default: 10)
- `async_http_force_accept_encoding` (default: true)
- `async_http_body_warn_bytes` (default: 5_242_880)
- `async_http_max_buffer_bytes` (default: 5MB; raise if buffering exceeds this; set to `nil` or `0` for unlimited)
- `async_http_header_timeout` (default: nil; optional timeout for response headers, applied even for streaming request bodies)
- `async_http_total_timeout` (default: nil; total request deadline in seconds)
- `async_http_idle_timeout` (default: 30; used as endpoint timeout when `http_open_timeout` is not set; changing this at runtime requires clearing the client cache)
- `async_http_max_cached_clients` (default: 100; LRU eviction per reactor when exceeded)
- `async_http_streaming_uploads` (default: :auto; values: :auto, :force, :off)
- `async_http_fallback` (default: :net_http; values: :net_http, :sync, :raise)
- `async_http_client_cache` (default: nil, injectable cache for lifecycle control)

### Timeout semantics

`http_open_timeout` applies to the connection phase. `http_read_timeout` is
enforced **per read chunk**, not as a total request deadline. For streaming
uploads, the request body is **not** wrapped by `http_read_timeout` to avoid
premature upload timeouts. Use `async_http_header_timeout` if you want a timeout
for waiting on response headers even when the request body is streaming. A
slow‑loris response that sends a byte before each timeout can remain open
indefinitely; add your own total deadline if needed. Use
`async_http_total_timeout` to enforce an overall deadline (upload + headers +
body).

### Opt-out of auto-patching

If you want to load the handler without global patching:

```ruby
require 'aws-sdk-http-async/core'

# Explicit plugin usage:
Aws::DynamoDB::Client.add_plugin(Async::Aws::HttpPlugin)
# or client = Aws::DynamoDB::Client.new(plugins: [Async::Aws::HttpPlugin])
```

If you explicitly add the plugin, only the clients you configure are affected.

For the global patcher (default auto‑patch), registration is retroactive for
already‑loaded AWS service clients. For test isolation, you can undo it:

```ruby
Async::Aws::Patcher.unpatch(:all)
```

Note: `unpatch(:all)` only removes the plugin from clients patched by the
patcher. If you define custom subclasses of AWS service clients, they will
inherit the plugin from their parent class and are not tracked for removal.

Note: patching scans existing classes at load time; require this gem early in
boot for best results.

## Cache injection

```ruby
  cache = Async::Aws::ClientCache.new
  client = Aws::DynamoDB::Client.new(async_http_client_cache: cache)
```

Use cache injection only when you want to **control or share** the async‑http
connection pool yourself. It caches **async‑http client instances** (connection
pools), not AWS responses. **Most apps should ignore this** and let the gem
manage its own internal cache. Inject a cache only when you need one of these:

- **Deterministic shutdown** in tests or short‑lived scripts (so servers don’t
  hang waiting for pooled connections to drain).
- **One shared pool across many AWS clients** to reduce sockets and improve
  reuse.
- **Custom lifecycle hooks** (e.g., you want to clear the pool on reload).

If you inject a cache, call `clear!`/`close!` during shutdown to close pooled
connections. For cross‑reactor apps, call it inside each reactor to ensure
clients are closed on their owning reactor. Calling `clear!` outside any
reactor will force‑close clients, which can interrupt in‑flight requests.

The cache is capped by `async_http_max_cached_clients` using per‑reactor LRU
eviction. Set it to `nil` or `0` to disable eviction.

Cold‑start behavior: the cache is **not** gated. If multiple fibers hit a
totally cold cache for the same endpoint at the same time, they may build
duplicate clients; the extra client is closed immediately. This trades a tiny
one‑time overhead for simpler, more reliable concurrency.

Memory note: `async_http_max_buffer_bytes` is per request. For high‑concurrency
or memory‑constrained environments, consider lowering it further to avoid
aggregate spikes.

## Test Notes

WebMock works for unit tests, but connection pooling can keep sockets open. Use
`WebMock.disable_net_connect!(allow_localhost: true)` and isolate tests that
rely on real IO.

### Docker integration tests

RSpec Integration tests run against DynamoDB Local + MinIO,
and proxy tests use tinyproxy + toxiproxy.

### RSpec/rails test setup

By default, when no Async reactor is present, the gem falls back to Net::HTTP.
To exercise the async-http code path in tests, use one of these approaches:

#### Option A: Global `around` hook (Recommended)

Tag specs with `:async` and wrap them in a reactor:

```ruby
# spec/support/async.rb
RSpec.configure do |config|
  config.around(:each, :async) do |example|
    Sync { example.run }
  end
end
```

```ruby
# spec/integration/dynamodb_spec.rb
RSpec.describe 'DynamoDB operations', :async do
  let(:client) { Aws::DynamoDB::Client.new }

  it 'lists tables' do
    expect(client.list_tables.table_names).to be_an(Array)
  end
end
```

#### Option B: Set fallback to `:sync`

Force all AWS calls to use async-http inside a transient reactor:

```ruby
# spec/spec_helper.rb
Aws.config[:async_http_fallback] = :sync
```

Or via environment variable:

```bash
AWS_SDK_HTTP_ASYNC_FALLBACK=sync bundle exec rspec
```

#### Option C: Wrap individual tests

For selective async testing:

```ruby
it 'performs async operation' do
  Sync do
    client = Aws::DynamoDB::Client.new
    client.list_tables
  end
end
```

#### Cache injection for deterministic cleanup

Inject a cache to control connection lifecycle and avoid test hangs:

```ruby
RSpec.describe 'AWS operations', :async do
  let(:cache) { Async::Aws::ClientCache.new }
  let(:client) do
    Aws::DynamoDB::Client.new(
      async_http_client_cache: cache,
      async_http_fallback: :raise
    )
  end

  after { cache.close! }

  it 'lists tables' do
    expect(client.list_tables.table_names).to be_an(Array)
  end
end
```

#### Testing concurrent fiber execution

```ruby
it 'handles parallel calls', :async do
  results = Async do |task|
    5.times.map do
      task.async { client.list_tables.table_names }
    end.map(&:wait)
  end.wait

  expect(results).to all(be_an(Array))
end
```

The gem also supplies a simple `async-rake` script for testing async behavior in Rake

## Current Limitations

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
and Set‑Cookie2 values are joined with "\n" to preserve cookie boundaries.

### Next Steps

- Native event stream support on async-http HTTP/2 (non‑trivial; SDK’s native handler already works with HTTP/2)
- Smarter proxy support (env vars, PAC)

See `md-docs/aws-sdk-http-async-rfc.md` for current design notes.

## Development

```bash
bundle install
# Do your development stuff.
bundle exec rake formatter
bundle exec rspec
bin/ci
```

### Release (maintainers)

Quick reference:

```bash
VERSION=0.1.0

# Build + push (after version bump + changelog)
gem build aws-sdk-http-async.gemspec
gem push "aws-sdk-http-async-${VERSION}.gem"

# Tag + push
git tag -a "v${VERSION}" -m "Release v${VERSION}"
git push origin main --tags
```

GitHub release (optional, via `gh`):

```bash
gh release create "v${VERSION}" \
  --title "v${VERSION}" \
  --generate-notes \
  "aws-sdk-http-async-${VERSION}.gem"
```

### Requirements

- Ruby 3.4+
- aws-sdk-core >= 3.241.0
- async-http >= 0.94.0

No backwards compatibility is maintained for older Ruby/AWS SDK versions.

# Author

Author: [Thomas Witt](https://thomas-witt.com)
Github: <https://github.com/thomaswitt/aws-sdk-http-async>
