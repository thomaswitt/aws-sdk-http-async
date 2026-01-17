require_relative '../spec_helper'
require 'socket'
require 'uri'

RSpec.describe 'Async::Aws integration' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  class CountingServer < Async::HTTP::Server
    attr_reader :connection_count

    def initialize(app, endpoint)
      super
      @connection_count = 0
    end

    def accept(peer, address, task: Async::Task.current)
      @connection_count += 1
      super
    end
  end

  def with_server(app)
    port = SpecHelper.available_port
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
    server = CountingServer.new(app, endpoint)

    Sync do |task|
      server_task = server.run

      begin
        task.sleep(0.05)
        yield endpoint, server
      ensure
        server_task.stop
        task.sleep(0.05)
      end
    end
  end

  def with_tls_server(app, client_host: '127.0.0.1', bind_host: '127.0.0.1')
    port = SpecHelper.available_port
    ssl_context = self_signed_context
    server_endpoint = Async::HTTP::Endpoint.parse(
      "https://#{bind_host}:#{port}",
      ssl_context:,
    )
    client_endpoint = Async::HTTP::Endpoint.parse(
      "https://#{client_host}:#{port}",
    )
    server = CountingServer.new(app, server_endpoint)

    Sync do |task|
      server_task = server.run

      begin
        task.sleep(0.05)
        yield client_endpoint, server
      ensure
        server_task.stop
        task.sleep(0.05)
      end
    end
  end

  def self_signed_context
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/CN=localhost')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
    cert.add_extension(ef.create_extension('authorityKeyIdentifier', 'keyid:always,issuer:always'))
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = cert
      context.key = key
    end
  end

  it 'completes a basic request/response' do
    with_server(->(_request) { Protocol::HTTP::Response[200, {}, ['OK']] }) do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)
      context = SpecHelper.build_context(endpoint: endpoint.url)

      handler.call(context)

      response = context.http_response
      response.body.rewind
      expect(response.status_code).to eq(200)
      expect(response.body.read).to eq('OK')
    ensure
      cache.clear!(timeout: 1)
    end
  end

  it 'reuses connections for sequential requests' do
    with_server(->(_request) { Protocol::HTTP::Response[200, {}, ['OK']] }) do |endpoint, server|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)

      2.times do
        context = SpecHelper.build_context(endpoint: endpoint.url)
        handler.call(context)
      end

      expect(server.connection_count).to eq(1)
    ensure
      cache.clear!(timeout: 1)
    end
  end

  it 'times out on slow responses (connect phase)' do
    with_server(lambda do |_request|
      Async::Task.current.sleep(0.2)
      Protocol::HTTP::Response[200, {}, ['OK']]
    end) do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)
      context = SpecHelper.build_context(
        endpoint: endpoint.url,
        config_overrides: { http_open_timeout: 0.05 },
      )

      handler.call(context)

      expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
    ensure
      cache.clear!(timeout: 1)
    end
  end

  it 'times out on slow body reads' do
    with_server(lambda do |_request|
      body = Async::HTTP::Body::Writable.new

      Async::Task.current.async do |task|
        task.sleep(0.2)
        body.write('OK')
        body.close
      end

      Protocol::HTTP::Response[200, {}, body]
    end) do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)
      context = SpecHelper.build_context(
        endpoint: endpoint.url,
        config_overrides: { http_read_timeout: 0.05 },
      )

      handler.call(context)

      expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
    ensure
      cache.clear!(timeout: 1)
    end
  end

  it 'streams large responses without error' do
    payload_size = 2 * 1024 * 1024
    chunk = 'a' * 64 * 1024

    with_server(lambda do |_request|
      chunks = Array.new(payload_size / chunk.bytesize, chunk)
      body = Protocol::HTTP::Body::Buffered.new(chunks)
      Protocol::HTTP::Response[200, {}, body]
    end) do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)
      context = SpecHelper.build_context(endpoint: endpoint.url)

      handler.call(context)

      response = context.http_response
      response.body.rewind
      expect(response.status_code).to eq(200)
      expect(response.body.read.bytesize).to eq(payload_size)
    ensure
      cache.clear!(timeout: 1)
    end
  end

  it 'proxies requests via CONNECT', :docker do
    received = Async::Queue.new
    with_tls_server(lambda do |request|
      received.enqueue(request.path)
      Protocol::HTTP::Response[200, { 'connection' => 'close' }, ['OK']]
    end, client_host: 'host.docker.internal', bind_host: '0.0.0.0') do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      begin
        skip 'tinyproxy not running (docker compose up)' unless SpecHelper.tinyproxy_available?

        config = SpecHelper.build_config(
          http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
          http_read_timeout: 5,
          http_open_timeout: 5,
          ssl_verify_peer: false,
        )
        client = cache.client_for(endpoint.url, config)
        request = Protocol::HTTP::Request['GET', '/', { 'connection' => 'close' }]
        response = Async::Task.current.with_timeout(10) { client.call(request) }

        expect(Async::Task.current.with_timeout(1) { received.dequeue }).to eq('/')
        expect(response.status).to eq(200)
        expect(Async::Task.current.with_timeout(10) { response.read }).to eq('OK')
        response.close
      ensure
        cache.clear!(timeout: 1)
      end
    end
  end

  it 'applies toxiproxy latency to CONNECT tunnel', :docker do
    received = Async::Queue.new
    with_tls_server(lambda do |request|
      received.enqueue(request.path)
      Protocol::HTTP::Response[200, { 'connection' => 'close' }, ['OK']]
    end, client_host: 'host.docker.internal', bind_host: '0.0.0.0') do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      proxy_name = 'tls_proxy'
      begin
        skip 'tinyproxy not running (docker compose up)' unless SpecHelper.tinyproxy_available?
        skip 'toxiproxy not running (docker compose up)' unless SpecHelper.toxiproxy_available?

        SpecHelper.toxiproxy_delete(proxy_name)
        SpecHelper.toxiproxy_create(
          name: proxy_name,
          listen: '0.0.0.0:8080',
          upstream: "host.docker.internal:#{endpoint.url.port}",
        )
        SpecHelper.toxiproxy_add_toxic(
          name: proxy_name,
          toxic_name: 'latency-200ms',
          type: 'latency',
          attributes: { latency: 200 },
        )

        proxy_endpoint = URI('https://host.docker.internal:8080')
        handler = Async::Aws::Handler.new(client_cache: cache)
        context = SpecHelper.build_context(
          endpoint: proxy_endpoint,
          headers: { 'connection' => 'close' },
          config_overrides: {
            http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
            http_read_timeout: 5,
            http_open_timeout: 5,
            ssl_verify_peer: false,
          },
        )

        handler.call(context)

        expect(Async::Task.current.with_timeout(1) { received.dequeue }).to eq('/')
        expect(context.http_response.status_code).to eq(200)
      ensure
        SpecHelper.toxiproxy_delete(proxy_name)
        cache.clear!(timeout: 1)
      end
    end
  end

  it 'surfaces toxiproxy connection resets', :docker do
    with_tls_server(lambda do |_request|
      Protocol::HTTP::Response[200, { 'connection' => 'close' }, ['OK']]
    end, client_host: 'host.docker.internal', bind_host: '0.0.0.0') do |endpoint, _server|
      cache = Async::Aws::ClientCache.new
      proxy_name = 'tls_proxy'
      begin
        skip 'tinyproxy not running (docker compose up)' unless SpecHelper.tinyproxy_available?
        skip 'toxiproxy not running (docker compose up)' unless SpecHelper.toxiproxy_available?

        SpecHelper.toxiproxy_delete(proxy_name)
        SpecHelper.toxiproxy_create(
          name: proxy_name,
          listen: '0.0.0.0:8080',
          upstream: "host.docker.internal:#{endpoint.url.port}",
        )
        SpecHelper.toxiproxy_add_toxic(
          name: proxy_name,
          toxic_name: 'reset-peer',
          type: 'reset_peer',
          attributes: { timeout: 100 },
        )

        proxy_endpoint = URI('https://host.docker.internal:8080')
        handler = Async::Aws::Handler.new(client_cache: cache)
        context = SpecHelper.build_context(
          endpoint: proxy_endpoint,
          headers: { 'connection' => 'close' },
          config_overrides: {
            http_proxy: SpecHelper::TINYPROXY_ENDPOINT,
            http_read_timeout: 5,
            http_open_timeout: 5,
            ssl_verify_peer: false,
          },
        )

        handler.call(context)

        expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
      ensure
        SpecHelper.toxiproxy_delete(proxy_name)
        cache.clear!(timeout: 1)
      end
    end
  end
end
