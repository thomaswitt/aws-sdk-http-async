require 'async/http'
require 'async/http/proxy'
require 'async/aws/errors'
require 'base64'
require 'digest'
require 'openssl'
require 'thread'
require 'uri'
require 'weakref'

module Async
  module Aws
    class ClientCache
      @default_cert_store_mutex = Mutex.new
      @default_cert_store = nil

      def self.default_cert_store
        return @default_cert_store if @default_cert_store

        @default_cert_store_mutex.synchronize do
          return @default_cert_store if @default_cert_store

          store = OpenSSL::X509::Store.new
          store.set_default_paths
          @default_cert_store = store
        end
      end

      Entry = Struct.new(:client, :reactor_ref)

      class ProxyClient
        # @param client [Async::HTTP::Client]
        # @param proxy_client [Async::HTTP::Client]
        # @return [void]
        def initialize(client, proxy_client)
          @client = client
          @proxy_client = proxy_client
        end

        # @param request [Protocol::HTTP::Request]
        # @return [Async::HTTP::Response]
        def call(request, &)
          @client.call(request, &)
        end

        # @return [void]
        def close
          @client.close
        ensure
          @proxy_client.close
        end
      end

      # @return [void]
      def initialize
        @clients = {}
        @mutex = Mutex.new
        @access_count = 0
      end

      # @param endpoint [URI::HTTP, URI::HTTPS]
      # @param config [Seahorse::Client::Configuration]
      # @return [Async::HTTP::Client]
      def client_for(endpoint, config)
        raise NoReactorError, 'Async reactor is required. Wrap calls in Sync { }.' unless Async::Task.current?

        reactor = Async::Task.current.reactor
        key = cache_key(endpoint, config, reactor)
        entry = nil
        stale_entry = nil

        entry = @mutex.synchronize do
          cached = @clients[key]
          if entry_valid_for?(cached, reactor)
            touch_lru!(key, cached)
            cached
          else
            stale_entry = @clients.delete(key) if cached
            nil
          end
        end

        close_entry(stale_entry) if stale_entry
        sweep_dead_entries_if_needed.each { |dead| close_entry(dead) }
        return entry.client if entry

        new_entry = nil
        evicted = []
        used_entry = nil
        stale_existing = nil

        new_entry = Entry.new(build_client(endpoint, config), WeakRef.new(reactor))

        @mutex.synchronize do
          existing = @clients[key]
          if entry_valid_for?(existing, reactor)
            touch_lru!(key, existing)
            used_entry = existing
          else
            stale_existing = existing
            @clients[key] = new_entry
            touch_lru!(key, new_entry)
            used_entry = new_entry
            evicted = evict_entries_locked(config, reactor)
          end
        end

        close_entry(new_entry) if used_entry != new_entry
        close_entry(stale_existing) if stale_existing
        evicted.each { |entry_to_close| close_entry(entry_to_close) }

        used_entry.client
      end

      # Closes all cached clients and clears the cache. Intended for shutdown only.
      #
      # @return [void]
      def clear!(timeout: nil)
        clients = @mutex.synchronize do
          values = @clients.values
          @clients.clear
          values
        end

        clients.each do |client_entry|
          current_reactor = Async::Task.current? ? Async::Task.current.reactor : nil
          owner_reactor = entry_reactor(client_entry)
          if timeout && current_reactor && owner_reactor == current_reactor
            begin
              client = extract_client(client_entry)
              Async::Task.current.with_timeout(timeout, Async::TimeoutError) { client.close if client.respond_to?(:close) }
            rescue Async::TimeoutError
              logger = logger_for
              logger&.warn('[aws-sdk-http-async] force-closing client (timeout)')
            rescue StandardError => e
              logger = logger_for
              logger&.warn("[aws-sdk-http-async] failed to close client: #{e.message}")
            end
          else
            close_entry(client_entry, force: current_reactor.nil?)
          end
        end
      end

      # @return [void]
      def close!
        clear!
      end

      private

      def cache_key(endpoint, config, reactor)
        reactor_id = reactor.object_id
        "#{reactor_id}|#{endpoint.scheme}://#{endpoint.host}:#{endpoint.port}|" \
        "limit=#{config.async_http_connection_limit}|" \
        "timeout=#{config.http_open_timeout}|" \
        "proxy=#{proxy_cache_value(config.http_proxy)}|" \
        "ssl=#{config.ssl_verify_peer}|" \
        "ca_store=#{ssl_cache_value(config.ssl_ca_store)}|" \
        "ca_bundle=#{config.ssl_ca_bundle}|" \
        "ca_dir=#{config.ssl_ca_directory}|" \
        "ssl_cert=#{ssl_cache_value(config.ssl_cert)}|" \
        "ssl_key=#{ssl_cache_value(config.ssl_key)}"
      end

      def entry_valid_for?(entry, reactor)
        return false unless entry.is_a?(Entry)
        ref = entry.reactor_ref
        return false unless ref&.weakref_alive?

        ref.__getobj__.equal?(reactor)
      rescue WeakRef::RefError
        false
      end

      def touch_lru!(key, entry)
        @clients.delete(key)
        @clients[key] = entry
      end

      def evict_entries_locked(config, reactor)
        limit = config.async_http_max_cached_clients
        return [] if limit.nil? || limit <= 0

        evicted = []
        current_size = 0
        dead_keys = []
        @clients.each do |key, entry|
          if entry_dead?(entry)
            dead_keys << key
            evicted << entry
            next
          end
          current_size += 1 if entry_valid_for?(entry, reactor)
        end
        dead_keys.each { |key| @clients.delete(key) }

        while current_size > limit
          key = @clients.keys.find do |candidate|
            entry_valid_for?(@clients[candidate], reactor)
          end
          break unless key

          entry = @clients.delete(key)
          evicted << entry if entry
          current_size -= 1
        end
        evicted
      end

      def close_entry(entry, force: false)
        client = extract_client(entry)
        return unless client.respond_to?(:close)

        reactor = entry_reactor(entry)
        current_reactor = Async::Task.current? ? Async::Task.current.reactor : nil
        if reactor && reactor != current_reactor && !force
          logger = logger_for
          logger&.debug('[aws-sdk-http-async] skipping close from different reactor')
          return
        end
        if reactor && reactor != current_reactor && force
          logger = logger_for
          logger&.debug('[aws-sdk-http-async] force-closing client from different reactor')
        end

        safe_close(client)
      rescue StandardError => e
        logger = logger_for
        logger&.warn("[aws-sdk-http-async] failed to close client: #{e.message}")
      end

      def extract_client(entry)
        return entry.client if entry.is_a?(Entry)

        entry
      end

      def entry_reactor(entry)
        return nil unless entry.is_a?(Entry)

        ref = entry.reactor_ref
        return nil unless ref&.weakref_alive?

        ref.__getobj__
      rescue WeakRef::RefError
        nil
      end

      def entry_dead?(entry)
        return false unless entry.is_a?(Entry)

        ref = entry.reactor_ref
        return true unless ref&.weakref_alive?

        false
      rescue WeakRef::RefError
        true
      end

      def sweep_dead_entries_if_needed
        do_sweep = false
        @mutex.synchronize do
          @access_count += 1
          do_sweep = (@access_count % 100).zero?
        end
        return [] unless do_sweep

        sweep_dead_entries
      end

      def sweep_dead_entries
        dead = []
        @mutex.synchronize do
          dead_keys = []
          @clients.each do |key, entry|
            next unless entry_dead?(entry)

            dead_keys << key
            dead << entry
          end
          dead_keys.each { |key| @clients.delete(key) }
        end
        dead
      end

      def safe_close(client)
        client.close
      rescue StandardError => e
        logger = logger_for
        logger&.warn("[aws-sdk-http-async] failed to close client: #{e.message}")
      end

      def build_client(endpoint, config)
        target_endpoint = build_endpoint(endpoint, config)
        return Async::HTTP::Client.new(
                 target_endpoint,
                 retries: 0,
                 limit: config.async_http_connection_limit,
               ) unless config.http_proxy

        proxy_endpoint = build_proxy_endpoint(config)
        proxy_client = Async::HTTP::Client.new(
          proxy_endpoint,
          retries: 0,
          limit: config.async_http_connection_limit,
        )
        headers = proxy_headers(proxy_endpoint.url)
        proxied_endpoint = proxy_client.proxied_endpoint(target_endpoint, headers)
        client = Async::HTTP::Client.new(
          proxied_endpoint,
          retries: 0,
          limit: config.async_http_connection_limit,
        )
        ProxyClient.new(client, proxy_client)
      end

      def build_endpoint(endpoint, config)
        Async::HTTP::Endpoint.parse(
          endpoint.to_s,
          timeout: build_timeout(config),
          ssl_context: ssl_context(config, endpoint),
        )
      end

      def build_proxy_endpoint(config)
        url = config.http_proxy.to_s
        endpoint = Async::HTTP::Endpoint.parse(
          url,
          timeout: build_timeout(config),
          ssl_context: ssl_context(config, URI.parse(url)),
        )
        endpoint
      end

      def build_timeout(config)
        return config.http_open_timeout if config.http_open_timeout

        idle = config.async_http_idle_timeout
        return idle if idle && idle > 0

        nil
      end

      def ssl_context(config, endpoint)
        return nil unless endpoint.scheme == 'https'

        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.verify_mode = config.ssl_verify_peer ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          if config.ssl_verify_peer && context.respond_to?(:verify_hostname=)
            context.verify_hostname = true
          end
          if config.ssl_ca_store
            context.cert_store = config.ssl_ca_store
          else
            context.ca_file = config.ssl_ca_bundle if config.ssl_ca_bundle
            context.ca_path = config.ssl_ca_directory if config.ssl_ca_directory
            unless config.ssl_ca_bundle || config.ssl_ca_directory
              context.cert_store = self.class.default_cert_store
            end
          end

          cert = load_certificate(config.ssl_cert, config)
          context.cert = cert if cert

          key = load_private_key(config.ssl_key, config)
          context.key = key if key
        end
      end

      def load_certificate(value, _config)
        return nil if value.nil?
        if value.respond_to?(:empty?) && value.empty?
          raise ArgumentError, 'ssl_cert cannot be empty; set to nil to disable or provide a valid path'
        end
        return value if value.is_a?(OpenSSL::X509::Certificate)
        if value.is_a?(String) || value.respond_to?(:to_path)
          path = value.is_a?(String) ? value : value.to_path
          return OpenSSL::X509::Certificate.new(File.read(path))
        end

        raise ArgumentError, "ssl_cert must be an OpenSSL::X509::Certificate or a file path (got #{value.class})"
      rescue StandardError => e
        raise ArgumentError, "failed to load ssl_cert: #{e.message}"
      end

      def load_private_key(value, _config)
        return nil if value.nil?
        if value.respond_to?(:empty?) && value.empty?
          raise ArgumentError, 'ssl_key cannot be empty; set to nil to disable or provide a valid path'
        end
        return value if value.is_a?(OpenSSL::PKey::PKey)
        if value.is_a?(String) || value.respond_to?(:to_path)
          path = value.is_a?(String) ? value : value.to_path
          return OpenSSL::PKey.read(File.read(path))
        end

        raise ArgumentError, "ssl_key must be an OpenSSL::PKey or a file path (got #{value.class})"
      rescue StandardError => e
        raise ArgumentError, "failed to load ssl_key: #{e.message}"
      end

      def ssl_cache_value(value)
        return nil if value.nil?
        return value if value.is_a?(String)
        return value.to_path if value.respond_to?(:to_path)

        value.object_id.to_s
      end

      def proxy_headers(proxy_url)
        return nil unless proxy_url.respond_to?(:user) && proxy_url.user

        user = URI::DEFAULT_PARSER.unescape(proxy_url.user)
        password = URI::DEFAULT_PARSER.unescape(proxy_url.password.to_s)
        token = "#{user}:#{password}"
        encoded = Base64.strict_encode64(token)

        [['proxy-authorization', "Basic #{encoded}"]]
      end

      def proxy_cache_value(proxy)
        return nil if proxy.nil?

        uri = URI.parse(proxy.to_s)
        return proxy.to_s unless uri.user

        user = URI::DEFAULT_PARSER.unescape(uri.user)
        password = URI::DEFAULT_PARSER.unescape(uri.password.to_s)
        auth_hash = Digest::SHA256.hexdigest("#{user}:#{password}")

        sanitized = uri.dup
        sanitized.user = nil
        sanitized.password = nil

        "#{sanitized}#auth=#{auth_hash}"
      rescue URI::InvalidURIError
        proxy.to_s
      end

      def logger_for
        return ::Aws.config[:logger] if defined?(::Aws)

        nil
      end
    end
  end
end
