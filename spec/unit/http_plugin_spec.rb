require_relative '../spec_helper'
require 'aws-sdk-dynamodb'

RSpec.describe Async::Aws::HttpPlugin do
  it 'adds async plugin options with defaults' do
    config = Seahorse::Client::Configuration.new
    described_class.new.add_options(config)
    built = config.build!

    expect(built.async_http_connection_limit).to eq(10)
    expect(built.async_http_force_accept_encoding).to be(true)
    expect(built.async_http_body_warn_bytes).to eq(5 * 1024 * 1024)
    expect(built.async_http_max_buffer_bytes).to eq(5 * 1024 * 1024)
    expect(built.async_http_idle_timeout).to eq(30)
    expect(built.async_http_header_timeout).to be_nil
    expect(built.async_http_max_cached_clients).to eq(100)
    expect(built.async_http_client_cache).to be_nil
  end

  it 'registers the async handler as send handler' do
    handlers = Seahorse::Client::HandlerList.new
    config = Seahorse::Client::Configuration.new

    described_class.new.add_handlers(handlers, config)

    expect(handlers.to_a).to eq([Async::Aws::Handler])
  end

  it 'does not interfere with stubbed responses' do
    client = Aws::DynamoDB::Client.new(
      region: 'us-east-1',
      credentials: Aws::Credentials.new('akid', 'secret'),
      stub_responses: true,
      plugins: [described_class],
    )

    client.stub_responses(:list_tables, { table_names: ['test'] })
    response = client.list_tables

    expect(response.table_names).to eq(['test'])
  end
end
