require 'async'
require 'async/http'
require 'async/aws/errors'
require 'openssl'
require 'protocol/http'
require 'protocol/http/body/buffered'
begin
  require 'protocol/http2'
rescue LoadError
end
require 'seahorse/client/networking_error'

module Async
  module Aws
    class Handler < Seahorse::Client::Handler
      # Seahorse builds a new handler for every API call, so anything that must
      # outlive one call (warn-once bookkeeping, the Net::HTTP fallback handler)
      # lives on the class.
      @transport_mutex = Mutex.new
      @transport_logged = {}
      @warned = {}
      @shared_state_pid = Process.pid
      @net_http_handler = nil
      WARN_ONCE_LIMIT = 100

      class << self
        # @param kind [Symbol]
        # @param logger [Logger, nil]
        # @return [void]
        def log_transport_once(kind, logger)
          return unless kind == :async_http && logger

          @transport_mutex.synchronize do
            forget_inherited_state
            return if @transport_logged[kind]

            @transport_logged[kind] = true
          end

          logger.info('[aws-sdk-http-async] using async-http transport')
        end

        # Logs `message` as a warning the first time `key` is seen in this
        # process. A call without a logger does not count as seen.
        #
        # @api private
        # @param key [String]
        # @param logger [Logger, nil]
        # @param message [String]
        # @return [void]
        def warn_once(key, logger, message)
          return unless logger

          @transport_mutex.synchronize do
            forget_inherited_state
            return if @warned[key]

            # Bounded: past the limit a new key warns on every occurrence.
            @warned[key] = true if @warned.size < WARN_ONCE_LIMIT
          end

          logger.warn(message)
        end

        # @api private
        # @return [Seahorse::Client::NetHttp::Handler] shared stateless fallback handler
        def net_http_handler
          return @net_http_handler if @net_http_handler

          @transport_mutex.synchronize do
            @net_http_handler ||= begin
                require 'seahorse/client/net_http/handler'
                Seahorse::Client::NetHttp::Handler.new(nil)
              end
          end
        end

        # Forgets the log-once/warn-once state. Intended for tests.
        #
        # @api private
        # @return [void]
        def reset_shared_state!
          @transport_mutex.synchronize do
            @transport_logged.clear
            @warned.clear
          end
        end

        private

        # "Once per process": a forked child logs again, possibly to another
        # destination than its parent. Called with the mutex held.
        def forget_inherited_state
          return if @shared_state_pid == Process.pid

          @transport_logged.clear
          @warned.clear
          @shared_state_pid = Process.pid
        end
      end

      class StreamingBody < Protocol::HTTP::Body::Readable
        CHUNK_SIZE = 16 * 1024

        # @param io [#read, #rewind, #size, nil]
        # @param size [Integer, nil]
        # @param max_buffer [Integer, nil]
        # @return [void]
        def initialize(io, size: nil, max_buffer: nil)
          @io = io
          @size = size
          @max_buffer = max_buffer
        end

        # @return [Integer, nil]
        def length
          @size
        end

        # @return [Boolean]
        def rewindable?
          @io.respond_to?(:rewind)
        end

        # @return [Boolean]
        def rewind
          return false unless rewindable?

          @io.rewind
          true
        end

        # @return [String, nil]
        def read
          chunk = read_chunk
          return nil if chunk.nil? || chunk.empty?

          chunk
        end

        # @param error [Exception, nil]
        # @return [void]
        def close(error = nil)
          nil
        end

        # @return [Protocol::HTTP::Body::Readable, nil]
        def buffered
          return nil unless rewindable?

          original_pos = @io.pos if @io.respond_to?(:pos)
          @io.rewind
          content = +''
          begin
            loop do
              chunk = read_chunk
              break if chunk.nil? || chunk.empty?

              if @max_buffer && (content.bytesize + chunk.bytesize) > @max_buffer
                raise BodyTooLargeError, "async_http_max_buffer_bytes exceeded (#{content.bytesize + chunk.bytesize} > #{@max_buffer})"
              end
              content << chunk
            end
          ensure
            if original_pos && @io.respond_to?(:pos=)
              @io.pos = original_pos
            else
              @io.rewind
            end
          end
          Protocol::HTTP::Body::Buffered.new([content], content.bytesize)
        end

        private

        def read_chunk
          @io.read(CHUNK_SIZE)
        rescue ArgumentError
          if @io.respond_to?(:readpartial)
            begin
              @io.readpartial(CHUNK_SIZE)
            rescue EOFError
              nil
            end
          elsif @max_buffer && @max_buffer > 0
            raise BodyTooLargeError, 'body does not support chunked reads; cannot enforce async_http_max_buffer_bytes'
          else
            @io.read
          end
        end
      end

      NETWORK_ERRORS = [
        Async::TimeoutError,
        SocketError,
        EOFError,
        IOError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EPIPE,
        Errno::ETIMEDOUT,
        Errno::EADDRNOTAVAIL,
        Errno::ENETDOWN,
        Errno::ENOBUFS,
        Errno::EHOSTUNREACH,
        Errno::ENETUNREACH,
        Errno::ENOTCONN,
        OpenSSL::SSL::SSLError,
        Protocol::HTTP::Error,
      ].tap do |errors|
        if defined?(Async::HTTP::ConnectionError)
          errors << Async::HTTP::ConnectionError
        end
        if defined?(Protocol::HTTP2::Error)
          errors << Protocol::HTTP2::Error
        end
        if defined?(Protocol::HTTP2)
          errors << Protocol::HTTP2::GoawayError if Protocol::HTTP2.const_defined?(:GoawayError)
          errors << Protocol::HTTP2::StreamError if Protocol::HTTP2.const_defined?(:StreamError)
        end
      end.freeze

      DNS_ERROR_PATTERNS = [
        /getaddrinfo/i,
        /nodename nor servname/i,
        /name or service not known/i,
        /host not found/i,
        /temporary failure in name resolution/i,
      ].freeze

      # @param handler [Seahorse::Client::Handler, nil]
      # @param client_cache [Async::Aws::ClientCache, nil] defaults to the
      #   process-wide {Async::Aws::ClientCache.default}
      # @return [void]
      def initialize(handler = nil, client_cache: nil)
        super(handler)
        @client_cache = client_cache
      end

      # @param context [Seahorse::Client::RequestContext]
      # @return [Seahorse::Client::Response]
      def call(context)
        if event_stream_operation?(context)
          ensure_reactor!
          return delegate_event_stream(context)
        end

        return force_net_http(context) if force_fallback?
        return fallback_handler(context) unless async_context?

        call_with_reactor(context)
      end

      private

      class TruncatedBodyError < IOError
        def initialize(bytes_expected, bytes_received)
          msg = "http response body truncated, expected #{bytes_expected} bytes, received #{bytes_received} bytes"
          super(msg)
        end
      end

      def ensure_reactor!
        return if Async::Task.current?

        raise NoReactorError, 'Async reactor is required. Wrap calls in Sync { }.'
      end

      def async_context?
        Async::Task.current?
      end

      def force_fallback?
        value = ENV.fetch('AWS_SDK_HTTP_ASYNC_FORCE_NET_HTTP', nil)
        return false if value.nil?

        %w[1 true yes].include?(value.to_s.strip.downcase)
      end

      def call_with_reactor(context)
        log_transport_once(:async_http, context.config)
        span_wrapper(context) do
          transmit(context.config, context.http_request, context.http_response)
        end

        Seahorse::Client::Response.new(context:)
      end

      def fallback_handler(context)
        mode = fallback_mode(context.config)

        case mode
        when :raise
          raise NoReactorError, 'Async reactor is required. Wrap calls in Sync { }.'
        when :sync
          # Without a scheduler, Sync creates a reactor that ends with the block.
          transient_reactor = Fiber.scheduler.nil?
          Sync do
            call_with_reactor(context)
          ensure
            close_transient_clients(context.config) if transient_reactor
          end
        else
          return @handler.call(context) if @handler

          Handler.net_http_handler.call(context)
        end
      end

      # The reactor of a :sync call ends with it: close its clients first, so
      # their entries do not stay in the cache. An injected cache-like object
      # manages its own lifecycle.
      def close_transient_clients(config)
        cache = client_cache(config)
        cache.clear! if cache.is_a?(ClientCache)
      rescue StandardError => e
        logger_for(config)&.warn("[aws-sdk-http-async] failed to close clients of the :sync reactor: #{e.message}")
      end

      def force_net_http(context)
        return @handler.call(context) if @handler

        Handler.net_http_handler.call(context)
      end

      def fallback_mode(config)
        env_mode = ENV.fetch('AWS_SDK_HTTP_ASYNC_FALLBACK', nil)
        if env_mode && !env_mode.to_s.strip.empty?
          normalized_env = env_mode.to_s.strip.downcase
          return normalized_env.to_sym if %w[net_http sync raise].include?(normalized_env)
          warn_invalid_fallback_once("ENV['AWS_SDK_HTTP_ASYNC_FALLBACK']", env_mode, config)
        end

        mode = config.async_http_fallback
        return :net_http if mode.nil?

        normalized = mode.to_s
        normalized = normalized.strip.downcase
        return normalized.to_sym if %w[net_http sync raise].include?(normalized)
        warn_invalid_fallback_once('config.async_http_fallback', mode, config)

        :net_http
      end

      def warn_invalid_fallback_once(source, value, config)
        Handler.warn_once(
          "fallback:#{source}:#{value.inspect}",
          logger_for(config),
          "[aws-sdk-http-async] invalid async_http_fallback #{source}=#{value.inspect}; using :net_http",
        )
      end

      def log_transport_once(kind, config)
        Handler.log_transport_once(kind, logger_for(config))
      end

      def streaming_mode(config)
        mode = config.async_http_streaming_uploads
        return :auto if mode.nil?

        normalized = mode.to_s.strip.downcase
        return normalized.to_sym if %w[auto force off].include?(normalized)

        warn_invalid_streaming_once(mode, config)
        :auto
      end

      def warn_invalid_streaming_once(value, config)
        Handler.warn_once(
          "streaming:#{value.inspect}",
          logger_for(config),
          "[aws-sdk-http-async] invalid async_http_streaming_uploads=#{value.inspect}; using :auto",
        )
      end

      def transmit(config, req, resp)
        total_timeout = config.async_http_total_timeout
        return transmit_inner(config, req, resp) unless total_timeout && total_timeout > 0

        # Raised as a copy of this instance, which carries the scope along.
        expired = TransportTimeoutError.new
        expired.scope = scope = Object.new
        Async::Task.current.with_timeout(total_timeout, expired) do |deadline|
          transmit_inner(config, req, resp, deadline:, scope:)
        end
      end

      def client_cache(config)
        config.async_http_client_cache || @client_cache || ClientCache.default
      end

      def transmit_inner(config, req, resp, deadline: nil, scope: nil)
        cache = client_cache(config)
        # Set once the outcome of the request has been signalled to Seahorse.
        settled = false
        # Set while the connection is used: what fails then is not the caller's code.
        on_wire = false
        runner = ->(client) do
          request = build_request(req, config)
          response = nil

          begin
            on_wire = true
            response = call_with_timeout(client, request, config)
            on_wire = false
            bytes_received = 0

            headers = response_headers(response)
            resp.signal_headers(response.status.to_i, headers)

            loop do
              on_wire = true
              chunk = read_with_timeout(response, config)
              on_wire = false
              break if chunk.nil? || chunk.empty?

              bytes_received += chunk.bytesize
              resp.signal_data(chunk)
            end

            # The response is complete: the total deadline must not interrupt
            # the listeners Seahorse runs now, nor turn their result into a
            # retry. The same holds for the listeners of an error, below.
            deadline&.cancel!
            complete_response(req, resp, bytes_received, headers)
            settled = true
          rescue Async::Stop
            raise
          rescue Async::TimeoutError => error
            # Not one of this transport's deadlines: the caller's own
            # `with_timeout` around the call. It is not a network error and
            # must not be retried.
            raise unless transport_timeout?(error, scope)

            settled = true
            deadline&.cancel!
            resp.signal_error(networking_error(error, req))
          rescue *NETWORK_ERRORS, SystemCallError => error
            settled = true
            deadline&.cancel!
            resp.signal_error(networking_error(error, req))
          rescue StandardError => error
            settled = true
            deadline&.cancel!
            if on_wire && cache.respond_to?(:force_closed?) && cache.force_closed?(client)
              # The connection was closed under the request (`clear!(timeout:)`),
              # which protocol-http1 reports as whatever its torn-down state raises.
              resp.signal_error(networking_error(error, req))
            else
              logger_for(config)&.error("[aws-sdk-http-async] unexpected error: #{error.class}: #{error.message}")
              resp.signal_error(error)
            end
          ensure
            # The request is over, whichever way it ends. The total deadline
            # does not cover the cleanup: giving up the turn switches to the
            # call that waits for it, and a deadline that came due in that pass
            # of the event loop would replace a stop or a timeout of the caller
            # on its way out and be reported as a network error, which the SDK
            # retries.
            deadline&.cancel!
            close_response(response)
          end
        end

        if cache.respond_to?(:with_client)
          cache.with_client(req.endpoint, config, &runner)
        else
          runner.call(cache.client_for(req.endpoint, config))
        end
      rescue TransportTimeoutError => error
        raise unless transport_timeout?(error, scope)

        # Timed out while waiting its turn: a network error like a timeout
        # during the request. Once the outcome is signalled, a timeout can only
        # have hit the cleanup of a finished request, and signalling an error
        # then would make the SDK retry an operation that succeeded.
        return if settled

        # The wait for a turn has its own timeout; the total deadline must not
        # cut off the listeners of the error either.
        deadline&.cancel!
        resp.signal_error(networking_error(error, req))
      end

      # The outcome is signalled by now. After `clear!(timeout:)` closed the
      # socket under the request, closing a partly read body raises; that must
      # not replace the error that was signalled.
      def close_response(response)
        response&.close
      rescue IOError, SystemCallError
        nil
      end

      # Whether `error` is a deadline of this invocation. The total deadline of
      # an outer call (one whose streaming block makes this call) is not: like a
      # timeout the caller put around the call, it passes through. WebMock's
      # `to_timeout` raises a plain `Async::TimeoutError` from inside the
      # stubbed client; it stands for a network timeout.
      def transport_timeout?(error, scope)
        return error.message == 'WebMock timeout error' unless error.is_a?(TransportTimeoutError)

        error.scope.nil? || error.scope.equal?(scope)
      end

      def build_request(http_request, config)
        method = http_request.http_method.to_s.upcase
        path = http_request.endpoint.request_uri
        headers = normalize_headers(http_request.headers, config)
        body = prepare_body(http_request.body, http_request.headers, config)
        headers.delete('transfer-encoding') if body.is_a?(String)

        Protocol::HTTP::Request[method, path, headers:, body:]
      end

      def normalize_headers(headers, config)
        normalized = headers.to_h.transform_keys { it.to_s.downcase }
        normalized.delete('host')
        normalized.delete('content-length')
        if config.async_http_force_accept_encoding && !normalized.key?('accept-encoding')
          normalized['accept-encoding'] = ''
        end
        Protocol::HTTP::Headers[normalized]
      end

      def prepare_body(body, headers, config)
        return nil if body.nil?
        if body.is_a?(String)
          enforce_max_buffer!(body.bytesize, config)
          warn_large_body(body.bytesize, config)
          return body
        end

        mode = streaming_mode(config)
        size = body_size(body, headers)
        rewindable = body.respond_to?(:rewind)
        max_buffer = config.async_http_max_buffer_bytes

        if mode == :auto
          return StreamingBody.new(body, size:, max_buffer:) if size && rewindable
          return buffer_body(body, config)
        end

        if mode == :force
          ensure_streaming_retry_safe!(config, rewindable)
          warn_unknown_stream_size(size, config)
          return StreamingBody.new(body, size:, max_buffer:)
        end

        buffer_body(body, config)
      end

      def buffer_body(body, config)
        return nil if body.nil?
        if body.is_a?(String)
          enforce_max_buffer!(body.bytesize, config)
          warn_large_body(body.bytesize, config)
          return body
        end
        original_pos = body.pos if body.respond_to?(:pos)

        size_hint = if body.respond_to?(:length)
            body.length
          elsif body.respond_to?(:size)
            body.size
          end
        enforce_max_buffer!(size_hint, config) if size_hint

        content = if size_hint.nil?
            buffer_unknown_size_body(body, config)
          else
            body.read || ''
          end
        body.rewind if body.respond_to?(:rewind)
        enforce_max_buffer!(content.bytesize, config)
        warn_large_body(content.bytesize, config)
        content
      rescue BodyTooLargeError
        if body.respond_to?(:pos=) && !original_pos.nil?
          body.pos = original_pos
        elsif body.respond_to?(:rewind)
          body.rewind
        end
        raise
      rescue StandardError
        if body.respond_to?(:pos=) && !original_pos.nil?
          body.pos = original_pos
        elsif body.respond_to?(:rewind)
          body.rewind
        end
        raise
      end

      def buffer_unknown_size_body(body, config)
        content = +''
        loop do
          chunk = begin
              body.read(StreamingBody::CHUNK_SIZE)
            rescue ArgumentError
              if body.respond_to?(:readpartial)
                begin
                  body.readpartial(StreamingBody::CHUNK_SIZE)
                rescue EOFError
                  nil
                end
              elsif config.async_http_max_buffer_bytes && config.async_http_max_buffer_bytes > 0
                raise BodyTooLargeError,
                      'body does not support chunked reads; cannot enforce async_http_max_buffer_bytes'
              else
                body.read
              end
            end
          break if chunk.nil? || chunk.empty?

          enforce_max_buffer!(content.bytesize + chunk.bytesize, config)
          content << chunk
        end
        content
      end

      def body_size(body, headers)
        content_length = headers['content-length']
        if content_length && !content_length.to_s.empty?
          return content_length.to_i if content_length.to_s.match?(/\A\d+\z/)
        end
        return body.bytesize if body.is_a?(String)
        if body.respond_to?(:length)
          length = body.length
          return length unless length.nil?
        end
        if body.respond_to?(:size)
          size = body.size
          return size unless size.nil?
        end

        nil
      end

      def ensure_streaming_retry_safe!(config, rewindable)
        return if rewindable
        return unless retries_enabled?(config)

        raise ArgumentError,
              'Non-rewindable streaming bodies cannot be retried. ' \
              'Use a rewindable body (File, StringIO) or disable retries, e.g. ' \
              'Aws::S3::Client.new(retry_max_attempts: 1, async_http_streaming_uploads: :force).'
      end

      def retries_enabled?(config)
        if config.respond_to?(:max_attempts) && !config.max_attempts.nil?
          return config.max_attempts.to_i > 1
        end

        if config.respond_to?(:retry_max_attempts) && !config.retry_max_attempts.nil?
          return config.retry_max_attempts.to_i > 1
        end

        if config.respond_to?(:retry_limit) && !config.retry_limit.nil?
          return config.retry_limit.to_i > 0
        end

        false
      end

      def warn_unknown_stream_size(size, config)
        return unless size.nil?

        logger_for(config)&.warn(
          '[aws-sdk-http-async] streaming request body with unknown size'
        )
      end

      def delegate_event_stream(context)
        require 'seahorse/client/h2/handler'

        if context.client.respond_to?(:connection)
          @h2_handler ||= Seahorse::Client::H2::Handler.new(nil)
          return @h2_handler.call(context)
        end

        return @handler.call(context) if @handler

        raise ArgumentError, 'event stream operations require an Async client (Seahorse::Client::AsyncBase) or a native H2 handler'
      end

      def read_with_timeout(response, config)
        timeout = config.http_read_timeout
        body = response.body
        return nil if body.nil?
        return read_response_chunk(body) if timeout.nil? || timeout <= 0

        Async::Task.current.with_timeout(timeout, TransportTimeoutError) { read_response_chunk(body) }
      end

      def read_response_chunk(body)
        body.read(StreamingBody::CHUNK_SIZE)
      rescue ArgumentError
        if body.respond_to?(:readpartial)
          begin
            body.readpartial(StreamingBody::CHUNK_SIZE)
          rescue EOFError
            nil
          end
        else
          body.read
        end
      end

      def call_with_timeout(client, request, config)
        header_timeout = config.async_http_header_timeout
        if header_timeout && header_timeout > 0
          return Async::Task.current.with_timeout(header_timeout, TransportTimeoutError) { client.call(request) }
        end

        timeout = config.http_read_timeout
        return client.call(request) if timeout.nil? || timeout <= 0

        body = request.body
        return client.call(request) unless body.nil? || body.is_a?(String) || body.is_a?(Protocol::HTTP::Body::Buffered)

        Async::Task.current.with_timeout(timeout, TransportTimeoutError) { client.call(request) }
      end

      def complete_response(req, resp, bytes_received, headers)
        content_length = headers['content-length']&.to_i
        content_encoding = headers['content-encoding']
        if req.http_method != 'HEAD' && content_length && (content_encoding.nil? || content_encoding.empty?) &&
           bytes_received != content_length
          error = TruncatedBodyError.new(content_length, bytes_received)
          resp.signal_error(Seahorse::Client::NetworkingError.new(error, error.message))
        else
          resp.signal_done
        end
      end

      def networking_error(error, req)
        message = error.message
        if DNS_ERROR_PATTERNS.any? { |pattern| message.match?(pattern) }
          message = "Unable to connect to `#{req.endpoint.host}`: #{message}"
        end

        Seahorse::Client::NetworkingError.new(error, message)
      end

      def span_wrapper(context)
        context.tracer.in_span(
          'Handler.AsyncHttp',
          attributes: ::Aws::Telemetry.http_request_attrs(context),
        ) do |span|
          yield
          span.add_attributes(::Aws::Telemetry.http_response_attrs(context))
        end
      end

      def response_headers(response)
        headers = {}
        set_cookies = []
        set_cookie2 = []

        # NOTE: HTTP allows duplicate header names, but Seahorse expects Hash<String, String>.
        # Multiple values are joined with ", " (comma-space). This is correct for most headers.
        # Set-Cookie/Set-Cookie2 are joined with "\n" to preserve cookie boundaries per RFC 6265.
        response.headers.each do |key, value|
          key = key.downcase
          if key == 'set-cookie'
            set_cookies << value.to_s
            next
          end
          if key == 'set-cookie2'
            set_cookie2 << value.to_s
            next
          end

          headers[key] = headers[key] ? "#{headers[key]}, #{value}" : value.to_s
        end

        headers['set-cookie'] = set_cookies.join("\n") unless set_cookies.empty?
        headers['set-cookie2'] = set_cookie2.join("\n") unless set_cookie2.empty?

        headers
      end

      def warn_large_body(size, config)
        limit = config.async_http_body_warn_bytes
        return if limit.nil? || limit <= 0 || size <= limit

        logger_for(config)&.warn(
          "[aws-sdk-http-async] request body buffered in memory (#{size} bytes)"
        )
      end

      def enforce_max_buffer!(size, config)
        limit = config.async_http_max_buffer_bytes
        return if limit.nil? || limit <= 0 || size.nil?
        return if size <= limit

        raise BodyTooLargeError, "buffered body size #{size} exceeds async_http_max_buffer_bytes=#{limit}"
      end

      def event_stream_operation?(context)
        return true if context[:input_event_stream_handler] ||
                       context[:output_event_stream_handler] ||
                       context[:event_stream_handler]

        operation = context.operation
        return false unless operation

        shape_ref_eventstream?(operation.input) || shape_ref_eventstream?(operation.output)
      end

      def shape_ref_eventstream?(shape_ref)
        return false unless shape_ref

        payload = shape_ref[:payload_member]
        return true if payload && payload.eventstream

        shape = shape_ref.shape
        return false unless shape.respond_to?(:members)

        members = shape.members
        return false unless members

        if members.respond_to?(:each_value)
          members.each_value do |ref|
            return true if ref.eventstream
          end
        else
          members.each do |item|
            ref = item.is_a?(Array) ? item.last : item
            return true if ref.respond_to?(:eventstream) && ref.eventstream
          end
        end

        false
      end

      def logger_for(config)
        config.logger || ::Aws.config[:logger]
      end
    end
  end
end
