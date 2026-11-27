require_relative '../spec_helper'
require 'webmock'

# Loading WebMock enables it for the whole process; only the last example uses it.
WebMock.disable!

# Regression: the handler mapped every Async::TimeoutError to a retryable
# Seahorse::Client::NetworkingError, including the one a caller's own
# `task.with_timeout { client.call }` raises into the call. The caller's
# timeout was swallowed and the request sent again.
RSpec.describe 'a timeout the caller puts around an AWS call' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  let(:requests) { [] }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Runs a server that answers ListTables after `delay` seconds, and the example, in one reactor.
  def with_slow_server(delay)
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{SpecHelper.available_port}")
    app = lambda do |request|
      request.read
      requests << request
      sleep delay
      Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, ['{"TableNames":[]}']]
    end

    Sync do |task|
      server_task = Async::HTTP::Server.new(app, endpoint).run
      task.sleep(0.05)
      yield task, endpoint
    ensure
      Async::Aws::ClientCache.default.clear!(timeout: 1)
      server_task&.stop
    end
  end

  def dynamodb(endpoint, **options)
    Aws::DynamoDB::Client.new(
      endpoint: endpoint.url.to_s,
      region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'),
      **options,
    )
  end

  it 'reaches the caller as Async::TimeoutError, without a retry' do
    with_slow_server(0.5) do |task, endpoint|
      client = dynamodb(endpoint) # default retries
      started = monotonic

      expect { task.with_timeout(0.1) { client.list_tables } }.to raise_error(Async::TimeoutError, 'execution expired')
      expect(monotonic - started).to be < 0.4
      expect(requests.size).to eq(1)
    end
  end

  it 'reaches the caller while the call waits its turn' do
    with_slow_server(0.5) do |task, endpoint|
      client = dynamodb(endpoint, async_http_connection_limit: 1, async_http_header_timeout: 5)
      holder = task.async { client.list_tables.table_names }
      task.sleep(0.05)
      started = monotonic

      expect { task.with_timeout(0.1) { client.list_tables } }.to raise_error(Async::TimeoutError, 'execution expired')
      expect(monotonic - started).to be < 0.4
      expect(requests.size).to eq(1)
      expect(holder.wait).to eq([])
    end
  end

  # Regression: giving up the turn switches to the call that waits for it, with
  # the timer of `async_http_total_timeout` still armed. If that timer was due
  # in the same pass of the event loop, its error replaced the caller's timeout
  # (or stop) and was reported as a networking error, so the SDK retried.
  context 'when async_http_total_timeout is due in the same pass of the event loop and another call waits its turn' do
    # A call that is interrupted at 0.2s, a call queued behind it, and an event
    # loop that is busy from 0.1s to 0.35s, across the total timeout at 0.25s.
    def interrupted_call(task, endpoint, stop_after: nil)
      options = { async_http_connection_limit: 1, retry_base_delay: 0.01 }
      client = dynamodb(endpoint, async_http_total_timeout: 0.25, **options)
      started = monotonic
      call = task.async do |call_task|
        yield call_task, client
      rescue StandardError => error
        error
      end
      queued = task.async { dynamodb(endpoint, **options).list_tables.table_names }
      task.async do
        sleep(0.1)
        nil while monotonic - started < 0.35
      end
      if stop_after
        task.async do
          sleep(stop_after)
          call.stop
        end
      end
      call.wait
      elapsed = monotonic - started
      expect(queued.wait).to eq([])
      [call, elapsed]
    end

    it "raises the caller's timeout, without a retry" do
      with_slow_server(0.5) do |task, endpoint|
        call, elapsed = interrupted_call(task, endpoint) do |call_task, client|
          call_task.with_timeout(0.2) { client.list_tables }
        end

        expect(call.result).to be_an_instance_of(Async::TimeoutError)
        expect(elapsed).to be < 0.5
        expect(requests.size).to eq(2)
      end
    end

    it 'ends a stopped call' do
      with_slow_server(0.5) do |task, endpoint|
        call, elapsed = interrupted_call(task, endpoint, stop_after: 0.2) { |_call_task, client| client.list_tables }

        expect(call.status).to eq(:cancelled)
        expect(elapsed).to be < 0.5
        expect(requests.size).to eq(2)
      end
    end
  end

  it "keeps the transport's own timeout a retried networking error" do
    with_slow_server(0.5) do |_task, endpoint|
      client = dynamodb(endpoint, async_http_header_timeout: 0.1, max_attempts: 2, retry_base_delay: 0.01)

      expect { client.list_tables }.to raise_error(Seahorse::Client::NetworkingError) { |error|
        expect(error.original_error).to be_a(Async::TimeoutError)
      }
      expect(requests.size).to eq(2)
    end
  end

  context 'with a WebMock stub that times out' do
    around do |example|
      WebMock.enable!
      example.run
    ensure
      WebMock.reset!
      WebMock.disable!
    end

    it 'is a networking error, as with Net::HTTP' do
      stub = WebMock.stub_request(:post, 'https://dynamodb.us-east-1.amazonaws.com/').to_timeout
      client = Aws::DynamoDB::Client.new(
        region: 'us-east-1', credentials: Aws::Credentials.new('akid', 'secret'), max_attempts: 2, retry_base_delay: 0.01,
      )

      expect { Sync { client.list_tables } }.to raise_error(Seahorse::Client::NetworkingError, /WebMock timeout error/)
      expect(WebMock::RequestRegistry.instance.times_executed(stub.request_pattern)).to eq(2)
    end
  end
end
