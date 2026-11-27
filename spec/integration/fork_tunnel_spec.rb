require_relative '../spec_helper'

RSpec.describe 'Async::Aws fork safety' do
  describe 'through a CONNECT proxy', if: Process.respond_to?(:fork) do
    around { |example| SpecHelper.with_webmock_localhost { example.run } }

    # Serves each accepted socket with `serve` on its own thread; yields the port.
    def with_threaded_listener(serve)
      server = TCPServer.new('127.0.0.1', 0)
      acceptor = Thread.new do
        loop do
          Thread.new(server.accept) do |socket|
            serve.call(socket)
          rescue IOError, SystemCallError
            nil
          ensure
            socket.close
          end
        end
      end
      yield server.addr[1]
    ensure
      acceptor&.kill
      server&.close
    end

    def serve_list_tables(socket)
      body = '{"TableNames":[]}'
      loop do
        head = +''
        head << socket.readpartial(16_384) until head.include?("\r\n\r\n")
        socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
      end
    end

    def relay_connect(socket)
      head = +''
      head << socket.readpartial(4096) until head.include?("\r\n\r\n")
      upstream = TCPSocket.new('127.0.0.1', head[/\ACONNECT [^:\s]+:(\d+)/, 1].to_i)
      socket.write("HTTP/1.1 200 Connection established\r\n\r\n")
      back = Thread.new { IO.copy_stream(upstream, socket) rescue nil }
      IO.copy_stream(socket, upstream)
    ensure
      upstream&.close
      back&.join(1)
    end

    it 'lets the parent replace a pooled tunnel while a child forked meanwhile is alive' do
      with_threaded_listener(method(:serve_list_tables)) do |target_port|
        with_threaded_listener(method(:relay_connect)) do |proxy_port|
          client = Aws::DynamoDB::Client.new(
            endpoint: "http://127.0.0.1:#{target_port}", region: 'us-east-1',
            credentials: Aws::Credentials.new('akid', 'secret'), retry_limit: 0, max_attempts: 1,
            http_proxy: "http://127.0.0.1:#{proxy_port}", async_http_connection_limit: 1,
            http_idle_timeout: 0.1, async_http_header_timeout: 2, http_open_timeout: 5, http_read_timeout: 5,
          )

          # The parent keeps a live reactor with one pooled tunnel on another thread.
          ready = Queue.new
          forked = Queue.new
          second_call = Queue.new
          parent_reactor = Thread.new do
            Sync do |task|
              client.list_tables
              ready << true
              forked.pop
              task.sleep(0.5) # the idle policy retires the tunnel after 0.1 to 0.2 seconds
              second_call << begin
                client.list_tables.table_names
              rescue StandardError => e
                e
              end
            ensure
              Async::Aws::ClientCache.default.clear!(timeout: 1)
            end
          end
          expect(ready.pop(timeout: 10)).to be(true)

          # The child inherits the tunnel's socket pair and never touches the gem.
          pid = fork do
            sleep 30
          ensure
            exit!(0)
          end
          forked << true

          # The retired tunnel used to keep the only proxy connection until the child was gone.
          expect(second_call.pop(timeout: 10)).to eq([])
        ensure
          if pid
            Process.kill('KILL', pid) rescue nil
            Process.wait(pid)
          end
          forked << true
          parent_reactor&.join(5) || parent_reactor&.kill
        end
      end
    end
  end
end
