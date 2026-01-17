require_relative '../spec_helper'
require 'stringio'
require 'tempfile'

RSpec.describe Async::Aws::Handler do
  class NonRewindableIO
    def initialize(content)
      @io = StringIO.new(content)
    end

    def read(*)
      @io.read(*)
    end

    def size
      @io.size
    end
  end

  class EmptyIO
    def read(*)
      nil
    end

    def rewind
      true
    end
  end

  class UnknownSizeIO
    def initialize(chunks)
      @chunks = chunks
    end

    def read(*)
      @chunks.shift
    end
  end

  it 'falls back to the next handler when no reactor is running' do
    fallback = instance_double(Seahorse::Client::Handler, call: :ok)
    handler = described_class.new(fallback)
    context = SpecHelper.build_context(endpoint: URI('http://example.com'))

    expect(handler.call(context)).to eq(:ok)
  end

  it 'raises in :raise fallback mode when no reactor is running' do
    handler = described_class.new
    context = SpecHelper.build_context(
      endpoint: URI('http://example.com'),
      config_overrides: { async_http_fallback: :raise },
    )

    expect { handler.call(context) }.to raise_error(Async::Aws::NoReactorError)
  end

  it 'accepts string fallback mode values' do
    handler = described_class.new
    context = SpecHelper.build_context(
      endpoint: URI('http://example.com'),
      config_overrides: { async_http_fallback: 'raise' },
    )

    expect { handler.call(context) }.to raise_error(Async::Aws::NoReactorError)
  end

  it 'prioritizes ENV fallback over config' do
    handler = described_class.new
    context = SpecHelper.build_context(
      endpoint: URI('http://example.com'),
      config_overrides: { async_http_fallback: :net_http },
    )

    begin
      ENV['AWS_SDK_HTTP_ASYNC_FALLBACK'] = 'raise'
      expect { handler.call(context) }.to raise_error(Async::Aws::NoReactorError)
    ensure
      ENV.delete('AWS_SDK_HTTP_ASYNC_FALLBACK')
    end
  end

  it 'warns when async_http_fallback is invalid' do
    logger = instance_double(Logger, warn: nil, debug: nil, info: nil)
    fallback = instance_double(Seahorse::Client::Handler, call: :ok)
    handler = described_class.new(fallback)
    context = SpecHelper.build_context(
      endpoint: URI('http://example.com'),
      config_overrides: { async_http_fallback: 'bogus', logger: },
    )

    handler.call(context)

    expect(logger).to have_received(:warn).with(
      /\[aws-sdk-http-async\] invalid async_http_fallback/
    )
  end

  it 'uses a transient reactor in :sync fallback mode' do
    handler = described_class.new
    context = SpecHelper.build_context(
      endpoint: URI('http://example.com'),
      config_overrides: { async_http_fallback: :sync },
    )

    allow(handler).to receive(:span_wrapper).and_yield
    allow(handler).to receive(:transmit)

    response = handler.call(context)

    expect(response).to be_a(Seahorse::Client::Response)
    expect(handler).to have_received(:transmit)
  end

  it 'includes common network errors' do
    expect(described_class::NETWORK_ERRORS).to include(Errno::ENETUNREACH, Errno::ENOTCONN)
  end

  it 'normalizes headers and forces empty accept-encoding' do
    handler = described_class.new
    config = SpecHelper.build_config
    headers = Seahorse::Client::Http::Headers.new(
      'Host' => 'example.com',
      'Content-Length' => '10',
      'X-Test' => 'ok',
    )

    normalized = handler.send(:normalize_headers, headers, config)
    hash = normalized.to_h

    expect(hash).not_to have_key('host')
    expect(hash).not_to have_key('content-length')
    expect(hash['x-test']).to eq(['ok'])
    expect(hash['accept-encoding']).to eq([])
  end

  it 'does not force accept-encoding when disabled' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_force_accept_encoding: false)
    headers = Seahorse::Client::Http::Headers.new('Accept-Encoding' => 'gzip')

    normalized = handler.send(:normalize_headers, headers, config)
    hash = normalized.to_h

    expect(hash['accept-encoding']).to eq(['gzip'])
  end

  it 'preserves accept-encoding when provided and force is enabled' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_force_accept_encoding: true)
    headers = Seahorse::Client::Http::Headers.new('Accept-Encoding' => 'gzip')

    normalized = handler.send(:normalize_headers, headers, config)
    hash = normalized.to_h

    expect(hash['accept-encoding']).to eq(['gzip'])
  end

  it 'buffers IO bodies and rewinds' do
    handler = described_class.new
    config = SpecHelper.build_config
    body = StringIO.new('payload')

    result = handler.send(:buffer_body, body, config)

    expect(result).to eq('payload')
    expect(body.pos).to eq(0)
  end

  it 'raises when buffered bodies exceed max size' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_max_buffer_bytes: 4)
    body = StringIO.new('12345')

    expect { handler.send(:buffer_body, body, config) }.to raise_error(Async::Aws::BodyTooLargeError, /async_http_max_buffer_bytes/)
  end

  it 'enforces max buffer size for string bodies' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_max_buffer_bytes: 3)
    headers = Seahorse::Client::Http::Headers.new

    expect { handler.send(:prepare_body, 'abcd', headers, config) }.to raise_error(Async::Aws::BodyTooLargeError, /async_http_max_buffer_bytes/)
  end

  it 'enforces max buffer size while reading unknown-size IO bodies' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_max_buffer_bytes: 5)
    body = UnknownSizeIO.new(['123', '456', nil])

    expect { handler.send(:buffer_body, body, config) }.to raise_error(Async::Aws::BodyTooLargeError, /async_http_max_buffer_bytes/)
  end

  it 'handles empty IO bodies without crashing' do
    handler = described_class.new
    config = SpecHelper.build_config
    body = EmptyIO.new

    result = handler.send(:buffer_body, body, config)

    expect(result).to eq('')
  end

  it 'streams rewindable IO with known size in auto mode' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_streaming_uploads: :auto)
    body = StringIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    result = handler.send(:prepare_body, body, headers, config)

    expect(result).to be_a(described_class::StreamingBody)
    expect(result.length).to eq(body.size)
  end

  it 'streams file IO for multipart-style bodies when size is known' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_streaming_uploads: :auto)
    headers = Seahorse::Client::Http::Headers.new

    file = Tempfile.new('multipart')
    file.write('payload')
    file.flush

    result = handler.send(:prepare_body, file, headers, config)

    expect(result).to be_a(described_class::StreamingBody)
    expect(result.length).to eq(file.size)
  ensure
    file&.close
    file&.unlink
  end

  it 'buffers non-rewindable IO in auto mode' do
    handler = described_class.new
    config = SpecHelper.build_config(async_http_streaming_uploads: :auto)
    body = NonRewindableIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    result = handler.send(:prepare_body, body, headers, config)

    expect(result).to eq('payload')
  end

  it 'warns on invalid async_http_streaming_uploads value' do
    logger = instance_double(Logger, warn: nil, info: nil)
    handler = described_class.new
    config = SpecHelper.build_config(async_http_streaming_uploads: :autoo, logger:)
    body = StringIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    handler.send(:prepare_body, body, headers, config)

    expect(logger).to have_received(:warn).with(/\[aws-sdk-http-async\] invalid async_http_streaming_uploads/)
  end

  it 'raises when forcing streaming with non-rewindable body and retries enabled' do
    handler = described_class.new
    config = Struct.new(
      :async_http_streaming_uploads,
      :max_attempts,
      :retry_max_attempts,
      :retry_limit,
      :async_http_max_buffer_bytes,
      :async_http_body_warn_bytes,
      :logger
    ).new(:force, nil, 3, nil, nil, 0, Logger.new(nil))

    body = NonRewindableIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    expect { handler.send(:prepare_body, body, headers, config) }.to raise_error(ArgumentError, /Non-rewindable/)
  end

  it 'allows forcing streaming with non-rewindable body when retries are disabled' do
    handler = described_class.new
    config = Struct.new(
      :async_http_streaming_uploads,
      :max_attempts,
      :retry_max_attempts,
      :retry_limit,
      :async_http_max_buffer_bytes,
      :async_http_body_warn_bytes,
      :logger
    ).new(:force, 1, 1, nil, nil, 0, Logger.new(nil))

    body = NonRewindableIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    result = handler.send(:prepare_body, body, headers, config)

    expect(result).to be_a(described_class::StreamingBody)
  end

  it 'honors max_attempts when guarding non-rewindable streaming' do
    handler = described_class.new
    config = Struct.new(
      :async_http_streaming_uploads,
      :max_attempts,
      :retry_max_attempts,
      :retry_limit,
      :async_http_max_buffer_bytes,
      :async_http_body_warn_bytes,
      :logger
    ).new(:force, 3, nil, nil, nil, 0, Logger.new(nil))

    body = NonRewindableIO.new('payload')
    headers = Seahorse::Client::Http::Headers.new

    expect { handler.send(:prepare_body, body, headers, config) }.to raise_error(ArgumentError, /Non-rewindable/)
  end

  it 'uses length when computing body size' do
    handler = described_class.new
    headers = Seahorse::Client::Http::Headers.new
    body = Struct.new(:length).new(12)

    expect(handler.send(:body_size, body, headers)).to eq(12)
  end

  it 'returns 0 for zero-length bodies' do
    handler = described_class.new
    headers = Seahorse::Client::Http::Headers.new
    body = Struct.new(:length).new(0)

    expect(handler.send(:body_size, body, headers)).to eq(0)
  end

  it 'warns when buffering large bodies' do
    output = StringIO.new
    logger = Logger.new(output)
    handler = described_class.new
    config = SpecHelper.build_config(async_http_body_warn_bytes: 1, logger:)

    handler.send(:buffer_body, 'payload', config)

    expect(output.string).to include('request body buffered in memory')
  end

  it 'verifies content-length and sets error on mismatch' do
    handler = described_class.new
    response = Seahorse::Client::Http::Response.new
    request = Seahorse::Client::Http::Request.new(http_method: 'GET')

    handler.send(:complete_response, request, response, 1, { 'content-length' => '2' })

    expect(response.error).to be_a(Seahorse::Client::NetworkingError)
  end

  it 'skips content-length validation when content-encoding is present' do
    handler = described_class.new
    response = Seahorse::Client::Http::Response.new
    request = Seahorse::Client::Http::Request.new(http_method: 'GET')

    handler.send(:complete_response, request, response, 1, { 'content-length' => '2', 'content-encoding' => 'gzip' })

    expect(response.error).to be_nil
  end

  it 'maps DNS errors with host context' do
    handler = described_class.new
    request = Seahorse::Client::Http::Request.new(endpoint: URI('http://dns.example'))
    error = SocketError.new('getaddrinfo: Name or service not known')

    mapped = handler.send(:networking_error, error, request)

    expect(mapped.message).to include('dns.example')
  end

  it 'propagates Async::Stop' do
    fake_client = Class.new do
      def call(*)
        raise Async::Stop
      end
    end.new

    fake_cache = Class.new do
      def initialize(client)
        @client = client
      end

      def client_for(*)
        @client
      end
    end.new(fake_client)

    Async do
      handler = described_class.new(client_cache: fake_cache)
      context = SpecHelper.build_context(endpoint: URI('http://example.com'))

      expect { handler.call(context) }.to raise_error(Async::Stop)
    end.wait
  end

  it 'delegates to next handler for event stream operations' do
    called = false
    next_handler = Class.new(Seahorse::Client::Handler) do
      def initialize(flag)
        super(nil)
        @flag = flag
      end

      def call(context)
        @flag.call
        Seahorse::Client::Response.new(context:)
      end
    end

    Async do
      handler = described_class.new(next_handler.new(-> { called = true }))
      context = SpecHelper.build_context(endpoint: URI('http://example.com'))
      context[:event_stream_handler] = proc { }

      handler.call(context)
    end.wait

    expect(called).to be(true)
  end

  it 'joins multiple set-cookie headers with newline' do
    handler = described_class.new
    response = Struct.new(:headers).new(
      Protocol::HTTP::Headers.new(
        [
          ['Set-Cookie', 'a=1'],
          ['Set-Cookie', 'b=2'],
        ]
      )
    )

    headers = handler.send(:response_headers, response)

    expect(headers['set-cookie']).to eq("a=1\nb=2")
  end

  it 'returns a single set-cookie header without separator' do
    handler = described_class.new
    response = Struct.new(:headers).new(
      Protocol::HTTP::Headers.new(
        [
          ['Set-Cookie', 'a=1'],
        ]
      )
    )

    headers = handler.send(:response_headers, response)

    expect(headers['set-cookie']).to eq('a=1')
  end

  it 'joins duplicate non-cookie headers with comma' do
    handler = described_class.new
    response = Struct.new(:headers).new(
      Protocol::HTTP::Headers.new(
        [
          ['Cache-Control', 'no-cache'],
          ['Cache-Control', 'no-store'],
        ]
      )
    )

    headers = handler.send(:response_headers, response)

    expect(headers['cache-control']).to eq('no-cache, no-store')
  end

  it 'reads response body in chunks with timeout' do
    handler = described_class.new
    config = SpecHelper.build_config(http_read_timeout: 0.1)
    chunks = %w[a b]

    body = Class.new do
      def initialize(chunks)
        @chunks = chunks
      end

      def read
        @chunks.shift
      end
    end.new(chunks)

    response = Struct.new(:body).new(body)

    Async do
      first = handler.send(:read_with_timeout, response, config)
      second = handler.send(:read_with_timeout, response, config)
      third = handler.send(:read_with_timeout, response, config)

      expect(first).to eq('a')
      expect(second).to eq('b')
      expect(third).to be_nil
    end.wait
  end

  it 'closes underlying IO when streaming body is closed' do
    file = Tempfile.new('streaming-body')
    body = described_class::StreamingBody.new(file, size: 1)

    body.close

    expect(file).to be_closed
  ensure
    file&.close
    file&.unlink
  end

  it 'reads from IOs that do not accept a size argument' do
    io = Class.new do
      def read(length = nil)
        raise ArgumentError, 'size not supported' if length

        'ok'
      end
    end.new

    body = described_class::StreamingBody.new(io, size: nil)

    expect(body.read).to eq('ok')
  end

  it 'restores IO position if buffered exceeds max size' do
    io = StringIO.new('123456')
    io.read(2)
    body = described_class::StreamingBody.new(io, size: 6, max_buffer: 3)

    expect { body.buffered }.to raise_error(Async::Aws::BodyTooLargeError, /async_http_max_buffer_bytes/)
    expect(io.pos).to eq(2)
  end

  it 'raises when chunked reads are unsupported and max buffer is set' do
    io = Class.new do
      def read(length = nil)
        raise ArgumentError, 'size not supported' if length

        'ok'
      end
    end.new

    body = described_class::StreamingBody.new(io, size: nil, max_buffer: 1)

    expect { body.read }.to raise_error(Async::Aws::BodyTooLargeError, /chunked reads/)
  end
end
