require_relative '../spec_helper'

RSpec.describe 'Async::Aws::ClientCache#clear!(timeout:) during a blocked upload' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def tls_context
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=localhost')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = cert
      context.key = key
    end
  end

  # A peer that connects (and, with a context, finishes the TLS handshake) and
  # then never reads: after a few megabytes the client's write blocks.
  def silent_server(context = nil)
    server = TCPServer.new('127.0.0.1', 0)
    held = []
    thread = Thread.new do
      loop do
        socket = server.accept
        socket = OpenSSL::SSL::SSLSocket.new(socket, context).tap(&:accept) if context
        held << socket
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end
    yield server.addr[1]
  ensure
    server&.close
    thread&.join(2)
    held&.each do |socket|
      socket.close
    rescue StandardError
      nil
    end
  end

  { 'http' => false, 'https' => true }.each do |scheme, tls|
    it "is bounded by its timeout while a request is blocked writing its body (#{scheme})" do
      silent_server(tls ? tls_context : nil) do |port|
        cache = Async::Aws::ClientCache.new
        client = Aws::DynamoDB::Client.new(
          endpoint: "#{scheme}://127.0.0.1:#{port}", region: 'us-east-1', ssl_verify_peer: false,
          credentials: Aws::Credentials.new('akid', 'secret'), retry_limit: 0, max_attempts: 1,
          async_http_client_cache: cache, http_open_timeout: 3, http_read_timeout: 30,
          async_http_max_buffer_bytes: 64 * 1024 * 1024, async_http_body_warn_bytes: 0,
        )
        item = { 'id' => 'a', 'payload' => 'x' * (32 * 1024 * 1024) }

        Sync do |task|
          call = task.async { client.put_item(table_name: 't', item:) }
          sleep 1 # signed, connected, and stuck in the socket write

          started = monotonic
          task.with_timeout(20) { cache.clear!(timeout: 0.2) }

          expect(monotonic - started).to be < 1
          expect(cache.size).to eq(0)
          # Not by the socket timeout of the blocked write (http_open_timeout).
          expect { task.with_timeout(1) { call.wait } }.to raise_error(Seahorse::Client::NetworkingError)
        end
      end
    end
  end
end
