module Async
  module Aws
    class NoReactorError < RuntimeError; end
    class BodyTooLargeError < RuntimeError; end
  end
end
