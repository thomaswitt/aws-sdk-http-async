require_relative '../spec_helper'
require 'tempfile'
require 'base64'
require 'timeout'
require 'async/barrier'

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

  it 'creates different clients when idle timeout differs' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config_a = SpecHelper.build_config(async_http_idle_timeout: 5)
    config_b = SpecHelper.build_config(async_http_idle_timeout: 10)

    Async do
      first = cache.client_for(endpoint, config_a)
      second = cache.client_for(endpoint, config_b)

      expect(first).not_to be(second)
    end.wait
  end

  it 'treats http_open_timeout <= 0 as disabled' do
    cache = described_class.new
    config = SpecHelper.build_config(http_open_timeout: 0, async_http_idle_timeout: 7)

    timeout = cache.send(:build_timeout, config)

    expect(timeout).to eq(7)
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

    tunnels = instance_double(Async::Aws::ClientCache::TunnelEndpoint, close: nil)
    client = Async::Aws::ClientCache::ProxyClient.new(target, proxy, tunnels)
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

    tunnels = instance_double(Async::Aws::ClientCache::TunnelEndpoint, close: nil)
    client = Async::Aws::ClientCache::ProxyClient.new(target, proxy, tunnels)
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

  it 'stops waiting for a client of the current reactor after the clear! timeout' do
    cache = described_class.new
    client = Class.new do
      def close
        sleep 5
      end
    end.new
    allow(cache).to receive(:build_client).and_return(client)

    Async do
      cache.client_for(URI('https://example.com'), SpecHelper.build_config)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      cache.clear!(timeout: 0.01)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(cache.size).to eq(0)
    end.wait
  end

  it 'never closes the clients of another running reactor' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config
    closed = []
    fake = Class.new do
      def initialize(closed)
        @closed = closed
      end

      def close
        @closed << self
      end
    end
    allow(cache).to receive(:build_client) { fake.new(closed) }

    ready = Queue.new
    release = Queue.new
    other_reactor = Thread.new do
      Sync do
        ready << cache.client_for(endpoint, config)
        release.pop
      end
    end
    other = ready.pop

    mine = Sync do
      cache.client_for(endpoint, config).tap { cache.clear! }
    end

    expect(closed).to eq([mine])
    expect(cache.size).to eq(1)

    # Not from outside a reactor either: the sockets belong to that reactor's thread.
    cache.clear!

    expect(closed).to eq([mine])
    expect(cache.size).to eq(1)

    release << true
    other_reactor.join
    cache.clear!

    expect(closed).to eq([mine, other])
    expect(cache.size).to eq(0)
  ensure
    release << true
    other_reactor&.join
  end

  it 'closes a client on release when it was cleared while in use' do
    cache = described_class.new
    closes = 0
    client = Class.new do
      define_method(:close) { closes += 1 }
    end.new
    allow(cache).to receive(:build_client).and_return(client)

    Sync do
      cache.with_client(URI('https://example.com'), SpecHelper.build_config) do
        # Timed: without a timeout clear! would wait for this very request.
        cache.clear!(timeout: 0.01)
        # This client shows no pool whose connections could be closed under the
        # request, so it is left to the request that still uses it.
        expect(closes).to eq(0)
      end
    end

    expect(closes).to eq(1)
    expect(cache.size).to eq(0)
  end

  it "lets the caller's own timeout end a clear! that is closing a client" do
    cache = described_class.new
    closes = 0
    slow = Class.new do
      define_method(:close) do
        closes += 1
        sleep 0.1
      end
    end
    allow(cache).to receive(:build_client) { slow.new }

    Async do |task|
      cache.client_for(URI('https://example.com'), SpecHelper.build_config)

      expect { task.with_timeout(0.02) { cache.clear! } }.to raise_error(Async::TimeoutError)

      # Interrupted in its close, the client is closed again, without the caller's deadline.
      expect(closes).to eq(2)
      expect(cache.size).to eq(0)
    end.wait
  end

  it 'waits in a timed clear! for a request on a client that shows no pool' do
    cache = described_class.new
    closes = 0
    client = Class.new { define_method(:close) { closes += 1 } }.new
    allow(cache).to receive(:build_client).and_return(client)

    Async do |task|
      finished = false
      request = task.async do
        cache.with_client(URI('https://example.com'), SpecHelper.build_config) do
          sleep 0.05
          finished = true
        end
      end

      cache.clear!(timeout: 1)

      expect(finished).to be(true)
      expect(closes).to be >= 1
      request.wait
    end.wait
  end

  it 'keeps adjoining values and values of different types apart in the cache key' do
    cache = described_class.new
    reactor = Object.new
    key = ->(**overrides) { cache.send(:cache_key, URI('https://example.com'), SpecHelper.build_config(**overrides), reactor) }

    expect(key.call(async_http_connection_limit: 50)).not_to eq(key.call(async_http_connection_limit: '50'))
    expect(key.call(ssl_ca_bundle: '/a|ca_dir=/b', ssl_ca_directory: '')).not_to eq(
      key.call(ssl_ca_bundle: '/a', ssl_ca_directory: '/b|ca_dir='),
    )
  end

  it 'does not retire a connection that served a request while another one was being retired' do
    connection = Struct.new(:count)
    first = connection.new(1)
    second = connection.new(7)
    pool = Class.new do
      attr_reader :resources, :retired

      def initialize(resources)
        @resources = resources
        @retired = []
      end

      # Closing a connection switches fibers: the other one serves a request meanwhile.
      def retire(connection)
        @retired << connection
        @resources.delete(connection)
        @resources.each_key { it.count += 1 }
      end
    end.new({ first => 0, second => 0 }.compare_by_identity)
    policy = described_class::IdlePolicy.new(5)
    checks = 0
    allow(policy).to receive(:sleep) { raise StopIteration if (checks += 1) > 2 }

    expect { policy.call(pool) }.to raise_error(StopIteration)

    expect(pool.retired).to eq([first])
  end

  it 'applies one deadline to all clients of a timed clear!' do
    cache = described_class.new
    config = SpecHelper.build_config
    slow = Class.new do
      def close
        sleep 5
      end
    end
    allow(cache).to receive(:build_client) { slow.new }

    Async do |task|
      %w[a b c].each { cache.client_for(URI("https://#{it}.example.com"), config) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # One deadline: about 0.3 s. A deadline per client would take 0.9 s.
      task.with_timeout(2) { cache.clear!(timeout: 0.3) }

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.6
      expect(cache.size).to eq(0)
    end.wait
  end

  it 'does not scan the cache on release while the reactor is within its bound' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 2)
    endpoints = %w[a b].map { URI("https://#{it}.example.com") }
    allow(cache).to receive(:build_client) { instance_double(Async::HTTP::Client, close: nil) }

    ready = Queue.new
    release = Queue.new
    other_reactor = Thread.new do
      Sync do
        endpoints.each { cache.client_for(it, config) }
        ready << true
        release.pop
      end
    end
    ready.pop

    Sync do
      endpoints.each { |endpoint| cache.with_client(endpoint, config) { nil } }
      # Four entries in the process, two per reactor: nobody is over the bound of two.
      expect(cache.size).to eq(4)
      allow(cache).to receive(:evict_entries_locked).and_call_original

      3.times { cache.with_client(endpoints.first, config) { nil } }

      expect(cache).not_to have_received(:evict_entries_locked)
    end
  ensure
    release << true
    other_reactor&.join
  end

  it 'counts a request as finished even if it is cancelled while waiting for the cache lock' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config
    allow(cache).to receive(:build_client).and_return(instance_double(Async::HTTP::Client, close: nil))
    lock = cache.instance_variable_get(:@mutex)
    locked = Queue.new
    unlock = Queue.new

    Sync do |task|
      gate = Async::Condition.new
      inside = false
      user = task.async do
        cache.with_client(endpoint, config) do
          inside = true
          gate.wait
        end
      end
      task.yield until inside
      entry = cache.instance_variable_get(:@clients).values.first
      expect(entry.inflight).to eq(1)

      holder = Thread.new do
        lock.synchronize do
          locked << true
          unlock.pop
        end
      end
      locked.pop
      gate.signal
      task.yield
      user.stop

      expect(entry.inflight).to eq(0)
      unlock << true
      holder.join
      user.wait
    end
  end

  it 'does not hand out a client built by another Async::HTTP::Client implementation' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config

    Sync do
      real = cache.client_for(endpoint, config)
      # WebMock swaps the constant when it is enabled; a client cached before
      # that would bypass its stubs and its ban on real connections.
      stub_const('Async::HTTP::Client', Class.new(Async::HTTP::Client))

      expect(cache.client_for(endpoint, config)).not_to be(real)
    end
  end

  it 'waits in clear! for a request that has not opened a connection yet' do
    cache = described_class.new
    # No pool to look at: only the in-flight count says the client is in use.
    client = Class.new do
      def close; end
    end.new
    allow(cache).to receive(:build_client).and_return(client)

    Sync do |task|
      connecting = Async::Condition.new
      inside = false
      request = task.async do
        cache.with_client(URI('https://example.com'), SpecHelper.build_config) do
          inside = true
          connecting.wait
        end
      end
      task.yield until inside

      shutdown = task.async { cache.clear! }
      3.times { task.yield }
      expect(shutdown).not_to be_finished

      connecting.signal
      request.wait
      task.with_timeout(2) { shutdown.wait }
      expect(cache.size).to eq(0)
    end
  end

  it 'keeps TLS settings that differ in effect apart in the cache key' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    reactor = Object.new
    key = ->(**overrides) { cache.send(:cache_key, endpoint, SpecHelper.build_config(**overrides), reactor) }

    # A truthy string is not the boolean false.
    expect(key.call(ssl_verify_peer: false)).not_to eq(key.call(ssl_verify_peer: 'false'))

    # A relative path names a different file in a different working directory.
    relative = %i[ssl_cert ssl_key ssl_ca_bundle ssl_ca_directory].map do |option|
      Array.new(2) { Dir.mktmpdir { |dir| Dir.chdir(dir) { key.call(option => 'tls/file.pem') } } }
    end
    expect(relative).to all(satisfy { |first, second| first != second })
    # Not normalized: after a symlink, `..` is not the lexical parent.
    expect(key.call(ssl_cert: '/tmp/a.pem')).not_to eq(key.call(ssl_cert: '/tmp/tls/../a.pem'))
  end

  it 'still finds an entry after the caller changed a path of its config in place' do
    cache = described_class.new
    directory = +'/etc/ssl/certs'
    config = SpecHelper.build_config(ssl_ca_directory: directory)
    closed = 0
    fake = Class.new { define_method(:close) { closed += 1 } }
    allow(cache).to receive(:build_client) { fake.new }

    Sync do
      cache.with_client(URI('https://example.com'), config) { nil }
      directory << '-other'
      cache.clear!

      expect(cache.size).to eq(0)
      expect(closed).to eq(1)
    end
  end

  # OpenSSL reads them when the context is first used, which can be after the
  # working directory changed.
  it 'hands relative CA paths to OpenSSL as the files they named when the client was built' do
    cache = described_class.new
    config = SpecHelper.build_config(ssl_ca_bundle: 'tls/ca.pem', ssl_ca_directory: 'tls/certs')

    built_in, context = Dir.mktmpdir do |dir|
      Dir.chdir(dir) { [Dir.pwd, cache.send(:ssl_context, config, URI('https://example.com'))] }
    end

    expect(context.ca_file).to eq(File.join(built_in, 'tls/ca.pem'))
    expect(context.ca_path).to eq(File.join(built_in, 'tls/certs'))
  end

  # The key and the client read the working directory at different moments.
  it 'does not cache a client under a key that names other settings than the ones it was built with' do
    cache = described_class.new
    endpoint = URI('https://example.com')
    config = SpecHelper.build_config(ssl_ca_bundle: 'tls/ca.pem')
    origin = Dir.pwd
    built_in = []
    closed = []
    fake = Class.new do
      define_method(:initialize) { |directory| @directory = directory }
      define_method(:close) { closed << @directory }
    end

    Dir.mktmpdir do |first|
      Dir.mktmpdir do |second|
        allow(cache).to receive(:build_client) do
          built_in << Dir.pwd
          # The working directory changes while the first client is built.
          Dir.chdir(second) if built_in.size == 1
          fake.new(built_in.last)
        end

        Sync do
          Dir.chdir(first)
          used = cache.with_client(endpoint, config) { it.instance_variable_get(:@directory) }
          in_second = Dir.pwd

          expect(used).to eq(in_second)
          expect(closed.size).to eq(1)

          # Back in the first directory, the client built for the second is not served.
          Dir.chdir(first)
          expect(cache.with_client(endpoint, config) { it.instance_variable_get(:@directory) }).to eq(Dir.pwd)
          expect(built_in.size).to eq(3)
        end
      ensure
        Dir.chdir(origin)
      end
    end
  end

  # An upload can go on after the server answered: nothing counts the client
  # as in use then, but its pool is busy and its close waits for the upload.
  it 'does not make a call wait for the close of an evicted client that is still busy' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 1)
    uploading = true
    finished = Async::Condition.new
    closed = []
    pool = Class.new { define_method(:busy?) { uploading } }.new
    fake = Class.new do
      define_method(:initialize) { |name| @name = name }
      define_method(:pool) { pool }
      define_method(:close) do
        finished.wait if uploading
        closed << @name
      end
    end
    allow(cache).to receive(:build_client).and_return(fake.new(:first), fake.new(:second))

    Sync do |task|
      cache.with_client(URI('https://first.example.com'), config) { nil }

      reached = false
      task.with_timeout(1) { cache.with_client(URI('https://second.example.com'), config) { reached = true } }
      expect(reached).to be(true)
      expect(closed).to be_empty

      uploading = false
      finished.signal
      task.yield
      expect(closed).to eq([:first])
    end
  end

  it 'trims back to the LRU bound once a burst of in-flight clients is released' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 1)
    endpoints = %w[a b c].map { URI("https://#{it}.example.com") }
    closed = 0
    fake = Class.new do
      define_method(:close) { closed += 1 }
    end
    allow(cache).to receive(:build_client) { fake.new }

    Sync do |task|
      hold = Async::Condition.new
      holding = 0
      users = endpoints.map do |endpoint|
        task.async do
          cache.with_client(endpoint, config) do
            holding += 1
            hold.wait
          end
        end
      end
      task.yield until holding == 3

      # In-flight clients are never evicted, so the burst exceeds the bound.
      expect(cache.size).to eq(3)

      hold.signal
      users.each(&:wait)

      expect(cache.size).to eq(1)
      expect(closed).to eq(2)
    end
  end

  it 'finishes closing evicted clients and releases the entry when the task is stopped meanwhile' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 1)
    closed = []
    slow_to_close = Class.new do
      define_method(:close) do
        sleep 0.1
        closed << self
      end
    end
    allow(cache).to receive(:build_client) { slow_to_close.new }

    Sync do |task|
      first = cache.client_for(URI('https://a.example.com'), config)
      second = cache.client_for(URI('https://b.example.com'), config)
      expect(closed).to eq([first])

      # The third client pushes out the second, whose close takes a while.
      user = task.async { cache.with_client(URI('https://c.example.com'), config) { nil } }
      task.yield
      user.stop
      user.wait

      # The evicted client is out of the cache: abandoning its close would leak it.
      expect(closed).to eq([first, second])
      expect(cache.instance_variable_get(:@clients).values.map(&:inflight)).to eq([0])
    end
  end

  it 'validates an empty ssl_key even when a client for the same endpoint is cached' do
    cache = described_class.new
    endpoint = URI('https://example.com')

    Async do
      cache.client_for(endpoint, SpecHelper.build_config)

      expect { cache.client_for(endpoint, SpecHelper.build_config(ssl_key: '')) }.to raise_error(ArgumentError, /ssl_key/)
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

  it 'closes a client from outside its reactor only once that reactor has finished' do
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

    expect(closed[:value]).to be(false)
    expect(cache.size).to eq(1)

    reactor.close
    cache.clear!

    expect(closed[:value]).to be(true)
    expect(cache.size).to eq(0)
  ensure
    # Async::Reactor.new installed itself as this thread's scheduler.
    Fiber.set_scheduler(nil)
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

  it 'does not evict in-flight entries during LRU eviction' do
    cache = described_class.new
    config = SpecHelper.build_config(async_http_max_cached_clients: 1)
    reactor = Async::Reactor.new

    inflight = described_class::Entry.new(:client_a, WeakRef.new(reactor), 1)
    idle = described_class::Entry.new(:client_b, WeakRef.new(reactor), 0)

    clients = cache.instance_variable_get(:@clients)
    clients['a'] = inflight
    clients['b'] = idle

    evicted = cache.send(:evict_entries_locked, config, reactor)

    expect(evicted).to contain_exactly(idle)
    expect(clients.values).to include(inflight)
  ensure
    # Async::Reactor.new installed itself as this thread's scheduler.
    Fiber.set_scheduler(nil)
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

  it 'closes every evicted client when one stop reaches the request twice (barrier under a stopped parent)' do
    cache = described_class.new
    closed = []
    slow_to_close = Class.new do
      define_method(:close) do
        sleep 0.05
        closed << self
      end
    end
    allow(cache).to receive(:build_client) { slow_to_close.new }

    Sync do |task|
      idle = %w[a b c].map { cache.client_for(URI("https://#{it}.example.com"), SpecHelper.build_config) }

      # A client with a smaller bound evicts all three in one batch.
      tight = SpecHelper.build_config(async_http_max_cached_clients: 1)
      parent = task.async do
        barrier = Async::Barrier.new
        barrier.async { cache.with_client(URI('https://d.example.com'), tight) { nil } }
        barrier.wait
      ensure
        # The request gets this cancel and then a second one from the stopped
        # parent; `Task#defer_cancel` holds back only the first.
        barrier.stop
      end
      parent.stop
      parent.wait
      sleep 0.3

      # The evicted clients are out of the cache: nothing else would close them.
      expect(closed).to match_array(idle)
      expect(cache.size).to eq(1)
    end
  end

  it 'closes every client of a clear! whose task is stopped twice' do
    cache = described_class.new
    closed = []
    slow_to_close = Class.new do
      define_method(:close) do
        sleep 0.05
        closed << self
      end
    end
    allow(cache).to receive(:build_client) { slow_to_close.new }

    Sync do |task|
      idle = %w[a b c].map { cache.client_for(URI("https://#{it}.example.com"), SpecHelper.build_config) }

      shutdown = task.async { cache.clear! }
      2.times { shutdown.stop }
      shutdown.wait
      sleep 0.3

      expect(cache.size).to eq(0)
      expect(closed).to match_array(idle)
    end
  end

  [100, nil].each do |other_limit|
    it "still trims a burst after a client with async_http_max_cached_clients=#{other_limit.inspect} used the shared cache" do
      cache = described_class.new
      small = SpecHelper.build_config(async_http_max_cached_clients: 1)
      other = SpecHelper.build_config(async_http_max_cached_clients: other_limit)
      closed = 0
      fake = Class.new do
        define_method(:close) { closed += 1 }
      end
      allow(cache).to receive(:build_client) { fake.new }

      Sync do |task|
        hold = Async::Condition.new
        holding = 0
        users = %w[a b].map do |name|
          task.async do
            cache.with_client(URI("https://#{name}.example.com"), small) do
              holding += 1
              hold.wait
            end
          end
        end
        task.yield until holding == 2

        # Another client shares the cache; its bound must not cancel the pending trim.
        cache.with_client(URI('https://c.example.com'), other) { nil }

        hold.signal
        users.each(&:wait)

        expect(cache.size).to eq(1)
        expect(closed).to eq(2)
      end
    end
  end

  it 'bounds a timed clear! while requests are queued for a connection' do
    cache = described_class.new
    connection = Class.new do
      def concurrency = 1
      def viable? = true
      def reusable? = true

      # Closing a real connection yields to the reactor as well.
      def close = sleep(0.001)
    end
    protocol = Class.new do
      define_method(:client) { |_stream| connection.new }
    end.new
    endpoint = instance_double(Async::HTTP::Endpoint, connect: nil)
    client = Async::HTTP::Client.new(
      endpoint, protocol:, scheme: 'https', authority: 'example.com', retries: 0, limit: 2,
    )
    allow(cache).to receive(:build_client).and_return(client)

    Sync do |task|
      # Two requests hold the two connections, two more wait for one.
      requests = 4.times.map do
        task.async do
          cache.with_client(URI('https://example.com'), SpecHelper.build_config) { it.pool.acquire { sleep } }
        end
      end
      sleep 0.01
      expect(client.pool.size).to eq(2)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      task.with_timeout(2) { cache.clear!(timeout: 0.05) }

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(client.pool).not_to be_busy
    ensure
      requests&.each(&:stop)
    end
  end

  describe '.default' do
    it 'returns one process-wide cache, also across threads' do
      caches = 8.times.map { Thread.new { described_class.default } }.map(&:value)

      expect(caches).to all(be(described_class.default))
    end
  end

  describe 'entries of a finished reactor' do
    let(:endpoint) { URI('https://example.com') }
    let(:config) { SpecHelper.build_config }

    # Caches `client` from a reactor on another thread and returns that (closed) reactor.
    def cache_in_finished_reactor(cache)
      Thread.new do
        Sync do |task|
          cache.client_for(endpoint, config)
          task.reactor
        end
      end.value
    end

    it 'drops them on the next insert and closes idle clients' do
      cache = described_class.new
      orphan = instance_double(Async::HTTP::Client, close: nil, pool: instance_double(Async::Pool::Controller, busy?: false))
      allow(cache).to receive(:build_client).and_return(orphan, instance_double(Async::HTTP::Client, close: nil))

      reactor = cache_in_finished_reactor(cache)
      expect(reactor).to be_closed
      expect(cache.size).to eq(1)

      Sync { cache.client_for(endpoint, config) }

      expect(cache.size).to eq(1)
      expect(orphan).to have_received(:close)
    end

    it 'never waits for a busy client, because nothing is left to release it' do
      cache = described_class.new
      orphan = instance_double(Async::HTTP::Client, close: nil, pool: instance_double(Async::Pool::Controller, busy?: true))
      allow(cache).to receive(:build_client).and_return(orphan)

      reactor = cache_in_finished_reactor(cache)
      expect(reactor).to be_closed
      cache.clear!

      expect(cache.size).to eq(0)
      expect(orphan).not_to have_received(:close)
    end
  end

  it 'exposes the target and the proxy pool of a proxy client' do
    target_pool = instance_double(Async::Pool::Controller)
    proxy_pool = instance_double(Async::Pool::Controller)
    client = described_class::ProxyClient.new(
      instance_double(Async::HTTP::Client, pool: target_pool),
      instance_double(Async::HTTP::Client, pool: proxy_pool),
      instance_double(described_class::TunnelEndpoint),
    )

    expect(client.pools).to eq([target_pool, proxy_pool])
  end

  describe 'fork safety' do
    let(:endpoint) { URI('https://example.com') }
    let(:config) { SpecHelper.build_config }

    it 'drops inherited entries without closing them when the pid changes' do
      cache = described_class.new
      inherited = instance_double(Async::HTTP::Client, close: nil)
      allow(cache).to receive(:build_client).and_return(inherited)
      Async { cache.client_for(endpoint, config) }.wait
      expect(cache.size).to eq(1)

      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      expect(cache.size).to eq(0)
      cache.clear!
      expect(inherited).not_to have_received(:close)
    end

    it 'with_client does not hand an inherited client to a new process' do
      cache = described_class.new
      inherited = instance_double(Async::HTTP::Client, close: nil)
      own = instance_double(Async::HTTP::Client, close: nil)
      allow(cache).to receive(:build_client).and_return(inherited, own)

      Sync do
        cache.with_client(endpoint, config) { nil }
        allow(Process).to receive(:pid).and_return(Process.pid + 1)

        used = cache.with_client(endpoint, config) { it }

        expect(used).to equal(own)
        expect(cache.instance_variable_get(:@clients).size).to eq(1)
        expect(inherited).not_to have_received(:close)
      end
    end

    it 'clear! as the first call in a new process does not close inherited clients' do
      cache = described_class.new
      inherited = instance_double(Async::HTTP::Client, close: nil)
      allow(cache).to receive(:build_client).and_return(inherited)
      Async { cache.with_client(endpoint, config) { nil } }.wait

      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      cache.clear!

      expect(inherited).not_to have_received(:close)
      expect(cache.instance_variable_get(:@clients)).to be_empty
    end

    it 'gives a forked child its own client and leaves the parent sockets alone', if: Process.respond_to?(:fork) do
      cache = described_class.new
      closed = Queue.new
      fake = Class.new do
        def initialize(closed)
          @closed = closed
        end

        def close
          @closed << true
        end
      end
      allow(cache).to receive(:build_client) { fake.new(closed) }

      # The parent keeps a live reactor (and its cached client) on another thread.
      ready = Queue.new
      release = Queue.new
      parent_reactor = Thread.new do
        Sync do
          ready << cache.client_for(endpoint, config)
          release.pop
        end
      end
      parent_client = ready.pop

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        child_client = Sync { cache.client_for(endpoint, config) }
        size = cache.size
        cache.clear!
        # The child's own client is closed by clear!; the parent's must not be.
        writer.write([child_client.equal?(parent_client), size, closed.size].join(','))
      ensure
        writer.close
        exit!(0)
      end
      writer.close

      expect(reader.wait_readable(10)).to be_truthy
      expect(reader.read).to eq('false,1,1')
      expect(cache.size).to eq(1)
      expect(closed).to be_empty
    ensure
      reader&.close
      if pid
        Process.kill('KILL', pid) rescue nil
        Process.wait(pid)
      end
      release << true
      parent_reactor&.join
    end
  end
end
