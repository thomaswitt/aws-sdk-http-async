require_relative '../spec_helper'
require 'tempfile'
require 'base64'
require 'timeout'

RSpec.describe Async::Aws::ClientCache do
  it 'reuses client for the same endpoint and config' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    Async do
      first = cache.client_for(endpoint, config)
      second = cache.client_for(endpoint, config)

      expect(first).to be(second)
    end.wait
  end

  it 'creates different clients when ssl settings differ' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(ssl_verify_peer: true)
    config_b = SpecHelper.build_config(ssl_verify_peer: false)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'creates different clients when ssl_cert differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    cert_a = OpenSSL::X509::Certificate.new
    cert_b = OpenSSL::X509::Certificate.new

    config_a = SpecHelper.build_config(ssl_cert: cert_a)
    config_b = SpecHelper.build_config(ssl_cert: cert_b)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'reuses client when ssl_cert path is the same' do
    cache = described_class.new
    endpoint = URI('https://example.com')

    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/CN=example')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now
    cert.not_after = Time.now + 3600
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    cert_file = Tempfile.new('cert')
    cert_file.write(cert.to_pem)
    cert_file.close

    config = SpecHelper.build_config(ssl_cert: cert_file.path)

    Async do
      first = cache.client_for(endpoint, config)
      second = cache.client_for(endpoint, config)

      expect(first).to be(second)
    end.wait
  ensure
    cert_file&.unlink
  end

  it 'accepts ssl_cert as a file object' do
    cache = described_class.new
    endpoint = URI('https://example.com')

    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/CN=example')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now
    cert.not_after = Time.now + 3600
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    cert_file = Tempfile.new('cert')
    cert_file.write(cert.to_pem)
    cert_file.flush

    config = SpecHelper.build_config(ssl_cert: cert_file)

    Async do
      expect { cache.client_for(endpoint, config) }.not_to raise_error
    end.wait
  ensure
    cert_file&.close
    cert_file&.unlink
  end

  it 'creates different clients when ssl_key differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    key_a = OpenSSL::PKey::RSA.new(2048)
    key_b = OpenSSL::PKey::RSA.new(2048)

    config_a = SpecHelper.build_config(ssl_key: key_a)
    config_b = SpecHelper.build_config(ssl_key: key_b)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'accepts ssl_key as a file object' do
    cache = described_class.new
    endpoint = URI('https://example.com')

    key = OpenSSL::PKey::RSA.new(2048)
    key_file = Tempfile.new('key')
    key_file.write(key.to_pem)
    key_file.flush

    config = SpecHelper.build_config(ssl_key: key_file)

    Async do
      expect { cache.client_for(endpoint, config) }.not_to raise_error
    end.wait
  ensure
    key_file&.close
    key_file&.unlink
  end

  it 'creates different clients when connection limit differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(async_http_connection_limit: 5)
    config_b = SpecHelper.build_config(async_http_connection_limit: 10)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'creates different clients when open timeout differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(http_open_timeout: 1)
    config_b = SpecHelper.build_config(http_open_timeout: 3)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'creates different clients when ssl_ca_store differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    store_a = OpenSSL::X509::Store.new
    store_b = OpenSSL::X509::Store.new

    config_a = SpecHelper.build_config(ssl_ca_store: store_a)
    config_b = SpecHelper.build_config(ssl_ca_store: store_b)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'creates different clients when http_proxy differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(http_proxy: 'http://proxy-a:8080')
    config_b = SpecHelper.build_config(http_proxy: 'http://proxy-b:8080')

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'creates different clients when proxy credentials differ' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(http_proxy: 'http://user:pass@proxy.local:8080')
    config_b = SpecHelper.build_config(http_proxy: 'http://user:other@proxy.local:8080')

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'adds proxy authorization header when credentials are provided' do
    cache = described_class.new
    uri = URI.parse('http://user:pass@proxy.local:8080')

    headers = cache.send(:proxy_headers, uri)

    expect(headers).to be_a(Array)
    key, value = headers.first
    expect(key).to eq('proxy-authorization')
    expect(value).to eq("Basic #{Base64.strict_encode64('user:pass')}")
  end

  it 'decodes percent-encoded proxy credentials' do
    cache = described_class.new
    uri = URI.parse('http://user%3Aname:pa%3Ass@proxy.local:8080')

    headers = cache.send(:proxy_headers, uri)
    _, value = headers.first

    expect(value).to eq("Basic #{Base64.strict_encode64('user:name:pa:ss')}")
  end

  it 'preserves plus signs in proxy credentials' do
    cache = described_class.new
    uri = URI.parse('http://user+name:pa+ss@proxy.local:8080')

    headers = cache.send(:proxy_headers, uri)
    _, value = headers.first

    expect(value).to eq("Basic #{Base64.strict_encode64('user+name:pa+ss')}")
  end

  it 'does not include raw proxy credentials in the cache key' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(http_proxy: 'http://user:pass@proxy.local:8080')

    Async do
      reactor = Async::Task.current.reactor
      key = cache.send(:cache_key, endpoint, config, reactor)

      expect(key).not_to include('user:pass')
    end.wait
  end

  it 'closes proxy client even if target close raises' do
    proxy_closed = false
    proxy = Class.new do
      define_method(:close) { proxy_closed = true }
    end.new
    target = Class.new do
      define_method(:close) { raise 'boom' }
    end.new

    client = Async::Aws::ClientCache::ProxyClient.new(target, proxy)
    expect { client.close }.to raise_error('boom')
    expect(proxy_closed).to be(true)
  end

  it 'closes both proxy and target clients' do
    closed = []
    proxy = Class.new do
      def initialize(closed)
        @closed = closed
      end

      def close
        @closed << :proxy
      end
    end.new(closed)

    target = Class.new do
      def initialize(closed)
        @closed = closed
      end

      def close
        @closed << :target
      end
    end.new(closed)

    client = Async::Aws::ClientCache::ProxyClient.new(target, proxy)
    client.close

    expect(closed).to contain_exactly(:proxy, :target)
  end

  it 'sets verify_hostname when ssl_verify_peer is enabled' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_verify_peer: true)

    context = cache.send(:ssl_context, config, endpoint)

    if context.respond_to?(:verify_hostname)
      expect(context.verify_hostname).to be(true)
    end
  end

  it 'creates different clients across reactors' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    first = Async { cache.client_for(endpoint, config) }.wait
    second = Thread.new { Async { cache.client_for(endpoint, config) }.wait }.value

    expect(first).not_to be(second)
  end

  it 'clears cached clients' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    first = Async { cache.client_for(endpoint, config) }.wait
    cache.clear!
    second = Async { cache.client_for(endpoint, config) }.wait

    expect(first).not_to be(second)
  end

  it 'clears cached clients with a timeout' do
    cache = described_class.new
    client = Class.new do
      def close
        Async::Task.current.sleep(0.2)
      end
    end.new

    cache.instance_variable_get(:@clients)['test'] = client

    Async do
      expect { cache.clear!(timeout: 0.01) }.not_to raise_error
    end.wait
  end

  it 'does not close clients from another reactor when evicting' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 1)
    endpoint_a = URI('https://a.example.com')
    endpoint_b = URI('https://b.example.com')
    closed = Queue.new

    client = Class.new do
      def initialize(queue)
        @queue = queue
      end

      def close
        @queue << :closed
      end
    end.new(closed)

    allow(cache).to receive(:build_client).and_return(client, Class.new { def close; end }.new)

    ready = Queue.new
    owner_thread = Thread.new do
      Async do |task|
        cache.client_for(endpoint_a, config)
        ready << true
        task.sleep(0.5)
      end.wait
    end

    ready.pop

    Thread.new do
      Async do
        cache.client_for(endpoint_b, config)
      end.wait
    end.join

    sleep 0.05
    expect(closed.empty?).to be(true)
    owner_thread.join
  end

  it 'clears cached clients outside a reactor without raising' do
    cache = described_class.new
    client = Class.new do
      def close; end
    end.new

    cache.instance_variable_get(:@clients)['test'] = described_class::Entry.new(client, nil)

    expect { cache.clear! }.not_to raise_error
  end

  it 'closes cross-reactor clients when clearing outside a reactor' do
    cache = described_class.new
    closed = { value: false }
    client = Class.new do
      def initialize(closed)
        @closed = closed
      end

      def close
        @closed[:value] = true
      end
    end.new(closed)

    reactor = Async::Reactor.new
    entry = described_class::Entry.new(client, WeakRef.new(reactor))
    cache.instance_variable_get(:@clients)['test'] = entry

    cache.clear!

    expect(closed[:value]).to be(true)
  end

  it 'evicts least recently used clients when max cached exceeded' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 2)
    endpoints = [
      URI('https://a.example.com'),
      URI('https://b.example.com'),
      URI('https://c.example.com'),
    ]
    closed = []
    clients = 3.times.map do |idx|
      Class.new do
        def initialize(id, closed)
          @id = id
          @closed = closed
        end

        def close
          @closed << @id
        end
      end.new(idx, closed)
    end

    allow(cache).to receive(:build_client).and_return(*clients)

    Async do
      cache.client_for(endpoints[0], config)
      cache.client_for(endpoints[1], config)
      cache.client_for(endpoints[0], config)
      cache.client_for(endpoints[2], config)
    end.wait

    expect(closed).to contain_exactly(1)
  end

  it 'rebuilds client when reactor reference does not match' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    Async do
      reactor = Async::Task.current.reactor
      key = cache.send(:cache_key, endpoint, config, reactor)
      cache.instance_variable_get(:@clients)[key] = described_class::Entry.new(:fake, WeakRef.new(Object.new))

      client = cache.client_for(endpoint, config)

      expect(client).not_to eq(:fake)
    end.wait
  end

  it 'raises when called outside a reactor' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    expect { cache.client_for(endpoint, config) }.to raise_error(Async::Aws::NoReactorError)
  end

  it 'raises on invalid ssl_cert path' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_cert: '/nope/cert.pem')

    Async do
      expect { cache.client_for(endpoint, config) }.to raise_error(ArgumentError, /ssl_cert/)
    end.wait
  end

  it 'raises on empty ssl_cert string' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_cert: '')

    Async do
      expect { cache.client_for(endpoint, config) }.to raise_error(ArgumentError, /ssl_cert cannot be empty/)
    end.wait
  end

  it 'raises on empty ssl_key string' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_key: '')

    Async do
      expect { cache.client_for(endpoint, config) }.to raise_error(ArgumentError, /ssl_key cannot be empty/)
    end.wait
  end

  it 'raises on invalid ssl_key path' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_key: '/nope/key.pem')

    Async do
      expect { cache.client_for(endpoint, config) }.to raise_error(ArgumentError, /ssl_key/)
    end.wait
  end
end
