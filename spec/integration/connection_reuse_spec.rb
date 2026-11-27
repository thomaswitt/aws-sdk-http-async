require_relative '../spec_helper'

# Regression: Seahorse builds a new handler stack for every API call. In 0.1.0
# each handler created its own ClientCache, so every call built a new
# Async::HTTP::Client, opened a new connection and never closed it.
RSpec.describe 'Async::Aws connection reuse' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  class TrackingServer < Async::HTTP::Server
    attr_reader :connection_count, :open_connections, :in_flight, :max_in_flight

    def initialize(app, endpoint)
      @connection_count = 0
      @open_connections = 0
      @in_flight = 0
      @max_in_flight = 0
      @peers = []
      super(->(request) { track(request, app) }, endpoint)
    end

    def accept(peer, address, task: Async::Task.current)
      @connection_count += 1
      @open_connections += 1
      @peers << peer
      super
    ensure
      @open_connections -= 1
      @peers.delete(peer)
    end

    # Closes every open connection from the server side, like an idle timeout.
    def drop_connections
      @peers.dup.each(&:close)
    end

    private

    def track(request, app)
      @in_flight += 1
      @max_in_flight = [@max_in_flight, @in_flight].max
      request.read
      app.call(request)
    ensure
      @in_flight -= 1
    end
  end

  # Holds server responses until the example opens it, so examples control
  # overlap and timeouts without relying on sleeps.
  class ResponseGate
    def initialize
      @open = false
      @condition = Async::Condition.new
    end

    def wait
      @condition.wait until @open
    end

    def open!
      @open = true
      @condition.signal
    end
  end

  LIST_TABLES = lambda do |_request|
    Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, ['{"TableNames":[]}']]
  end

  def build_server(app, bind: '127.0.0.1')
    endpoint = Async::HTTP::Endpoint.parse("http://#{bind}:#{SpecHelper.available_port}")
    [endpoint, TrackingServer.new(app, endpoint)]
  end

  # Runs the server and the example inside one reactor.
  def with_server(app = LIST_TABLES)
    endpoint, server = build_server(app)

    Sync do |task|
      server_task = server.run
      task.sleep(0.05)
      yield endpoint, server
    ensure
      Async::Aws::ClientCache.default.clear!(timeout: 1)
      server_task&.stop
    end
  end

  # Runs the server on its own thread, so the example itself has no reactor.
  def with_threaded_server(app = LIST_TABLES, bind: '127.0.0.1')
    endpoint, server = build_server(app, bind:)
    ready = Queue.new
    stop = Queue.new
    thread = Thread.new do
      Sync do |task|
        server_task = server.run
        task.sleep(0.05)
        ready << true
        stop.pop
        server_task.stop
      end
    end

    ready.pop
    yield endpoint, server
  ensure
    stop << true
    thread&.join
  end

  def client_options(endpoint, **options)
    {
      endpoint: endpoint.respond_to?(:url) ? endpoint.url.to_s : endpoint,
      region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'),
      retry_limit: 0, # legacy retry mode
      max_attempts: 1, # standard/adaptive retry mode (the default in newer SDKs)
      **options,
    }
  end

  def dynamodb(endpoint, **)
    Aws::DynamoDB::Client.new(**client_options(endpoint, **))
  end

  # @return [Array<Async::HTTP::Client>] every client built from now on
  def track_http_clients
    built = []
    allow(Async::HTTP::Client).to receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { built << it }
    end
    built
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_until(timeout: 2)
    deadline = monotonic + timeout
    until yield
      raise 'condition not met in time' if monotonic > deadline

      sleep 0.01
    end
  end

  let(:default_cache) { Async::Aws::ClientCache.default }

  it 'builds one Async::HTTP::Client for all calls of a reactor and honors the connection limit' do
    # The server answers only once three requests overlap, so the burst below
    # needs all three connections, and a fourth would show in max_in_flight.
    gate = ResponseGate.new
    arrived = 0
    app = lambda do |request|
      arrived += 1
      gate.open! if arrived == 3
      gate.wait
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      built = track_http_clients
      client = dynamodb(endpoint, async_http_connection_limit: 3)

      Async::Task.current.with_timeout(5) do
        20.times.map { Async { client.list_tables.table_names } }.each(&:wait)
      end
      5.times { client.list_tables }

      # A second Aws client with the same config shares the cached HTTP client.
      dynamodb(endpoint, async_http_connection_limit: 3).list_tables

      expect(built.size).to eq(1)
      expect(default_cache.size).to eq(1)
      expect(server.connection_count).to eq(3)
      expect(server.max_in_flight).to eq(3)
    ensure
      gate.open!
    end
  end

  it 'gives a second reactor its own client and closes it when that reactor finishes' do
    with_server do |endpoint, server|
      built = track_http_clients
      client = dynamodb(endpoint)

      client.list_tables
      Thread.new { Sync { 3.times { client.list_tables } } }.join
      client.list_tables

      expect(built.size).to eq(2)
      expect(server.connection_count).to eq(2)

      # The finished reactor closed its pool; only this reactor's connection is left.
      wait_until { server.open_connections == 1 }
      expect(server.open_connections).to eq(1)
      expect(built.last.pool).to be_empty

      # The next insert drops the entry of the finished reactor.
      dynamodb(endpoint, http_open_timeout: 7).list_tables
      expect(default_cache.size).to eq(2)
    end
  end

  it 'closes a client when its entry is evicted' do
    with_server do |endpoint, server|
      built = track_http_clients
      first = dynamodb(endpoint, async_http_max_cached_clients: 1, http_open_timeout: 5)
      second = dynamodb(endpoint, async_http_max_cached_clients: 1, http_open_timeout: 6)

      first.list_tables
      second.list_tables

      expect(built.size).to eq(2)
      expect(default_cache.size).to eq(1)
      expect(built.first.pool).to be_empty
      wait_until { server.open_connections == 1 }
      expect(server.open_connections).to eq(1)
    end
  end

  it 'prefers async_http_client_cache over the default cache' do
    with_server do |endpoint, server|
      built = track_http_clients
      custom = Async::Aws::ClientCache.new
      client = dynamodb(endpoint, async_http_client_cache: custom)

      3.times { client.list_tables }

      expect(built.size).to eq(1)
      expect(custom.size).to eq(1)
      expect(default_cache.size).to eq(0)
      expect(server.connection_count).to eq(1)
    ensure
      custom.clear!(timeout: 1)
    end
  end

  it 'does not make other calls wait for a connection that one call is still opening' do
    with_server do |endpoint, server|
      # The first new connection stalls in its setup, like a lost SYN or a slow TLS handshake.
      gate = ResponseGate.new
      stalling = false
      allow(Async::HTTP::Endpoint).to receive(:parse).and_wrap_original do |parse, *args, **options|
        parse.call(*args, **options).tap do |target|
          allow(target).to receive(:connect).and_wrap_original do |connect, *connect_args, &block|
            unless stalling
              stalling = true
              gate.wait
            end
            connect.call(*connect_args, &block)
          end
        end
      end
      client = dynamodb(endpoint)
      slow = Async { client.list_tables.table_names }
      wait_until { stalling }

      # The next call opens its own connection and the one after reuses it;
      # neither waits for the stalled connect.
      Async::Task.current.with_timeout(2) do
        2.times { expect(client.list_tables.table_names).to eq([]) }
      end
      expect(server.connection_count).to eq(1)

      gate.open!
      expect(slow.wait).to eq([])
      expect(server.connection_count).to eq(2)
    ensure
      gate&.open!
    end
  end

  it 'does not reuse connections that sat idle for longer than http_idle_timeout' do
    flows = Set.new.compare_by_identity # one server task per HTTP/1 connection
    dropped = nil
    released = Async::Condition.new
    app = lambda do |request|
      flows << Async::Task.current
      sleep 0.05 # the burst below overlaps, so it needs one connection per call
      # A silently dropped flow: the request is never answered, nothing is closed.
      released.wait if dropped&.include?(Async::Task.current)
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      client = dynamodb(endpoint, http_idle_timeout: 0.2, http_open_timeout: 0.5)

      6.times.map { Async { client.list_tables } }.each(&:wait)
      expect(server.connection_count).to eq(6)

      sleep 0.6 # quiet period, longer than 2 * http_idle_timeout
      dropped = flows.dup

      # A single attempt: it must not be handed one of the dead connections.
      expect(client.list_tables.table_names).to eq([])
      expect(server.connection_count).to eq(7)
      expect(server.open_connections).to eq(1)
    ensure
      released.signal # lets the server tasks of the dropped flows finish
    end
  end

  it 'keeps a connection that is in regular use' do
    with_server do |endpoint, server|
      client = dynamodb(endpoint, http_idle_timeout: 0.1)

      25.times do
        client.list_tables
        sleep 0.02
      end

      expect(server.connection_count).to eq(1)
    end
  end

  { async_http_header_timeout: 0.2, async_http_total_timeout: 0.2 }.each do |option, seconds|
    it "fails a call that waits its turn for longer than #{option}" do
      gate = ResponseGate.new
      app = lambda do |request|
        gate.wait
        LIST_TABLES.call(request)
      end

      with_server(app) do |endpoint, server|
        holder = Async { dynamodb(endpoint, async_http_connection_limit: 1).list_tables.table_names }
        wait_until { server.in_flight == 1 }
        started = monotonic

        # Same endpoint and limit, so the same cached client: its one connection is taken.
        waiting = dynamodb(endpoint, async_http_connection_limit: 1, option => seconds)
        expect { waiting.list_tables }.to raise_error(Seahorse::Client::NetworkingError)
        expect(monotonic - started).to be < 2
        expect(server.connection_count).to eq(1)

        gate.open!
        expect(holder.wait).to eq([])
      ensure
        gate.open!
      end
    end
  end

  it 'replaces a pooled connection that the server closed while idle' do
    with_server do |endpoint, server|
      built = track_http_clients
      client = dynamodb(endpoint)

      client.list_tables
      server.drop_connections
      wait_until { server.open_connections.zero? }

      # A single attempt (no SDK retry): the pool notices the dead connection on checkout.
      expect(client.list_tables.table_names).to eq([])
      expect(built.size).to eq(1)
      expect(server.connection_count).to eq(2)
    end
  end

  it 'does not reuse a connection whose request timed out' do
    gate = ResponseGate.new
    app = lambda do |request|
      gate.wait
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      built = track_http_clients
      # One connection only: a slot still held by the timed-out request would block the next call.
      client = dynamodb(endpoint, async_http_header_timeout: 0.2, async_http_connection_limit: 1)

      expect { client.list_tables }.to raise_error(Seahorse::Client::NetworkingError)
      gate.open!
      expect(client.list_tables.table_names).to eq([])

      expect(built.size).to eq(1)
      expect(server.connection_count).to eq(2)
    ensure
      gate.open!
    end
  end

  it 'does not reuse a connection whose response body timed out' do
    stalled = []
    stall = true
    app = lambda do |request|
      next LIST_TABLES.call(request) unless stall

      body = Protocol::HTTP::Body::Writable.new
      body.write('{"TableNames":')
      stalled << body
      Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, body]
    end

    with_server(app) do |endpoint, server|
      built = track_http_clients
      client = dynamodb(endpoint, http_read_timeout: 0.2, async_http_connection_limit: 1)

      expect { client.list_tables }.to raise_error(Seahorse::Client::NetworkingError)
      stall = false
      # With the connection still held, this call would wait for the only slot forever.
      Async::Task.current.with_timeout(5) { expect(client.list_tables.table_names).to eq([]) }

      expect(built.size).to eq(1)
      expect(server.connection_count).to eq(2)
    ensure
      # Let the server finish the stalled response, so its task can stop.
      stalled.each(&:close_write)
    end
  end

  it 'closes connections and drops entries of transient reactors in :sync fallback mode' do
    with_threaded_server do |endpoint, server|
      client = dynamodb(endpoint, async_http_fallback: :sync)

      5.times { client.list_tables }

      expect(server.connection_count).to eq(5)
      wait_until { server.open_connections.zero? }
      expect(server.open_connections).to eq(0)
      # Each call closes its transient reactor's client before returning.
      expect(default_cache.size).to eq(0)
    end
  end

  it 'answers a call without a reactor through the shared Net::HTTP handler' do
    with_threaded_server do |endpoint, server|
      built = track_http_clients
      allow(Async::Aws::Handler.net_http_handler).to receive(:call).and_call_original

      expect(dynamodb(endpoint).list_tables.table_names).to eq([])

      expect(Async::Aws::Handler.net_http_handler).to have_received(:call).once
      expect(built).to be_empty
      expect(default_cache.size).to eq(0)
      expect(server.connection_count).to eq(1)
    end
  end

  it 'answers a call inside a reactor through Net::HTTP when AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP is set' do
    previous = ENV.fetch('AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP', nil)
    ENV['AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP'] = '1'

    with_threaded_server do |endpoint, server|
      built = track_http_clients
      allow(Async::Aws::Handler.net_http_handler).to receive(:call).and_call_original

      expect(Sync { dynamodb(endpoint).list_tables.table_names }).to eq([])

      expect(Async::Aws::Handler.net_http_handler).to have_received(:call).once
      expect(built).to be_empty
      expect(default_cache.size).to eq(0)
      expect(server.connection_count).to eq(1)
    end
  ensure
    ENV['AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP'] = previous
  end

  it 'returns from a :sync fallback call through a CONNECT proxy', :docker do
    skip 'tinyproxy not running (docker compose up)' unless SpecHelper.tinyproxy_available?

    with_threaded_server(bind: '0.0.0.0') do |endpoint, _server|
      client = dynamodb(
        "http://host.docker.internal:#{endpoint.url.port}",
        async_http_fallback: :sync,
        http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
        http_open_timeout: 5,
        http_read_timeout: 5,
      )

      # The CONNECT tunnel used to keep the transient reactor, and so the call, alive.
      call = Thread.new { client.list_tables.table_names }
      expect(call.join(10)).to be(call)
      expect(call.value).to eq([])
      expect(default_cache.size).to eq(0)
    ensure
      call&.kill
    end
  end

  it 'leaves a running reactor usable when clear! is called from outside any reactor' do
    with_threaded_server do |endpoint, server|
      client = dynamodb(endpoint)
      first_done = Queue.new
      continue = Queue.new
      worker = Thread.new do
        Sync do
          client.list_tables
          first_done << true
          continue.pop
          client.list_tables.table_names
        end
      end
      first_done.pop

      default_cache.clear!
      continue << true

      # The worker keeps its pooled connection and its reactor can finish.
      expect(worker.join(5)).to be(worker)
      expect(worker.value).to eq([])
      expect(server.connection_count).to eq(1)
    ensure
      continue << true
      worker&.join(5) || worker&.kill
    end
  end

  # Closing the socket under a request that is reading its body makes the
  # close of that body raise too; that must not replace the networking error.
  it 'fails a request that was reading its response body with a networking error when clear! times out' do
    body = Protocol::HTTP::Body::Writable.new
    responded = false
    app = lambda do |_request|
      responded = true
      body.write('{"Table')
      Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, body]
    end

    with_server(app) do |endpoint, _server|
      client = dynamodb(endpoint)
      call = Async { client.list_tables }
      wait_until { responded }
      sleep 0.05 # the headers and the first chunk reach the client

      Async::Task.current.with_timeout(5) { default_cache.clear!(timeout: 0.05) }

      expect { Async::Task.current.with_timeout(2) { call.wait } }.to raise_error(Seahorse::Client::NetworkingError)
    ensure
      body.close
    end
  end

  it 'bounds clear! by its timeout and fails the request that was in flight' do
    gate = ResponseGate.new
    app = lambda do |request|
      gate.wait
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      client = dynamodb(endpoint)
      call = Async { client.list_tables }
      wait_until { server.in_flight == 1 }

      started = monotonic
      Async::Task.current.with_timeout(5) { default_cache.clear!(timeout: 0.05) }

      expect(monotonic - started).to be < 1
      expect(default_cache.size).to eq(0)
      # Not by the request's own socket timeout (http_open_timeout, 15 s by default).
      expect { Async::Task.current.with_timeout(2) { call.wait } }.to raise_error(Seahorse::Client::NetworkingError)
    ensure
      gate.open!
    end
  end

  # Closing a socket under a blocked request makes Ruby interrupt that fiber
  # with an IOError, which the scheduler delivers on its next turn. A request
  # whose own timeout fires in the same timer batch has left its read by then.
  { 'alone on its client' => 1, 'next to another request on its client' => 2 }.each do |situation, requests|
    it "fails a request #{situation} as a network error when its timeout and the deadline of clear! fire together" do
      gate = ResponseGate.new
      app = lambda do |request|
        gate.wait
        LIST_TABLES.call(request)
      end

      with_server(app) do |endpoint, server|
        started = monotonic
        call = Async do
          dynamodb(endpoint, async_http_total_timeout: 0.35).list_tables
        rescue Seahorse::Client::NetworkingError => e
          sleep 0.01 # the caller's own code after the failed call
          e
        end
        wait_until { server.in_flight == 1 }
        # A second request keeps the client in use, so the first one closes nothing on release.
        other = Async { dynamodb(endpoint).list_tables } if requests == 2
        wait_until { server.in_flight == requests }
        clearing = Async { default_cache.clear!(timeout: started + 0.3 - monotonic) }

        # Block the event loop across both deadlines, so one timer batch fires both.
        sleep(started + 0.2 - monotonic)
        Fiber.blocking { sleep(started + 0.5 - monotonic) }

        expect(Async::Task.current.with_timeout(2) { call.wait }).to be_a(Seahorse::Client::NetworkingError)
        expect { Async::Task.current.with_timeout(2) { other.wait } }.to raise_error(Seahorse::Client::NetworkingError) if other
        clearing.wait
      ensure
        gate.open!
      end
    end
  end

  it 'closes the idle connections of the calling reactor on a timed clear!' do
    with_server do |endpoint, server|
      built = track_http_clients
      dynamodb(endpoint).list_tables
      expect(server.open_connections).to eq(1)

      default_cache.clear!(timeout: 1)

      expect(default_cache.size).to eq(0)
      expect(built.first.pool).to be_empty
      wait_until { server.open_connections.zero? }
    end
  end

  it 'stops waiting when the task that runs clear! is cancelled, and still closes the client' do
    gate = ResponseGate.new
    app = lambda do |request|
      gate.wait
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      client = dynamodb(endpoint)
      call = Async { client.list_tables.table_names }
      wait_until { server.in_flight == 1 }

      cleaner = Async { default_cache.clear! }
      cleaner.stop
      sleep 0.1

      # The cancellation is not held back until the request has finished ...
      expect(cleaner).to be_finished
      expect(default_cache.size).to eq(0)

      # ... the request is left alone, and its client is closed once it is done.
      gate.open!
      expect(call.wait).to eq([])
      wait_until { server.open_connections.zero? }
    ensure
      gate.open!
    end
  end

  it 'lets an enclosing timeout end clear!, and still closes the client' do
    gate = ResponseGate.new
    app = lambda do |request|
      gate.wait
      LIST_TABLES.call(request)
    end

    with_server(app) do |endpoint, server|
      client = dynamodb(endpoint)
      call = Async { client.list_tables.table_names }
      wait_until { server.in_flight == 1 }

      started = monotonic
      expect { Async::Task.current.with_timeout(0.05) { default_cache.clear! } }.to raise_error(Async::TimeoutError)
      expect(monotonic - started).to be < 1

      gate.open!
      expect(call.wait).to eq([])
      wait_until { server.open_connections.zero? }
    ensure
      gate.open!
    end
  end

  it 'reports a response cut off by a timed clear! as a networking error' do
    gate = ResponseGate.new
    app = lambda do |_request|
      body = Protocol::HTTP::Body::Writable.new
      Async do
        body.write('he')
        gate.wait
        body.write('llo')
        body.close_write
      end
      Protocol::HTTP::Response[200, {}, body]
    end

    with_server(app) do |endpoint, _server|
      s3 = Aws::S3::Client.new(**client_options(endpoint, force_path_style: true))
      cleared = false

      expect do
        Async::Task.current.with_timeout(5) do
          s3.get_object(bucket: 'bucket', key: 'key') do |_chunk|
            # Shutdown between two chunks: the connection is closed under the response.
            default_cache.clear!(timeout: 0.01) unless cleared
            cleared = true
          end
        end
        # S3 refuses to retry a download whose block already saw data, and says
        # so with this error; it only does that for retryable (networking) errors.
      end.to raise_error(Aws::S3::Plugins::NonRetryableStreamingError) { |error|
        expect(error.original_error).to be_a(Seahorse::Client::NetworkingError)
      }
    ensure
      gate.open!
    end
  end

  it 'lets a streaming block call the same endpoint while the outer response holds a connection' do
    # The object arrives in two chunks, and the second is only sent once the
    # nested call has reached the server: the outer response still owns its
    # connection while the block runs.
    gate = ResponseGate.new
    app = lambda do |request|
      unless request.path.start_with?('/bucket')
        gate.open!
        next LIST_TABLES.call(request)
      end

      body = Protocol::HTTP::Body::Writable.new
      Async do
        body.write('he')
        gate.wait
        body.write('llo')
        body.close_write
      end
      Protocol::HTTP::Response[200, {}, body]
    end

    with_server(app) do |endpoint, server|
      built = track_http_clients
      ddb = dynamodb(endpoint, async_http_connection_limit: 2)
      s3 = Aws::S3::Client.new(**client_options(endpoint, async_http_connection_limit: 2, force_path_style: true))

      nested = nil
      received = +''
      Async::Task.current.with_timeout(5) do
        s3.get_object(bucket: 'bucket', key: 'key') do |chunk|
          received << chunk
          nested ||= ddb.list_tables.table_names
        end
      end

      # The nested call needs a second connection of the same pool. With a
      # limit of 1 it would wait for the outer response forever.
      expect(received).to eq('hello')
      expect(nested).to eq([])
      expect(built.size).to eq(1)
      expect(server.connection_count).to eq(2)
    ensure
      gate.open!
    end
  end

  describe 'through a CONNECT proxy' do
    # A CONNECT proxy that reads the request and then answers with `reply`, or
    # never answers. Yields its URL and the client sockets it still holds.
    def with_stub_proxy(reply: nil)
      server = TCPServer.new('127.0.0.1', 0)
      held = []
      acceptor = Thread.new do
        loop do
          Thread.new(server.accept) do |socket|
            held << socket
            socket.readpartial(4096)
            reply ? socket.write(reply) : socket.read # `read` returns once the client closes
          rescue IOError, SystemCallError
            nil
          ensure
            held.delete(socket)
            socket.close
          end
        end
      end
      yield "http://127.0.0.1:#{server.addr[1]}", held
    ensure
      acceptor&.kill
      server&.close
    end

    def proxied_dynamodb(endpoint, **)
      dynamodb(
        "http://host.docker.internal:#{endpoint.url.port}",
        http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
        http_open_timeout: 5,
        http_read_timeout: 5,
        **,
      )
    end

    # Runs the block in a reactor on its own thread, so that a reactor which
    # does not finish fails the example instead of hanging it.
    def in_reactor(limit: 10, &block)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        Sync(&block)
      end
      expect(thread.join(limit)).to be(thread), 'the reactor did not finish'
      thread.value
    ensure
      thread&.kill
    end

    { 'a top-level Sync block' => {}, 'the :sync fallback' => { async_http_fallback: :sync } }.each do |caller, options|
      it "raises a networking error and returns from #{caller} when the proxy never answers CONNECT" do
        with_stub_proxy do |proxy_url, held|
          client = dynamodb(
            'http://127.0.0.1:1',
            http_proxy: proxy_url,
            async_http_header_timeout: 0.3,
            http_open_timeout: 5,
            http_read_timeout: 5,
            **options,
          )
          call = Thread.new do
            options.empty? ? Sync { client.list_tables } : client.list_tables
          rescue StandardError => e
            e
          end

          # The unanswered CONNECT used to leave a task behind that kept the reactor alive.
          expect(call.join(3)).to be(call)
          expect(call.value).to be_a(Seahorse::Client::NetworkingError)
          wait_until { held.empty? }
        ensure
          call&.kill
        end
      end
    end

    it 'closes the proxy connection when the caller is stopped while CONNECT is pending' do
      with_stub_proxy do |proxy_url, held|
        client = dynamodb('http://127.0.0.1:1', http_proxy: proxy_url, http_open_timeout: 20, http_read_timeout: 20)

        in_reactor do
          call = Async { client.list_tables }
          wait_until { held.size == 1 }
          call.stop
          wait_until { held.empty? }
        end

        expect(held).to be_empty
      end
    end

    context 'with tinyproxy', :docker do
      before { skip 'tinyproxy not running (docker compose up)' unless SpecHelper.tinyproxy_available? }

      it 'leaves no task behind when a pooled tunnel ends while another one stays open' do
        gate = Queue.new
        app = lambda do |request|
          gate.pop
          LIST_TABLES.call(request)
        end

        with_threaded_server(app, bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint)

          tunnel_tasks, open_tunnels = in_reactor do |task|
            # Two tunnels. The task of the first one hosts the proxy pool's
            # gardener, which async-pool starts in whichever task opens a
            # connection while the pool has none.
            calls = 2.times.map do |index|
              Async { client.list_tables }.tap { wait_until { server.in_flight == index + 1 } }
            end
            2.times { gate << true }
            calls.each(&:wait)

            target_pool, proxy_pool = default_cache.with_client(client.config.endpoint, client.config, &:pools)
            # What a `connection: close` answer or the idle policy does.
            target_pool.retire(target_pool.resources.keys.first)
            wait_until { proxy_pool.size == 1 }
            sleep 0.1

            tasks = task.reactor.traverse.count { |node, _| node.annotation == 'aws-sdk-http-async proxy tunnel' }
            [tasks, proxy_pool.size]
          end

          expect(open_tunnels).to eq(1)
          expect(tunnel_tasks).to eq(1)
        end
      ensure
        gate.close
      end

      it 'lets the reactor finish while a tunnel is still pooled' do
        with_threaded_server(bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint)

          expect(in_reactor { client.list_tables.table_names }).to eq([])
          wait_until { server.open_connections.zero? }
        end
      end

      it 'builds one proxied client for concurrent first calls' do
        built = track_http_clients

        with_threaded_server(bind: '0.0.0.0') do |endpoint, _server|
          client = proxied_dynamodb(endpoint)

          results = in_reactor { 10.times.map { Async { client.list_tables.table_names } }.map(&:wait) }

          expect(results).to all(eq([]))
          # One client for the target, one for the proxy.
          expect(built.size).to eq(2)
        end
      end

      it 'leaves no tunnel behind when a caller is stopped right after it started one' do
        with_threaded_server(bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint, async_http_connection_limit: 3)

          results = in_reactor do
            # More stops than the limit: an orphaned tunnel would keep its pool slot.
            6.times do
              Async { client.list_tables }.stop
              sleep 0.05
            end
            3.times.map { Async { client.list_tables.table_names } }.map(&:wait)
          end

          expect(results).to eq([[], [], []])
          wait_until { server.open_connections.zero? }
        end
      end

      it 'does not reuse a tunnel that sat idle past the proxy socket timeout' do
        with_threaded_server(bind: '0.0.0.0') do |endpoint, server|
          # The proxy socket's I/O timeout (http_open_timeout) ends an idle tunnel
          # inside async-http without closing the connection on top of it.
          client = proxied_dynamodb(endpoint, http_open_timeout: 1)

          results = in_reactor do |task|
            first = client.list_tables.table_names
            sleep 1.6
            [first, task.with_timeout(3) { client.list_tables.table_names }]
          end

          expect(results).to eq([[], []])
          expect(server.connection_count).to eq(2)
        end
      end

      it 'keeps a pooled tunnel usable after the task that opened it was stopped' do
        with_threaded_server(bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint)

          results = in_reactor do
            opened = Async::Promise.new
            opener = Async do
              opened.resolve(client.list_tables.table_names)
              sleep
            end
            opened.wait
            opener.stop
            3.times.map { Async { client.list_tables.table_names }.wait }
          end

          expect(results).to eq([[], [], []])
          expect(server.connection_count).to eq(1)
        end
      end

      it 'keeps a request in flight alive when the task that opened its tunnel is stopped' do
        gate = Queue.new
        app = lambda do |request|
          gate.pop
          LIST_TABLES.call(request)
        end

        with_threaded_server(app, bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint)

          results = in_reactor do
            opened = Async::Promise.new
            opener = Async do
              opened.resolve(client.list_tables.table_names)
              sleep
            end
            gate << true
            opened.wait
            in_flight = Async { client.list_tables.table_names }
            wait_until { server.in_flight == 1 }
            opener.stop
            gate << true
            [in_flight.wait, Async { gate << true; client.list_tables.table_names }.wait]
          end

          expect(results).to eq([[], []])
          expect(server.connection_count).to eq(1)
        ensure
          gate.close
        end
      end

      it 'bounds clear! by its timeout while a proxied request is in flight' do
        gate = Queue.new
        app = lambda do |request|
          gate.pop
          LIST_TABLES.call(request)
        end

        with_threaded_server(app, bind: '0.0.0.0') do |endpoint, server|
          client = proxied_dynamodb(endpoint, http_read_timeout: 20)

          elapsed, call = in_reactor do |task|
            call = Async { client.list_tables }
            wait_until { server.in_flight == 1 }
            started = monotonic
            task.with_timeout(5) { default_cache.clear!(timeout: 0.05) }
            [monotonic - started, call]
          end

          expect(elapsed).to be < 1
          expect(default_cache.size).to eq(0)
          expect { call.wait }.to raise_error(Seahorse::Client::NetworkingError)
        ensure
          gate.close
        end
      end

      it 'takes the tunnel down when the caller is stopped during the TLS handshake' do
        # Accepts the tunnel and never answers the ClientHello.
        silent = TCPServer.new('0.0.0.0', 0)
        accepted = Queue.new
        closed = Queue.new
        acceptor = Thread.new do
          socket = silent.accept
          accepted << true
          socket.read # returns once the tunnel is gone
          closed << true
        end
        client = dynamodb(
          "https://host.docker.internal:#{silent.addr[1]}",
          http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
          ssl_verify_peer: false,
          http_open_timeout: 20,
          http_read_timeout: 20,
        )

        in_reactor do
          call = Async { client.list_tables }
          expect(accepted.pop(timeout: 5)).to be(true)
          sleep 0.1
          call.stop
          expect(closed.pop(timeout: 3)).to be(true)
        end
      ensure
        acceptor&.kill
        silent&.close
      end
    end
  end
end
