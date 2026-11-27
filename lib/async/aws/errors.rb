require 'async'

module Async
  module Aws
    class NoReactorError < RuntimeError; end
    class BodyTooLargeError < RuntimeError; end

    # A deadline of the transport itself (`http_read_timeout`,
    # `async_http_header_timeout`, `async_http_total_timeout`, the wait for a
    # free connection). Its own class tells it apart from a timeout the caller
    # put around the call (`task.with_timeout { client.get_item(...) }`), which
    # must reach the caller as it is.
    class TransportTimeoutError < Async::TimeoutError
      # The handler invocation whose `async_http_total_timeout` this is. That
      # deadline also runs while a streaming block makes another AWS call,
      # which must not take it for a timeout of its own. Nil for the deadlines
      # that only run inside the invocation that set them.
      #
      # @api private
      # @return [Object, nil]
      attr_accessor :scope
    end
  end
end
