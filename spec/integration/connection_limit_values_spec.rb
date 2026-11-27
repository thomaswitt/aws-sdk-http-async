require_relative '../spec_helper'

RSpec.describe 'Async::Aws connection limit without an Integer value' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  let(:app) do
    lambda do |request|
      request.read
      Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, ['{"TableNames":[]}']]
    end
  end

  def with_server
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{SpecHelper.available_port}")
    connections = 0
    server = Async::HTTP::Server.new(app, endpoint)
    server.define_singleton_method(:accept) do |*arguments, **options|
      connections += 1
      super(*arguments, **options)
    end

    Sync do |task|
      server_task = server.run
      task.sleep(0.05)
      yield endpoint, -> { connections }
    ensure
      Async::Aws::ClientCache.default.clear!(timeout: 1)
      server_task&.stop
    end
  end

  def dynamodb(endpoint, **options)
    Aws::DynamoDB::Client.new(
      endpoint: endpoint.url.to_s, region: 'us-east-1', max_attempts: 1,
      credentials: Aws::Credentials.new('akid', 'secret'), **options,
    )
  end

  # Makes every client connect take `seconds` (without blocking the reactor)
  # and records how many connects overlap.
  def slow_connects(seconds)
    stats = { active: 0, peak: 0 }
    # rubocop:disable RSpec/AnyInstance -- the endpoint is built inside the cache
    allow_any_instance_of(Async::HTTP::Endpoint).to receive(:connect).and_wrap_original do |original, *arguments, &block|
      # rubocop:enable RSpec/AnyInstance
      stats[:active] += 1
      stats[:peak] = [stats[:peak], stats[:active]].max
      begin
        Async::Task.current.sleep(seconds)
      ensure
        stats[:active] -= 1
      end
      original.call(*arguments, &block)
    end
    stats
  end

  [nil, 50.0, Float::INFINITY].each do |limit|
    it "opens connections concurrently with async_http_connection_limit: #{limit.inspect}" do
      with_server do |endpoint, connections|
        stats = slow_connects(0.1)
        client = dynamodb(endpoint, async_http_connection_limit: limit)

        Async::Task.current.with_timeout(5) do
          6.times.map { Async { client.list_tables.table_names } }.each(&:wait)
        end

        expect(stats[:peak]).to eq(6)
        expect(connections.call).to eq(6)
      end
    end
  end

  it 'does not make a call that can reuse an idle connection wait for a pending connect (limit: nil)' do
    with_server do |endpoint, connections|
      client = dynamodb(endpoint, async_http_connection_limit: nil)
      client.list_tables # one warm, idle connection
      slow_connects(1.5)

      Async::Task.current.with_timeout(5) do
        slow = [Async { client.list_tables }, Async { client.list_tables }] # the second one has to connect
        Async::Task.current.sleep(0.2)
        reused = Async::Task.current.with_timeout(0.5) { client.list_tables.table_names }
        expect(reused).to eq([])
        slow.each(&:wait)
      end
      expect(connections.call).to eq(2)
    end
  end

  it 'still keeps to a Float limit' do
    with_server do |endpoint, connections|
      slow_connects(0.05)
      client = dynamodb(endpoint, async_http_connection_limit: 2.0)

      Async::Task.current.with_timeout(5) do
        8.times.map { Async { client.list_tables.table_names } }.each(&:wait)
      end

      expect(connections.call).to eq(2)
    end
  end

  [0, -1].each do |limit|
    it "treats async_http_connection_limit: #{limit} as no limit" do
      with_server do |endpoint, connections|
        client = dynamodb(endpoint, async_http_connection_limit: limit)

        # async-pool would open no connection for such a limit and wait forever.
        tables = Async::Task.current.with_timeout(2) { client.list_tables.table_names }

        expect(tables).to eq([])
        expect(connections.call).to eq(1)
      end
    end
  end

  it 'rejects a limit that is not a number' do
    with_server do |endpoint, _connections|
      # Also with a client for the number already cached.
      dynamodb(endpoint, async_http_connection_limit: 50).list_tables
      client = dynamodb(endpoint, async_http_connection_limit: '50')

      expect { client.list_tables }.to raise_error(ArgumentError, /async_http_connection_limit/)
    end
  end
end
