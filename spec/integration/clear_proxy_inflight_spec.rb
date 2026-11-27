require_relative '../spec_helper'

RSpec.describe 'Async::Aws::ClientCache#clear! with proxied requests that hold no connection yet' do
  let(:body) { '{"TableNames":[]}' }

  # Threaded HTTP/1.1 target: answers every request with "connection: close",
  # the first one only once `gate` is fed.
  def with_target(body, gate: nil)
    server = TCPServer.new('127.0.0.1', 0)
    requests = Queue.new
    acceptor = Thread.new do
      loop do
        Thread.new(server.accept) do |socket|
          buffer = +''
          buffer << socket.readpartial(16_384) until buffer.include?("\r\n\r\n")
          requests << true
          gate&.pop if requests.size == 1
          socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\n" \
                       "connection: close\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
        rescue IOError, SystemCallError
          nil
        ensure
          socket.close
        end
      end
    end
    yield server.addr[1], requests
  ensure
    acceptor&.kill
    server&.close
  end

  # CONNECT proxy that answers after `delay` seconds, then relays bytes.
  def with_relay_proxy(delay)
    server = TCPServer.new('127.0.0.1', 0)
    open = []
    acceptor = Thread.new do
      loop do
        Thread.new(server.accept) do |client|
          open << client
          head = +''
          head << client.readpartial(4096) until head.include?("\r\n\r\n")
          sleep delay
          upstream = TCPSocket.new('127.0.0.1', head[/\ACONNECT [^:\s]+:(\d+)/, 1].to_i)
          client.write("HTTP/1.1 200 Connection established\r\n\r\n")
          back = Thread.new do
            IO.copy_stream(upstream, client)
            client.close_write
          rescue IOError, SystemCallError
            nil
          end
          IO.copy_stream(client, upstream)
          back.join(2)
        rescue IOError, SystemCallError
          nil
        ensure
          upstream&.close
          client.close
          open.delete(client)
        end
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}", open
  ensure
    acceptor&.kill
    server&.close
  end

  def proxied_client(port, proxy, cache)
    Aws::DynamoDB::Client.new(
      endpoint: "http://127.0.0.1:#{port}", region: 'us-east-1', credentials: Aws::Credentials.new('a', 's'),
      http_proxy: proxy, http_open_timeout: 5, http_read_timeout: 5, retry_limit: 0, max_attempts: 1,
      async_http_client_cache: cache, async_http_connection_limit: 1,
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

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'condition not met in time' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  { 'clear!' => {}, 'clear!(timeout: 5)' => { timeout: 5 } }.each do |name, options|
    it "#{name} does not fail a request whose CONNECT is still pending, and its last request closes the client" do
      cache = Async::Aws::ClientCache.new

      with_target(body) do |port, requests|
        with_relay_proxy(0.3) do |proxy, open|
          client = proxied_client(port, proxy, cache)

          result = in_reactor do
            call = Async { client.list_tables.table_names }
            wait_until { open.size == 1 } # the CONNECT was sent, the answer is 0.3s away
            cache.clear!(**options)
            expect(cache.size).to eq(0)
            call.wait
          end

          expect(result).to eq([])
          expect(requests.size).to eq(1)
          wait_until { open.empty? }
        end
      end
    end
  end

  it 'clear! does not fail requests that wait their turn behind a connection that is not reused' do
    cache = Async::Aws::ClientCache.new
    gate = Queue.new

    with_target(body, gate:) do |port, requests|
      with_relay_proxy(0.05) do |proxy, open|
        client = proxied_client(port, proxy, cache)

        results = in_reactor do
          calls = 3.times.map { Async { client.list_tables.table_names } }
          wait_until { requests.size == 1 } # one request in flight, two wait for the only slot
          cleaner = Async { cache.clear! }
          sleep 0.05
          gate << true
          cleaner.wait
          calls.map(&:wait)
        end

        expect(results).to eq([[], [], []])
        expect(requests.size).to eq(3)
        expect(cache.size).to eq(0)
        wait_until { open.empty? }
      end
    end
  end
end
