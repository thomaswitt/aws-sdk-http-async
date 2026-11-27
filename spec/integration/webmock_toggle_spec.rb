require_relative '../spec_helper'
require 'webmock'

WebMock.disable!

# Regression: WebMock.enable!/disable! swap the Async::HTTP::Client constant.
# A client cached for a reactor must not outlive such a switch, or stubs and
# disable_net_connect! are ignored (and the other way round, a real call is
# still intercepted) for as long as that reactor runs.
RSpec.describe 'WebMock switched on and off inside one reactor' do
  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  # Runs a real server on its own thread and yields its URL and request counter.
  def with_real_server
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{SpecHelper.available_port}")
    requests = []
    app = lambda do |request|
      request.read
      requests << request.path
      Protocol::HTTP::Response[200, { 'content-type' => 'application/x-amz-json-1.0' }, ['{"TableNames":["real"]}']]
    end
    ready = Queue.new
    stop = Queue.new
    thread = Thread.new do
      Sync do |task|
        server_task = Async::HTTP::Server.new(app, endpoint).run
        task.sleep(0.05)
        ready << true
        stop.pop
        server_task.stop
      end
    end
    ready.pop
    yield endpoint.url.to_s.chomp('/'), requests
  ensure
    stop << true
    thread&.join
  end

  def dynamodb(url)
    Aws::DynamoDB::Client.new(
      endpoint: url,
      region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'),
      max_attempts: 1,
    )
  end

  def stub_list_tables(url)
    WebMock.stub_request(:post, "#{url}/").to_return(
      status: 200,
      body: '{"TableNames":["stubbed"]}',
      headers: { 'content-type' => 'application/x-amz-json-1.0' },
    )
  end

  it 'honours stubs and disable_net_connect! after a real call cached a client' do
    with_real_server do |url, requests|
      client = dynamodb(url)

      results = Sync do
        real = client.list_tables.table_names
        WebMock.enable!
        WebMock.disable_net_connect!
        stub_list_tables(url)
        [real, client.list_tables.table_names]
      end

      expect(results).to eq([['real'], ['stubbed']])
      expect(requests.size).to eq(1)
    end
  end

  it 'makes real calls again after WebMock.disable!' do
    with_real_server do |url, requests|
      client = dynamodb(url)

      results = Sync do
        WebMock.enable!
        WebMock.disable_net_connect!
        stub_list_tables(url)
        stubbed = client.list_tables.table_names
        WebMock.disable!
        [stubbed, client.list_tables.table_names]
      end

      expect(results).to eq([['stubbed'], ['real']])
      expect(requests.size).to eq(1)
    end
  end
end
