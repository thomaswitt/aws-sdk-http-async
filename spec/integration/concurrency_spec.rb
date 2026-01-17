require_relative '../spec_helper'

RSpec.describe 'Async::Aws concurrency' do
  around do |example|
    SpecHelper.with_webmock_localhost { example.run }
  end

  def with_server(app)
    port = SpecHelper.available_port
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
    server = Async::HTTP::Server.for(endpoint, &app)

    Sync do |task|
      server_task = task.async { server.run }

      begin
        sleep 0.05
        yield endpoint
      ensure
        server_task.stop
        server_task.wait
      end
    end
  end

  it 'handles concurrent requests without blocking' do
    with_server(->(_request) { Protocol::HTTP::Response[200, {}, ['OK']] }) do |endpoint|
      cache = Async::Aws::ClientCache.new
      handler = Async::Aws::Handler.new(client_cache: cache)

      task = Async::Task.current
      tasks = 10.times.map do
        task.async do
          context = SpecHelper.build_context(endpoint: endpoint.url)
          handler.call(context)
          context.http_response.status_code
        end
      end

      results = tasks.map(&:wait)
      expect(results).to all(eq(200))
    end
  end
end
