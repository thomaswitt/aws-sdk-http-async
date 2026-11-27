require 'async/http'
require 'async/condition'
require 'async/http/proxy'
require 'async/semaphore'
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

      @default_mutex = Mutex.new
      @default = nil

      # Process-wide cache used by every handler that has no explicit cache
      # (`async_http_client_cache` or `Handler.new(client_cache:)`). Seahorse
      # builds a new handler per API call, so only a shared cache lets calls
      # reuse an `Async::HTTP::Client` (and its connections).
      #
      # @return [Async::Aws::ClientCache]
      def self.default
        return @default if @default

        @default_mutex.synchronize { @default ||= new }
      end

      Entry = Struct.new(:client, :reactor_ref, :inflight, :limiter, :unused)

      # WebMock's `Async::HTTP::Client` wrapper refuses to hand out its pool
      # while real connections are disabled, with an error that is not a
      # `StandardError`.
      #
      # @api private
      # @param error [Exception]
      # @return [Boolean]
      def self.pool_refused?(error)
        error.class.name == 'WebMock::NetConnectNotAllowedError'
      end

      # The deadline of `clear!(timeout:)`, kept apart from a caller's own timeout.
      CloseDeadline = Class.new(Async::TimeoutError)
      private_constant :CloseDeadline

      # Retires pooled connections that went unused for `timeout` seconds, like
      # the SDK's Net::HTTP pool does for `http_idle_timeout`. async-pool expires
      # nothing by itself, and its checkout probe only notices connections the
      # peer closed, not flows a NAT gateway or firewall dropped silently.
      #
      # Runs in the pool's transient gardener task. A connection is retired
      # after it was seen unused, with the same request count, on two
      # consecutive checks, so after `timeout` to `2 * timeout` seconds idle.
      class IdlePolicy
        # @param timeout [Numeric] seconds
        # @return [void]
        def initialize(timeout)
          @timeout = timeout
        end

        # @param pool [Async::Pool::Controller]
        # @return [void] once the pool is empty; the gardener calls again after the next release
        def call(pool)
          idle = {}.compare_by_identity
          until pool.resources.empty?
            sleep(@timeout)
            previous = idle
            idle = {}.compare_by_identity
            pool.resources.each { |connection, usage| idle[connection] = connection.count if usage.zero? }
            idle.each_key do |connection|
              # Checked right before retiring: closing a connection may switch
              # fibers, and another one may serve a request meanwhile.
              pool.retire(connection) if previous[connection] == connection.count && pool.resources[connection]&.zero?
            end
          end
        end
      end

      # The target endpoint of a proxied client. Every CONNECT tunnel runs in a
      # task of its own below a transient task at the root of the reactor, not
      # below the request that happened to open it: stopping that request leaves
      # the pooled tunnel intact, and an open tunnel does not keep the reactor
      # alive once its other tasks are done.
      class TunnelEndpoint < Async::HTTP::Endpoint
        # An endpoint that is already connected: lets
        # `Async::HTTP::Endpoint#build_endpoint` put TLS on top of an open tunnel.
        Tunnel = Struct.new(:connect)

        # @param endpoint [Async::HTTP::Endpoint] the target
        # @param proxy [Async::HTTP::Proxy]
        # @return [void]
        def initialize(endpoint, proxy)
          super(endpoint.url, **endpoint.options)
          @proxy = proxy
          @tunnels = nil
          @closed = false
          @pool = nil
          @connecting = 0
          @connected = Async::Condition.new
          @cut = 0
        end

        # @return [#call, nil] returns the pool of the client on top of this
        #   endpoint, or nil while that pool cannot be inspected
        attr_writer :pool

        # @return [Integer] how many tunnels were stopped while the connection
        #   on top of them was open, and so possibly under a request
        attr_reader :cut

        # Opens a tunnel to the target, including the TLS handshake for an
        # https target. A caller that is stopped or times out while waiting
        # takes its unfinished tunnel down with it.
        #
        # @return [IO] the socket to the target
        # @raise [IOError] if the endpoint is closed
        def connect
          parent = tunnels
          # Checked last: starting the parent task lets other tasks run.
          raise IOError, 'proxy client is closed' if @closed

          opened = Async::Promise.new
          tunnel = nil
          @connecting += 1
          # Assigned inside the block: `async` runs the tunnel until it first
          # waits, and the caller can be cancelled before `async` returns.
          parent.async(annotation: 'aws-sdk-http-async proxy tunnel') do |task|
            tunnel = task
            run_tunnel(opened, task)
          end
          socket = opened.wait
        ensure
          if opened
            @connecting -= 1
            @connected.signal
          end
          tunnel&.cancel unless socket
        end

        # Closes every tunnel, also those under a request in flight, and
        # refuses new ones.
        #
        # @return [void]
        def close
          @closed = true
          # A task can only be stopped from inside its reactor. Elsewhere the
          # tunnels end once the connections on top of them are closed.
          @tunnels.cancel if @tunnels && Async::Task.current?&.reactor.equal?(@tunnels.reactor)
        end

        private

        # Started with the first tunnel rather than with the endpoint, because
        # starting a task lets other tasks run and the cache builds clients
        # between two lookups.
        def tunnels
          # Not only `#close` ends the parent task: `Scheduler#stop` (SIGINT)
          # cancels it too, and calls made during shutdown need a new one. A
          # cancelled task still runs while it stops its tunnels, and would
          # stop a new one with them.
          return @tunnels if @closed || (@tunnels&.running? && !@tunnels.cancelled?)

          Async::Task.run(
            Async::Task.current.reactor,
            transient: true,
            annotation: 'aws-sdk-http-async proxy tunnels',
          ) do |task|
            @tunnels = task
            sleep
          ensure
            # `Scheduler#stop` cancels this task at once, but not the requests
            # that defer their cancel (a request a server is still answering)
            # or that an `ensure` makes while it is stopped.
            drain unless @closed
          end
        end

        # Ends the tunnels the way a pool's gardener ends direct connections
        # when it is stopped: an idle one at once, one in use after its
        # request. A second cancel ends the wait, and so all tunnels.
        def drain
          pool = @pool&.call
          loop do
            # A tunnel that is being opened is in no pool yet.
            @connected.wait while @connecting.positive?
            pool&.drain
            break if @connecting.zero?
          end
        rescue StandardError
          # The tunnels are then stopped with this task, as by `#close`.
          nil
        end

        def run_tunnel(opened, task)
          @proxy.connect do |socket|
            # Like a direct connection, so that a tunnel that went dead does not
            # leave its request waiting for good.
            socket.timeout = timeout if timeout
            shutdown_on_close(socket)
            opened.resolve(build_endpoint(Tunnel.new(socket)).connect)
            # The tunnel's writer ends when the connection on top of it is
            # closed. Returning then closes the pipe, which releases the proxy
            # connection without waiting for the proxy to close it.
            task.wait_all
          ensure
            # Stopped by `#close` or with the reactor while its connection is
            # open: async-http closes the socket next, in this task.
            @cut += 1 if opened.completed? && !socket.closed?
          end
        rescue StandardError => error
          # Once the tunnel is open nobody waits for it any more; the
          # connection on top of it then fails on the closed socket.
          opened.reject(error)
        ensure
          # Stopped before it opened, by `#close` or for a caller that gave up.
          opened.reject(IOError.new('proxy tunnel closed before it was established'))
          # A cancel that lands while async-http sets up the tunnel's pipe leaves
          # the pipe's transient tasks behind, holding the proxy connection.
          # The proxy pool's gardener is a child of whichever tunnel opened a
          # connection while the pool had none, and outlives it: cancelled, it
          # would wait for the pool to drain and keep this task in the tree.
          task.children&.each { it.cancel unless it.annotation.to_s.end_with?(' Gardener') }
        end

        # A process forked while the tunnel is open inherits the pipe's socket
        # pair. A plain close of this end then no longer reaches the pipe's
        # writer for as long as that process lives, and the tunnel would keep
        # its proxy connection. A shutdown reaches it whoever else holds the
        # socket. Only the process that opened the tunnel shuts it down.
        def shutdown_on_close(socket)
          owner = Process.pid
          socket.define_singleton_method(:close) do
            begin
              shutdown if !closed? && Process.pid == owner
            rescue SystemCallError, IOError
              # Already disconnected by the other end.
            end
            super()
          end
        end
      end

      class ProxyClient
        # @param client [Async::HTTP::Client]
        # @param proxy_client [Async::HTTP::Client]
        # @param tunnels [TunnelEndpoint] the endpoint of `client`
        # @return [void]
        def initialize(client, proxy_client, tunnels)
          @client = client
          @proxy_client = proxy_client
          @tunnels = tunnels
        end

        # @param request [Protocol::HTTP::Request]
        # @return [Async::HTTP::Response]
        def call(request, &)
          @client.call(request, &)
        end

        # Waits for the requests in flight, then closes all connections. If the
        # wait is interrupted (timeout, stop), the requests still in flight fail.
        #
        # @return [void]
        def close
          @client.close
        ensure
          # A tunnel holds its proxy connection for as long as it is open, so
          # the proxy pool only drains once the tunnels are gone. Whatever is
          # left then is the remains of a tunnel: nothing to wait for.
          @tunnels.close
          retire_proxy_connections
          @proxy_client.close
        end

        # @return [Array<Async::Pool::Controller>] the target pool, then the proxy pool
        def pools
          [@client, @proxy_client].filter_map { it.pool if it.respond_to?(:pool) }
        end

        # @return [Integer] changes when a tunnel is stopped under its connection
        def tunnels_cut
          @tunnels.cut
        end

        private

        def retire_proxy_connections
          return unless @proxy_client.respond_to?(:pool)

          pool = @proxy_client.pool
          pool.resources.keys.each { pool.retire(it) } until pool.empty?
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise unless ClientCache.pool_refused?(e)
        end
      end

      # @return [void]
      def initialize
        @clients = {}
        @mutex = Mutex.new
        @access_count = 0
        @over_limit = ObjectSpace::WeakKeyMap.new
        @force_closed = ObjectSpace::WeakKeyMap.new
        # Every client that is still referenced, also one that `clear!` took
        # out of the cache and is still closing.
        @built = ObjectSpace::WeakMap.new
        @pid = Process.pid
      end

      # Hands out the cached client itself. Unlike {#with_client} it does not
      # count the caller as a user of the client: the client may be evicted and
      # closed while in use, and concurrent first calls can briefly exceed
      # `async_http_connection_limit`.
      #
      # @param endpoint [URI::HTTP, URI::HTTPS]
      # @param config [Seahorse::Client::Configuration]
      # @return [Async::HTTP::Client]
      def client_for(endpoint, config)
        raise NoReactorError, 'Async reactor is required. Wrap calls in Sync { }.' unless Async::Task.current?

        discard_inherited_entries
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

        close_entries([stale_entry, *sweep_dead_entries_if_needed])
        return entry.client if entry

        new_entry = nil
        evicted = []
        used_entry = nil
        stale_existing = nil

        key, new_entry = build_for_key(endpoint, config, reactor, key)

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

        close_entries([(new_entry if used_entry != new_entry), stale_existing, *evicted])

        used_entry.client
      end

      # Yields the cached client for the endpoint and counts the caller as using
      # it until the block returns. At most `async_http_connection_limit` callers
      # use a client at once; further callers wait their turn.
      #
      # @param endpoint [URI::HTTP, URI::HTTPS]
      # @param config [Seahorse::Client::Configuration]
      # @yieldparam client [Async::HTTP::Client]
      # @return [Object] the value of the block
      # @raise [Async::Aws::TransportTimeoutError] if `async_http_header_timeout` passes while waiting for a turn
      def with_client(endpoint, config)
        raise NoReactorError, 'Async reactor is required. Wrap calls in Sync { }.' unless Async::Task.current?

        discard_inherited_entries
        reactor = Async::Task.current.reactor
        key = cache_key(endpoint, config, reactor)
        entry = nil
        stale_entry = nil

        entry = @mutex.synchronize do
          cached = @clients[key]
          if entry_valid_for?(cached, reactor)
            touch_lru!(key, cached)
            cached.inflight = cached.inflight.to_i + 1
            cached
          else
            stale_entry = @clients.delete(key) if cached
            nil
          end
        end

        close_entries([stale_entry, *sweep_dead_entries_if_needed])

        unless entry
          key, new_entry = build_for_key(endpoint, config, reactor, key)
          evicted = []
          stale_existing = nil

          # `entry` is assigned where it is counted as in-flight, so the `ensure`
          # below releases it whatever happens after this point.
          @mutex.synchronize do
            existing = @clients[key]
            if entry_valid_for?(existing, reactor)
              touch_lru!(key, existing)
              existing.inflight = existing.inflight.to_i + 1
              entry = existing
            else
              stale_existing = existing
              @clients[key] = new_entry
              touch_lru!(key, new_entry)
              new_entry.inflight = new_entry.inflight.to_i + 1
              entry = new_entry
              evicted = evict_entries_locked(config, reactor)
            end
          end

          close_entries([(new_entry if entry != new_entry), stale_existing, *evicted])
        end

        client = extract_client(entry)
        limiter = entry.limiter
        wait_for_turn(limiter, config) if limiter
        cut = tunnels_cut(client)
        begin
          yield client
        ensure
          begin
            take_close_interrupt if force_closed?(client) || cut != tunnels_cut(client)
          ensure
            limiter&.release
          end
        end
      ensure
        release_entry(entry, key, config, reactor) if entry
      end

      # Whether the connections of `client` were closed under its requests by
      # `clear!(timeout:)`. Such requests fail in whatever way their torn-down
      # connection raises; the handler reports that as a networking error.
      #
      # @api private
      # @param client [Async::HTTP::Client]
      # @return [Boolean]
      def force_closed?(client)
        @mutex.synchronize { @force_closed.key?(client) }
      end

      # @return [Integer] number of cached clients, across all reactors
      def size
        discard_inherited_entries
        @mutex.synchronize { @clients.size }
      end

      # Closes the clients of the calling reactor and of finished reactors, and
      # removes them from the cache. Intended for shutdown.
      #
      # A client is only closed by its own reactor: its sockets and its pool's
      # tasks belong to that reactor's thread. Clients of other running reactors
      # therefore stay cached until those reactors call `clear!` or finish.
      #
      # Without a timeout it waits for the calling reactor's in-flight requests.
      # Cancelling the caller, or a timeout of its own around the call, ends that
      # wait; the remaining clients are then closed as soon as they are unused.
      #
      # @param timeout [Numeric, nil] seconds to wait, in total, for in-flight
      #   requests of the calling reactor; after that their connections are
      #   closed anyway
      # @return [void]
      def clear!(timeout: nil)
        discard_inherited_entries
        reactor = current_reactor
        pending = @mutex.synchronize do
          keys = @clients.keys.reject { owned_by_other_reactor?(@clients[it], reactor) }
          keys.map { @clients.delete(it) }
        end
        deadline = monotonic_time + timeout if timeout

        # An entry leaves `pending` only once it is closed.
        until pending.empty?
          entry = pending.first
          if reactor && reactor.equal?(entry_reactor(entry))
            deadline ? close_before(entry, deadline) : close_gracefully(entry)
          else
            close_entry(entry)
          end
          pending.shift
        end
      ensure
        # Interrupted while waiting: the entries are already out of the cache, so
        # nothing else would close them.
        close_entries(pending) { close_without_waiting(it) } if pending && !pending.empty?
      end

      # @return [void]
      def close!
        clear!
      end

      private

      # A forked child inherits the parent's entries, but their sockets (and TLS
      # sessions) still belong to the parent. Drop them without closing: a close
      # would write TLS close_notify / HTTP/2 GOAWAY onto connections the parent
      # is still using.
      def discard_inherited_entries
        return if @pid == Process.pid

        @mutex.synchronize do
          next if @pid == Process.pid

          inherited = @built.keys
          @clients = {}
          @access_count = 0
          @over_limit = ObjectSpace::WeakKeyMap.new
          @force_closed = ObjectSpace::WeakKeyMap.new
          @built = ObjectSpace::WeakMap.new
          @pid = Process.pid
          release_inherited_sockets(inherited)
        end
      end

      # Closes this process's copies of the parent's sockets, which writes
      # nothing to them. Kept open, they would hold the parent's connections
      # open for the peer after the parent closed them.
      def release_inherited_sockets(clients)
        clients.each do |client|
          pools_of(client)&.each { |pool| pool.resources.each_key { close_socket(it) } }
        end
      rescue StandardError
        nil
      end

      def owned_by_other_reactor?(entry, reactor)
        entry.is_a?(Entry) && !entry_dead?(entry) && !entry_valid_for?(entry, reactor)
      end

      def current_reactor
        Async::Task.current? ? Async::Task.current.reactor : nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Runs the block to completion even if the task is cancelled meanwhile.
      # Used where entries were already taken out of the cache, so nothing else
      # would close them.
      def uninterrupted(&)
        task = Async::Task.current?
        task ? task.defer_cancel(&) : yield
      end

      # Closes entries that are already out of the cache, so nothing else would
      # close them. `defer_cancel` holds back only the first cancel (a task under
      # an `Async::Barrier` can get two from one stop), so the closes run in a
      # transient task, which a cancel of the caller does not reach. The caller
      # waits for it; a second cancel ends only that wait.
      #
      # A client can be busy without a request that counts as using it: an
      # upload that goes on after the server answered early. Its close waits
      # for that upload, which must not hold up the caller (possibly a call to
      # another endpoint that evicted it), so it is left to the transient task.
      def close_entries(entries, &close)
        entries = entries.compact
        return if entries.empty?

        task = Async::Task.current?
        return entries.each(&close || method(:close_entry)) unless task

        unless close
          close = method(:close_entry)
          busy, entries = entries.partition { busy?(it) }
          task.async(transient: true) { busy.each(&close) } unless busy.empty?
          return if entries.empty?
        end

        closer = task.async(transient: true) { entries.each(&close) }
        uninterrupted { closer.wait }
      end

      def busy?(entry)
        return false if entry_dead?(entry)

        pools_of(extract_client(entry)).to_a.any?(&:busy?)
      rescue StandardError
        false
      end

      # Waits for the client's requests, then closes it. The wait is outside any
      # rescue, so cancelling the caller or its own timeout ends it.
      def close_gracefully(entry)
        wait_until_unused(entry)
        close_entry(entry)
      end

      # A request that is still opening its connection holds no connection of
      # the pool yet, so the pool alone cannot tell whether the client is in use.
      def wait_until_unused(entry)
        if entry.is_a?(Entry)
          (entry.unused ||= Async::Condition.new).wait while entry.inflight.to_i.positive?
        end
        pools_of(extract_client(entry))&.first&.wait_until_free
      end

      # Closes an entry without waiting for its requests. An entry that is in
      # use is closed by its last request instead (see `release_entry`).
      def close_without_waiting(entry)
        return close_entry(entry) if entry_dead?(entry)
        return if entry.is_a?(Entry) && entry.inflight.to_i.positive?

        client = extract_client(entry)
        pools_of(client).to_a.empty? ? safe_close(client) : force_close(client)
      end

      # Counts the entry as no longer in use, and closes what this request kept
      # alive: clients evicted late (in-flight entries are never evicted, so a
      # burst can leave the reactor over its LRU bound) and the entry itself if
      # it was cleared or replaced while in use.
      def release_entry(entry, key, config, reactor)
        # Only the owning reactor's fibers change the counter, so it needs no
        # lock, and a cancellation while waiting for the lock cannot leak it.
        entry.inflight = [entry.inflight.to_i - 1, 0].max
        entry.unused&.signal if entry.inflight.zero?

        uninterrupted do
          to_close = @mutex.synchronize do
            unmet = @over_limit[reactor]
            evicted = unmet ? evict_entries_locked(config, reactor, limit: unmet) : []
            detached = entry.inflight.zero? && !@clients[key].equal?(entry)
            detached ? evicted | [entry] : evicted
          end
          close_entries(to_close)
        end
      end

      # An Array, so that no value can run into the next one and values of
      # different types (`50`, `'50'`) stay apart. Strings are frozen copies: a
      # caller that changes its string in place must not change the hash of a
      # stored key, which would strand the entry.
      def cache_key(endpoint, config, reactor)
        [
          reactor.object_id, endpoint.scheme, endpoint.host, endpoint.port,
          Async::HTTP::Client.object_id,
          config.async_http_connection_limit,
          config.http_open_timeout,
          config.async_http_idle_timeout,
          config.http_idle_timeout,
          proxy_cache_value(config.http_proxy),
          config.ssl_verify_peer,
          ssl_cache_value(config.ssl_ca_store),
          ssl_cache_value(config.ssl_ca_bundle),
          ssl_cache_value(config.ssl_ca_directory),
          ssl_cache_value(config.ssl_cert),
          ssl_cache_value(config.ssl_key),
        ].map! { it.is_a?(String) ? -it : it }.freeze
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

      def evict_entries_locked(config, reactor, limit: config.async_http_max_cached_clients)
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
            candidate_entry = @clients[candidate]
            entry_valid_for?(candidate_entry, reactor) && candidate_entry.inflight.to_i <= 0
          end
          break unless key

          entry = @clients.delete(key)
          evicted << entry if entry
          current_size -= 1
        end

        # Still over a bound means in-flight entries blocked the eviction:
        # remember the tightest such bound, so the next release of this reactor
        # trims again. Clients with a larger (or no) bound share the cache and
        # must not clear it.
        unmet = [limit, @over_limit[reactor]].compact.min
        if current_size > unmet
          @over_limit[reactor] = unmet
        else
          @over_limit.delete(reactor)
        end
        evicted
      end

      def close_entry(entry)
        client = extract_client(entry)
        return unless client.respond_to?(:close)

        return close_orphaned(client) if entry_dead?(entry)

        reactor = entry_reactor(entry)
        if reactor && !reactor.equal?(current_reactor)
          logger_for&.debug('[aws-sdk-http-async] skipping close from different reactor')
          return
        end

        safe_close(client)
      rescue StandardError => e
        close_failed(e)
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

      # An entry is dead once its reactor was collected or closed. A closed
      # reactor stops its pools' gardener tasks, which close the connections.
      def entry_dead?(entry)
        return false unless entry.is_a?(Entry)

        ref = entry.reactor_ref
        return true unless ref&.weakref_alive?

        reactor = ref.__getobj__
        reactor.respond_to?(:closed?) && reactor.closed?
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
        close_failed(e)
      end

      # The owning reactor is gone, so no fiber is left to release a busy
      # connection and `Async::HTTP::Client#close` would wait forever for the
      # pool to drain. Close only idle clients; GC reclaims the rest.
      def close_orphaned(client)
        pools = pools_of(client)
        if pools.nil? || pools.any?(&:busy?)
          return logger_for&.debug('[aws-sdk-http-async] skipping close of busy client from a finished reactor')
        end

        safe_close(client)
      rescue StandardError => e
        close_failed(e)
      end

      # Waits until `deadline` for the client's requests to finish, then closes it
      # either way.
      def close_before(entry, deadline)
        client = extract_client(entry)
        return unless client.respond_to?(:close)

        pools = pools_of(client).to_a
        remaining = [deadline - monotonic_time, 0].max
        Async::Task.current.with_timeout(remaining, CloseDeadline) do
          wait_until_unused(entry)
          # Nothing to retire: WebMock does not show its pool.
          client.close if pools.empty?
        end
        force_close(client)
      rescue CloseDeadline
        logger_for&.warn('[aws-sdk-http-async] force-closing client (timeout)')
        force_close(client)
      rescue StandardError => e
        close_failed(e)
      end

      # A close that fails must not keep the other clients from being closed.
      # The caller's own timeout is not such a failure: it ends the caller.
      def close_failed(error)
        raise error if error.is_a?(Async::TimeoutError)

        logger_for&.warn("[aws-sdk-http-async] failed to close client: #{error.message}")
      end

      # `Async::HTTP::Client#close` waits for the pool to drain. Close the
      # connections under the in-flight requests instead; those requests fail
      # with a network error.
      def force_close(client)
        pools = pools_of(client).to_a
        return if pools.empty?

        @mutex.synchronize { @force_closed[client] = true }
        # Each retire frees a slot, so a request that was waiting for one may
        # connect meanwhile: repeat until nothing is left.
        pools.each do |pool|
          until pool.empty?
            pool.resources.to_a.each do |connection, usage|
              close_socket(connection) if usage.positive?
              pool.retire(connection)
            end
          end
        end
        # The client may hold more than its pools show (WebMock keeps a second
        # pool for stubbed responses), so the final close is not waited for.
        task = Async::Task.current?
        task ? task.async(transient: true) { safe_close(client) } : safe_close(client)
      rescue StandardError => e
        close_failed(e)
      end

      # Closing a connection flushes its stream, under the stream's write lock,
      # and TLS flushes once more. A request that is blocked writing its body
      # holds that lock until the peer reads or the socket times out, so the
      # close would wait as long (several socket timeouts under TLS). Closing
      # the socket underneath fails the blocked write at once, and the stream
      # then closes without flushing.
      def close_socket(connection)
        stream = connection.stream if connection.respond_to?(:stream)
        io = stream.io if stream.respond_to?(:io)
        # Under TLS: the TCP socket, because `SSLSocket#close` flushes too.
        io = io.to_io if io.respond_to?(:to_io)
        io.close if io.respond_to?(:close)
      rescue StandardError
        nil
      end

      # Closing a socket under a blocked request makes Ruby interrupt that fiber
      # with an IOError, which the scheduler delivers on its next turn. A request
      # that left its read before that (its own timeout fired in the same timer
      # batch) would get the error at its next yield point instead, which may be
      # the caller's own code. Take it here: the interrupt is queued ahead of
      # this yield.
      #
      # A tunnel that is stopped under its request (a second stop of the
      # reactor, its close) leaves the same interrupt behind: the end of the
      # stream wakes the request first. A stop or a timeout that arrives during
      # the yield is held until the interrupt is taken. `defer_cancel` cannot do
      # that for a task whose own `defer_stop` already holds a cancel, and the
      # interrupt would otherwise replace the stop, or reach the task while it
      # stops its children, outside any `rescue`, and end the reactor.
      def take_close_interrupt
        held = nil
        begin
          Async::Task.current.yield
        rescue IOError
          nil
        rescue Async::Stop, Async::TimeoutError => held
          retry
        end
        raise held if held
      end

      # A tunnel that is stopped closes its socket under the request using it,
      # like `clear!(timeout:)` does.
      def tunnels_cut(client)
        client.tunnels_cut if client.respond_to?(:tunnels_cut)
      end

      # @return [Array<Async::Pool::Controller>, nil] nil when the client does
      #   not let its pool be inspected
      def pools_of(client)
        return client.pools if client.respond_to?(:pools)

        client.respond_to?(:pool) ? [client.pool] : []
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise unless ClientCache.pool_refused?(e)

        nil
      end

      # The key and the client both read the working directory (relative TLS
      # paths) and the client class (WebMock swaps it), at different moments.
      # If those changed in between, the client is built again: it must not be
      # cached under a key that names other settings than its own.
      #
      # @return [Array(Array, Entry)] the key the entry was built for, and the entry
      def build_for_key(endpoint, config, reactor, key)
        loop do
          entry = build_entry(endpoint, config, reactor)
          current = cache_key(endpoint, config, reactor)
          return [key, entry] if current == key

          close_entries([entry])
          key = current
        end
      end

      def build_entry(endpoint, config, reactor)
        client = build_client(endpoint, config)
        @mutex.synchronize { @built[client] = true }
        Entry.new(client, WeakRef.new(reactor), 0, limiter_for(config))
      end

      # Stands in for "no bound" where async-pool wants an Integer.
      UNBOUNDED_CONNECTS = 1 << 30

      # @return [Integer, nil] nil for no limit: nil, zero or less, infinity
      def connection_limit(config)
        limit = config.async_http_connection_limit
        return if limit.nil?
        raise ArgumentError, 'async_http_connection_limit must be a number or nil' unless limit.is_a?(Numeric)

        limit.ceil if limit.positive? && limit.finite?
      end

      # Waits until fewer than `async_http_connection_limit` requests use the
      # client, for at most `async_http_header_timeout`.
      def wait_for_turn(limiter, config)
        timeout = config.async_http_header_timeout
        return limiter.acquire unless timeout && timeout > 0

        Async::Task.current.with_timeout(timeout, TransportTimeoutError, 'timed out waiting for a free connection') do
          limiter.acquire
        end
      end

      # The pool may open connections concurrently (see `pool_options`), which
      # keeps to its limit only while no more than `limit` requests use it at
      # once. This semaphore guarantees that for requests made through
      # `with_client`.
      def limiter_for(config)
        limit = connection_limit(config)
        Async::Semaphore.new(limit) if limit
      end

      # async-pool opens one connection at a time by default and holds that
      # guard even to hand out an idle connection, so one slow connect would
      # make every call to the endpoint wait. Without a limit the guard has
      # nothing to protect, so it must not serialize connects either.
      def pool_options(config, idle: config.http_idle_timeout)
        limit = connection_limit(config)
        options = { retries: 0, limit:, concurrency: limit || UNBOUNDED_CONNECTS }
        options[:policy] = IdlePolicy.new(idle) if idle && idle > 0
        options
      end

      def build_client(endpoint, config)
        target_endpoint = build_endpoint(endpoint, config)
        return Async::HTTP::Client.new(target_endpoint, **pool_options(config)) unless config.http_proxy

        proxy_endpoint = build_proxy_endpoint(config)
        proxy_client = Async::HTTP::Client.new(proxy_endpoint, **pool_options(config))
        proxy = proxy_client.proxy(target_endpoint, proxy_headers(proxy_endpoint.url))
        tunnels = TunnelEndpoint.new(target_endpoint, proxy)
        client = Async::HTTP::Client.new(tunnels, **pool_options(config, idle: tunnel_idle_timeout(config)))
        tunnels.pool = -> { pools_of(client)&.first }
        ProxyClient.new(client, proxy_client, tunnels)
      end

      # The proxy socket's I/O timeout (see `build_timeout`) ends an idle
      # tunnel inside async-http without closing the connection on top of it,
      # and the next call would wait for an answer that cannot come. Idle
      # tunnels are therefore retired well before that: the policy retires
      # after one to two times its timeout.
      def tunnel_idle_timeout(config)
        io_timeout = build_timeout(config)
        [config.http_idle_timeout, (io_timeout / 3.0 if io_timeout)].compact.select(&:positive?).min
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
        open_timeout = config.http_open_timeout
        return open_timeout if open_timeout && open_timeout > 0

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
            context.ca_file = absolute_path(config.ssl_ca_bundle) if config.ssl_ca_bundle
            context.ca_path = absolute_path(config.ssl_ca_directory) if config.ssl_ca_directory
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
          if Async::Task.current?
            logger = logger_for
            logger&.debug('[aws-sdk-http-async] loading ssl_cert from path inside reactor (blocking IO)')
          end
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
          if Async::Task.current?
            logger = logger_for
            logger&.debug('[aws-sdk-http-async] loading ssl_key from path inside reactor (blocking IO)')
          end
          return OpenSSL::PKey.read(File.read(path))
        end

        raise ArgumentError, "ssl_key must be an OpenSSL::PKey or a file path (got #{value.class})"
      rescue StandardError => e
        raise ArgumentError, "failed to load ssl_key: #{e.message}"
      end

      def ssl_cache_value(value)
        return nil if value.nil?

        path = value.respond_to?(:to_path) ? value.to_path : value
        return value.object_id.to_s unless path.is_a?(String)
        # Keeps '' apart from nil, so an invalid empty value is not served a
        # client that was cached for nil.
        return '""' if path.empty?

        absolute_path(path)
      end

      # Files are read relative to the working directory at build time. OpenSSL
      # reads the CA bundle and directory only when the context is first used,
      # so they are handed over as absolute paths. The path is not normalized:
      # `..` after a symlink names another file than its lexical parent.
      def absolute_path(path)
        path = path.to_path if path.respond_to?(:to_path)
        return path unless path.is_a?(String) && !path.empty?

        File.absolute_path?(path) ? path : File.join(Dir.pwd, path)
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
