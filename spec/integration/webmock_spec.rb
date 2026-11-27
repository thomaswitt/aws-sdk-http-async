require_relative '../spec_helper'
require 'webmock'

# Loading WebMock enables it for the whole process; the examples below switch
# it on only for themselves.
WebMock.disable!

# Regression: WebMock's Async::HTTP::Client wrapper refuses to hand out its pool
# while real connections are disabled, with an error that is not a
# StandardError. Closing a finished reactor's client from the shared cache
# raised it out of the next AWS call.

RSpec.describe 'WebMock-stubbed calls' do
  around do |example|
    # The cache logs through Aws.config[:logger].
    previous_logger = Aws.config[:logger]
    Aws.config[:logger] = Logger.new(log)
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    Aws.config[:logger] = previous_logger
  end

  let(:log) { StringIO.new }
  let(:client) do
    Aws::DynamoDB::Client.new(
      region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'),
      max_attempts: 1,
      logger: Logger.new(log),
      **options,
    )
  end
  let(:options) { {} }

  before do
    WebMock.stub_request(:post, 'https://dynamodb.us-east-1.amazonaws.com/').to_return(
      status: 200,
      body: '{"TableNames":["t"]}',
      headers: { 'content-type' => 'application/x-amz-json-1.0' },
    )
  end

  it 'serves a call from each new reactor, after the previous reactor left its client in the shared cache' do
    results = Array.new(3) { Sync { client.list_tables.table_names } }

    expect(results).to eq([['t'], ['t'], ['t']])
    expect(Async::Aws::ClientCache.default.size).to eq(1)
    expect(log.string).not_to include('failed to close')
  end

  it 'shuts the cache down, with and without a timeout, inside and outside a reactor' do
    Sync do
      client.list_tables
      Async::Aws::ClientCache.default.clear!(timeout: 1)
    end
    Sync { client.list_tables }
    Async::Aws::ClientCache.default.clear!

    expect(Async::Aws::ClientCache.default.size).to eq(0)
    expect(log.string).not_to include('failed to close')
  end

  context 'with http_proxy' do
    let(:options) { { http_proxy: 'http://proxy.example:8080' } }

    it 'closes a stubbed client without touching the network' do
      Sync do
        expect(client.list_tables.table_names).to eq(['t'])
        Async::Aws::ClientCache.default.clear!(timeout: 1)
      end
      Sync { expect(client.list_tables.table_names).to eq(['t']) }
      Async::Aws::ClientCache.default.clear!

      expect(Async::Aws::ClientCache.default.size).to eq(0)
    end
  end

  context 'with the :sync fallback' do
    let(:options) { { async_http_fallback: :sync } }

    it 'serves a call outside a reactor after a reactor left its client in the shared cache' do
      Sync { client.list_tables }

      expect(client.list_tables.table_names).to eq(['t'])
    end
  end
end
