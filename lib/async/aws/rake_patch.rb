module Async
  module Aws
    module RakePatch
      # @param args [Array]
      # @return [Object]
      def top_level(*)
        return super if Async::Task.current?

        Async { super(*) }.wait
      end
    end
  end
end
