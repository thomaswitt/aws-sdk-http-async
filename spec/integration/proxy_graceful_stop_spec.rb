require_relative '../spec_helper'

RSpec.describe 'Async::Aws proxied requests when the reactor is stopped' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  # Fake DynamoDB: answers ListTables once `gate` hands out a token.
  class GatedTarget
    attr_reader :port, :gate

    def initialize
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @gate = Queue.new
      @mutex = Mutex.new
      @in_flight = 0
      @requests = 0
      @acceptor = Thread.new { loop { Thread.new(@server.accept) { serve(it) } } }
    end

    def in_flight = @mutex.synchronize { @in_flight }
    def requests = @mutex.synchronize { @requests }

    def close
      @acceptor.kill
      @gate.close
      @server.close
    end

    private

    def serve(socket)
      buffer = +''
      loop do
        buffer << socket.readpartial(16_384) until buffer.include?("\r\n\r\n")
        head, rest = buffer.split("\r\n\r\n", 2)
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        rest << socket.readpartial(65_536) while rest.bytesize < length
        buffer = rest.byteslice(length..) || +''
        @mutex.synchronize { @in_flight += 1; @requests += 1 }
        @gate.pop
        @mutex.synchronize { @in_flight -= 1 }
        body = '{"TableNames":[]}'
        socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
      end
    rescue EOFError, IOError, SystemCallError
      nil
    ensure
      socket.close
    end
  end

  # CONNECT proxy that relays to 127.0.0.1, answering CONNECT after `delay`.
  class RelayProxy
    attr_accessor :delay

    def initialize
      @server = TCPServer.new('127.0.0.1', 0)
      @delay = 0
      @mutex = Mutex.new
      @open = 0
      @connects = 0
      @acceptor = Thread.new { loop { Thread.new(@server.accept) { serve(it) } } }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"
    def open = @mutex.synchronize { @open }
    def connects = @mutex.synchronize { @connects }

    def close
      @acceptor.kill
      @server.close
    end

    private

    def serve(client)
      @mutex.synchronize { @open += 1 }
      head = +''
      head << client.readpartial(4096) until head.include?("\r\n\r\n")
      @mutex.synchronize { @connects += 1 }
      sleep @delay
      upstream = TCPSocket.new('127.0.0.1', head[/\ACONNECT [^:\s]+:(\d+)/, 1].to_i)
      client.write("HTTP/1.1 200 Connection established\r\n\r\n")
      Thread.new do
        IO.copy_stream(upstream, client)
      rescue IOError, SystemCallError
        nil
      ensure
        client.close_write rescue nil # rubocop:disable Style/RescueModifier
      end
      IO.copy_stream(client, upstream)
    rescue EOFError, IOError, SystemCallError
      nil
    ensure
      @mutex.synchronize { @open -= 1 }
      [client, upstream].compact.each { it.close rescue nil } # rubocop:disable Style/RescueModifier
    end
  end

  let(:target) { GatedTarget.new }
  let(:proxy) { RelayProxy.new }
  let(:client) do
    Aws::DynamoDB::Client.new(
      endpoint: "http://127.0.0.1:#{target.port}", region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'), retry_limit: 0, max_attempts: 1,
      http_proxy: proxy.url, http_open_timeout: 5, http_read_timeout: 5,
    )
  end

  after do
    target.close
    proxy.close
  end

  def wait_until(limit = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(yield).to be_truthy
  end

  # Runs the block in a reactor on a thread of its own. `thread.raise(Interrupt)`
  # then does to that reactor what SIGINT does to the reactor of the main
  # thread: `Async::Scheduler#stop`.
  def reactor_thread(&block)
    Thread.new do
      Sync(&block)
      :finished
    rescue Interrupt
      :interrupted
    end
  end

  # Stops the reactor like SIGINT and expects it to finish within `limit` seconds.
  def interrupt(thread, limit: 5)
    thread.raise(Interrupt)
    yield if block_given?
    expect(thread.join(limit)).to be(thread), 'the reactor did not finish'
    expect(thread.value).to eq(:interrupted)
  end

  def call(client)
    client.list_tables.table_names
  rescue StandardError => e
    e
  end

  it 'lets a request on a pooled tunnel finish when it defers its cancel' do
    results = []
    thread = reactor_thread do
      target.gate << true
      results << call(client) # a pooled tunnel exists
      Async { |task| task.defer_stop { results << call(client) } }
      sleep
    end
    wait_until { target.in_flight == 1 && target.requests == 2 }

    interrupt(thread) do
      sleep 0.2
      target.gate << true
    end

    expect(results).to eq([[], []])
    expect(target.requests).to eq(2)
    wait_until { proxy.open.zero? }
  ensure
    thread&.kill
  end

  it 'lets a request finish whose tunnel is still being opened' do
    results = []
    proxy.delay = 0.4
    thread = reactor_thread do
      Async { |task| task.defer_stop { results << call(client) } }
      sleep
    end
    wait_until { proxy.connects == 1 }

    interrupt(thread) { target.gate << true }

    expect(results).to eq([[]])
    wait_until { proxy.open.zero? }
  ensure
    thread&.kill
  end

  it 'lets a stopped task make a call in its ensure' do
    results = []
    thread = reactor_thread do
      target.gate << true
      results << call(client)
      sleep
    ensure
      target.gate << true
      results << call(client)
    end
    wait_until { results.size == 1 }

    interrupt(thread)

    expect(results).to eq([[], []])
    wait_until { proxy.open.zero? }
  ensure
    thread&.kill
  end

  it 'closes idle tunnels at once and ends a request that does not defer its cancel' do
    results = []
    thread = reactor_thread do
      2.times { target.gate << true }
      2.times.map { Async { results << call(client) } }.each(&:wait)
      Async { results << call(client) } # never answered, not deferred
      sleep
    end
    wait_until { target.in_flight == 1 && results.size == 2 }
    expect(proxy.open).to eq(2)

    interrupt(thread, limit: 1)

    expect(results).to eq([[], []])
    wait_until { proxy.open.zero? }
  ensure
    thread&.kill
  end

  it 'keeps the error of a tunnel that a second stop closes under its request out of the caller', if: Process.respond_to?(:fork) do
    results = []
    after_call = []
    thread = reactor_thread do
      Async do |task|
        task.defer_stop do
          results << call(client)
          after_call << begin
            sleep 0.05 # the caller's own work after the call
            :fine
          rescue IOError => e
            e
          end
        end
      end
      sleep
    ensure
      sleep 0.5 # shutdown work that outlasts the second stop
    end
    wait_until { target.in_flight == 1 }
    # The child holds the tunnel's socket pair, so only the shutdown of the
    # tunnel's socket wakes the request, ahead of the IOError Ruby queued for it.
    pid = fork do
      sleep 30
    ensure
      exit!(0)
    end

    thread.raise(Interrupt)
    sleep 0.2
    thread.raise(Interrupt)

    expect(thread.join(5)).to be(thread), 'the reactor did not finish'
    expect(results.size).to eq(1)
    expect(results.first).to be_a(Seahorse::Client::NetworkingError)
    expect(after_call).to eq([:fine])
  ensure
    if pid
      Process.kill('KILL', pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(pid)
    end
    thread&.kill
  end

  # Ends the reactor the way the default SIGTERM handler ends the one of the
  # main thread: the event loop is left with the exception, and
  # `Async::Scheduler#close` then terminates every task, the tunnels included.
  it 'ends with the signal when the reactor is closed under a request that defers its cancel' do
    thread = Thread.new do
      Thread.current.report_on_exception = false
      Sync do
        Async do |task|
          task.defer_stop do
            # Outlives the request, so the request's task has a child to stop.
            task.async { |helper| helper.defer_stop { sleep } }
            call(client)
          end
        end
        sleep
      ensure
        Async::Aws::ClientCache.default.clear!
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end
    wait_until { target.in_flight == 1 }

    thread.raise(SignalException, 'SIGTERM')

    expect(thread.join(5)).to be(thread), 'the reactor did not finish'
    expect(thread.value).to be_a(SignalException)
    wait_until { proxy.open.zero? }
  ensure
    thread&.kill
  end
end
