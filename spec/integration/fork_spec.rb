require_relative '../spec_helper'

RSpec.describe 'Async::Aws fork safety' do
  describe 'through an Aws client and the default cache', if: Process.respond_to?(:fork) do
    around { |example| SpecHelper.with_webmock_localhost { example.run } }

    let(:cache) { Async::Aws::ClientCache.default }
    # Requests per connection: the server handles each connection in a task of its own.
    let(:requests) { Hash.new(0).compare_by_identity }
    let(:list_tables) do
      lambda do |request|
        request.read
        requests[Async::Task.current] += 1
        Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, ['{"TableNames":[]}']]
      end
    end

    it 'a forked child keeps only its own client after its first call' do
      url = "http://127.0.0.1:#{SpecHelper.available_port}"
      server = Async::HTTP::Server.new(list_tables, Async::HTTP::Endpoint.parse(url))
      client = Aws::DynamoDB::Client.new(
        endpoint: url, region: 'us-east-1', credentials: Aws::Credentials.new('akid', 'secret'),
        retry_limit: 0, max_attempts: 1,
      )

      # The parent keeps a live reactor (server + its cached client) on another thread.
      ready = Queue.new
      release = Queue.new
      parent_reactor = Thread.new do
        Sync do |task|
          server_task = server.run
          task.sleep(0.05)
          client.list_tables
          ready << cache.size
          release.pop
          # After the fork: the parent's pooled connection still works.
          client.list_tables.table_names
        ensure
          cache.clear!(timeout: 1)
          server_task&.stop
        end
      end
      expect(ready.pop(timeout: 10)).to eq(1)

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        names = Sync { client.list_tables.table_names }
        entries = cache.instance_variable_get(:@clients).size
        writer.write([names.inspect, entries, cache.size].join(','))
      rescue Exception => e # rubocop:disable Lint/RescueException
        writer.write("#{e.class}: #{e.message}")
      ensure
        writer.close
        exit!(0)
      end
      writer.close

      expect(reader.wait_readable(10)).to be_truthy
      expect(reader.read).to eq('[],1,1') # mutant without the with_client guard: "[],2,0"
      expect(cache.size).to eq(1)

      release << true
      expect(parent_reactor.join(10)).to be(parent_reactor)
      expect(parent_reactor.value).to eq([])
      # The parent's connection carried both of its requests, the child used its own.
      expect(requests.values.sort).to eq([1, 2])
    ensure
      reader&.close
      if pid
        Process.kill('KILL', pid) rescue nil
        Process.wait(pid)
      end
      release << true
      parent_reactor&.join(10)
    end

    it "a forked child that uses the cache does not keep the parent's connections open" do
      closed = Queue.new
      body = '{"TableNames":[]}'
      server = TCPServer.new('127.0.0.1', 0)
      acceptor = Thread.new do
        socket = server.accept
        loop do
          head = +''
          head << socket.readpartial(16_384) until head.include?("\r\n\r\n")
          socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
        end
      rescue EOFError
        closed << true
      end
      client = Aws::DynamoDB::Client.new(
        endpoint: "http://127.0.0.1:#{server.addr[1]}", region: 'us-east-1',
        credentials: Aws::Credentials.new('akid', 'secret'), retry_limit: 0, max_attempts: 1,
      )

      ready = Queue.new
      release = Queue.new
      parent_reactor = Thread.new do
        Sync do
          client.list_tables
          ready << true
          release.pop
        ensure
          cache.clear!(timeout: 1)
        end
      end
      expect(ready.pop(timeout: 10)).to be(true)

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(cache.size.to_s) # its first use of the cache
        writer.close
        sleep 30
      ensure
        exit!(0)
      end
      writer.close
      expect(reader.wait_readable(10)).to be_truthy
      expect(reader.read).to eq('0')

      # The child is still alive: the server sees the parent's close all the same.
      release << true
      expect(closed.pop(timeout: 5)).to be(true)
    ensure
      reader&.close
      if pid
        Process.kill('KILL', pid) rescue nil
        Process.wait(pid)
      end
      release << true
      parent_reactor&.join(10)
      acceptor&.kill
      server&.close
    end

    it "a forked child does not keep open a connection that the parent's clear! is still closing" do
      seen = Queue.new
      answer = Queue.new
      closed = Queue.new
      body = '{"TableNames":[]}'
      server = TCPServer.new('127.0.0.1', 0)
      acceptor = Thread.new do
        socket = server.accept
        loop do
          head = +''
          head << socket.readpartial(16_384) until head.include?("\r\n\r\n")
          seen << true
          answer.pop
          socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
        end
      rescue EOFError
        closed << true
      end
      client = Aws::DynamoDB::Client.new(
        endpoint: "http://127.0.0.1:#{server.addr[1]}", region: 'us-east-1',
        credentials: Aws::Credentials.new('akid', 'secret'), retry_limit: 0, max_attempts: 1,
      )

      parent_reactor = Thread.new do
        Sync do |task|
          request = task.async { client.list_tables }
          # Takes the client out of the cache, then waits for its request.
          cache.clear!
          request.wait
        end
      end
      expect(seen.pop(timeout: 10)).to be(true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.01 until cache.size.zero? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      expect(cache.size).to eq(0)

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(cache.size.to_s) # its first use of the cache
        writer.close
        sleep 30
      ensure
        exit!(0)
      end
      writer.close
      expect(reader.wait_readable(10)).to be_truthy
      expect(reader.read).to eq('0')

      # The child is still alive: the server sees the parent's close all the same.
      answer << true
      expect(closed.pop(timeout: 5)).to be(true)
    ensure
      reader&.close
      if pid
        Process.kill('KILL', pid) rescue nil
        Process.wait(pid)
      end
      answer << true
      parent_reactor&.join(10)
      acceptor&.kill
      server&.close
    end
  end
end
