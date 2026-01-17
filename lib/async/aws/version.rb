module Async
  module Aws
    VERSION = File.read(File.expand_path('../../../VERSION', __dir__)).strip

    def self.const_missing(name)
      return ::Aws.const_get(name) if ::Aws.const_defined?(name)

      super
    end
  end
end
