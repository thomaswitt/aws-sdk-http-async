$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'bundler/setup'
require 'json'
require 'logger'
require 'net/http'
require 'socket'
require 'rspec'
require 'console'

Console.logger = Logger.new(nil)
Console.logger.level = Logger::FATAL if Console.logger.respond_to?(:level=)

require 'async'
require 'async/http'
require 'protocol/http'
require 'aws-sdk-core'
require 'aws-sdk-http-async'
require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'

module SpecHelper
  DYNAMODB_ENDPOINT = 'http://localhost:8011'.freeze
  MINIO_ENDPOINT = 'http://localhost:9010'.freeze
  TOXIPROXY_ENDPOINT = 'http://localhost:8474'.freeze
  TINYPROXY_ENDPOINT = 'http://127.0.0.1:8888'.freeze

  class << self
    # @yield Runs the block with localhost net connect enabled for WebMock, if loaded.
    # @return [void]
    def with_webmock_localhost
      return yield unless defined?(WebMock)

      config = WebMock::Config.instance
      previous = {
        allow_net_connect: config.allow_net_connect,
        allow_localhost: config.allow_localhost,
        allow: config.allow,
      }

      WebMock.disable_net_connect!(allow_localhost: true, allow: previous[:allow])
      yield
    ensure
      if defined?(WebMock)
        config = WebMock::Config.instance
        config.allow_net_connect = previous[:allow_net_connect]
        config.allow_localhost = previous[:allow_localhost]
        config.allow = previous[:allow]
      end
    end

    # @param overrides [Hash]
    # @return [Seahorse::Client::Configuration]
    def build_config(overrides = {})
      config = Seahorse::Client::Configuration.new
      Async::Aws::HttpPlugin.new.add_options(config)
      config.add_option(:stub_responses, false)

      defaults = {
        async_http_connection_limit: 5,
        async_http_force_accept_encoding: true,
        async_http_body_warn_bytes: 5 * 1024 * 1024,
        async_http_max_buffer_bytes: 5 * 1024 * 1024,
        async_http_idle_timeout: 30,
        async_http_header_timeout: nil,
        async_http_max_cached_clients: 100,
        async_http_streaming_uploads: :auto,
        async_http_fallback: :net_http,
        async_http_client_cache: nil,
        http_open_timeout: 1,
        http_read_timeout: 1,
        stub_responses: false,
        ssl_verify_peer: true,
        logger: Logger.new(nil),
      }

      config.build!(defaults.merge(overrides))
    end

    # @param endpoint [URI::HTTP, URI::HTTPS]
    # @param http_method [String]
    # @param headers [Hash]
    # @param body [Object, nil]
    # @param config_overrides [Hash]
    # @return [Seahorse::Client::RequestContext]
    def build_context(endpoint:, http_method: 'GET', headers: {}, body: nil, config_overrides: {})
      http_request = Seahorse::Client::Http::Request.new(
        endpoint:,
        http_method:,
        headers:,
        body:,
      )

      Seahorse::Client::RequestContext.new(
        operation_name: :test,
        config: build_config(config_overrides),
        http_request:,
        http_response: Seahorse::Client::Http::Response.new,
      )
    end

    # @return [Integer]
    def available_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    # @return [Boolean]
    def dynamodb_available?
      uri = URI(DYNAMODB_ENDPOINT)
      Net::HTTP.start(uri.host, uri.port) { |http| http.head('/') }
      true
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::ECONNRESET, SocketError
      false
    end

    # @return [Boolean]
    def minio_available?
      uri = URI("#{MINIO_ENDPOINT}/minio/health/live")
      Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::ECONNRESET, SocketError
      false
    end

    # @return [Boolean]
    def toxiproxy_available?
      uri = URI("#{TOXIPROXY_ENDPOINT}/version")
      Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::ECONNRESET, SocketError
      false
    end

    # @param method [Symbol]
    # @param path [String]
    # @param body [Hash, nil]
    # @return [Net::HTTPResponse]
    def toxiproxy_request(method, path, body: nil)
      uri = URI("#{TOXIPROXY_ENDPOINT}#{path}")
      request_class = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        delete: Net::HTTP::Delete,
      }.fetch(method)
      request = request_class.new(uri)
      if body
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    end

    # @param name [String]
    # @return [void]
    def toxiproxy_delete(name)
      toxiproxy_request(:delete, "/proxies/#{name}")
    rescue StandardError
      nil
    end

    # @param name [String]
    # @param listen [String]
    # @param upstream [String]
    # @return [void]
    def toxiproxy_create(name:, listen:, upstream:)
      response = toxiproxy_request(:post, '/proxies', body: { name:, listen:, upstream: })
      return if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

      raise "toxiproxy create failed: #{response.code} #{response.body}"
    end

    # @param name [String]
    # @param toxic_name [String]
    # @param type [String]
    # @param attributes [Hash]
    # @return [void]
    def toxiproxy_add_toxic(name:, toxic_name:, type:, attributes:)
      response = toxiproxy_request(
        :post,
        "/proxies/#{name}/toxics",
        body: {
          name: toxic_name,
          type:,
          attributes:,
        },
      )
      return if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

      raise "toxiproxy toxic failed: #{response.code} #{response.body}"
    end

    # @return [Boolean]
    def tinyproxy_available?
      uri = URI(TINYPROXY_ENDPOINT)
      socket = TCPSocket.new(uri.host, uri.port)
      socket.close
      true
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError
      false
    end
  end
end
