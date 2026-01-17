require_relative '../spec_helper'

RSpec.describe Async::Aws::Patcher do
  around do |example|
    described_class.unpatch(:all)
    example.run
  ensure
    described_class.patch(:all)
  end

  it 'patches existing clients when using :all' do
    dummy_class = Class.new(Seahorse::Client::Base)
    Object.const_set('DummyAwsClient', dummy_class)

    expect(dummy_class.plugins).not_to include(Async::Aws::HttpPlugin)

    described_class.patch(:all)

    expect(dummy_class.plugins).to include(Async::Aws::HttpPlugin)
  ensure
    Object.send(:remove_const, 'DummyAwsClient') if Object.const_defined?('DummyAwsClient')
  end

  it 'patches a specific service when provided' do
    described_class.patch(:dynamodb)

    expect(Aws::DynamoDB::Client.plugins).to include(Async::Aws::HttpPlugin)
  end

  it 'unpatches only what it patched' do
    dummy_class = Class.new(Seahorse::Client::Base)
    Object.const_set('DummyAwsClient', dummy_class)

    described_class.patch(:all)
    expect(dummy_class.plugins).to include(Async::Aws::HttpPlugin)

    described_class.unpatch(:all)
    expect(dummy_class.plugins).not_to include(Async::Aws::HttpPlugin)
  ensure
    Object.send(:remove_const, 'DummyAwsClient') if Object.const_defined?('DummyAwsClient')
  end

  it 'unpatches clients created after patch(:all)' do
    described_class.patch(:all)

    late_class = Class.new(Seahorse::Client::Base)
    Object.const_set('LateAwsClient', late_class)
    expect(late_class.plugins).to include(Async::Aws::HttpPlugin)

    described_class.unpatch(:all)
    expect(late_class.plugins).not_to include(Async::Aws::HttpPlugin)
  ensure
    Object.send(:remove_const, 'LateAwsClient') if Object.const_defined?('LateAwsClient')
  end
end
