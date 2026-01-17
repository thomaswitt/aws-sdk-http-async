require 'seahorse/client/plugins/net_http'

module Async
  module Aws
    class HttpPlugin < Seahorse::Client::Plugin
      # @param config [Seahorse::Client::Configuration]
      # @return [void]
      def add_options(config)
        Seahorse::Client::Plugins::NetHttp.new.add_options(config)

        config.add_option(:async_http_connection_limit, 10)
        config.add_option(:async_http_force_accept_encoding, true)
        config.add_option(:async_http_body_warn_bytes, 5 * 1024 * 1024)
        config.add_option(:async_http_max_buffer_bytes, 5 * 1024 * 1024)
        config.add_option(:async_http_idle_timeout, 30)
        config.add_option(:async_http_header_timeout, nil)
        config.add_option(:async_http_total_timeout, nil)
        config.add_option(:async_http_max_cached_clients, 100)
        config.add_option(:async_http_streaming_uploads, :auto)
        config.add_option(:async_http_fallback, :net_http)
        config.add_option(:async_http_client_cache, nil)
      end

      # @param handlers [Seahorse::Client::HandlerList]
      # @param _config [Seahorse::Client::Configuration]
      # @return [void]
      def add_handlers(handlers, config)
        return if config.respond_to?(:stub_responses) && config.stub_responses

        handlers.add(Async::Aws::Handler, step: :send)
      end

      private
    end
  end
end
