require 'seahorse/client/base'

module Async
  module Aws
    module Patcher
      MUTEX = Mutex.new
      @patched_base = false
      @patched_clients = {}
      @inherited_tracker_installed = false

      module InheritedTracker
        def inherited(subclass)
          super
          return unless Async::Aws::Patcher.send(:patched_base?)

          Async::Aws::Patcher.send(:__track_client, subclass)
        end
      end

      # @param services [Array<Symbol>, Symbol] :all or list of service identifiers
      # @return [void]
      def self.patch(services = :all)
        MUTEX.synchronize do
          if services == :all
            patch_base!
            patch_existing_clients!
            return
          end

          Array(services).each do |service|
            client_class = resolve_client_class(service)
            next unless client_class

            patch_client!(client_class)
          end
        end
      end

      # @param services [Array<Symbol>, Symbol] :all or list of service identifiers
      # @return [void]
      def self.unpatch(services = :all)
        MUTEX.synchronize do
          if services == :all
            unpatch_base!
            unpatch_existing_clients!
            return
          end

          Array(services).each do |service|
            client_class = resolve_client_class(service)
            next unless client_class

            unpatch_client!(client_class)
          end
        end
      end

      def self.patch_base!
        return if @patched_base
        return if plugin_registered?(::Seahorse::Client::Base)

        ::Seahorse::Client::Base.add_plugin(HttpPlugin)
        @patched_base = true
        install_inherited_tracker!
      end
      private_class_method :patch_base!

      def self.unpatch_base!
        return unless @patched_base

        ::Seahorse::Client::Base.remove_plugin(HttpPlugin)
        @patched_base = false
      end
      private_class_method :unpatch_base!

      def self.unpatch_existing_clients!
        @patched_clients.keys.each do |klass|
          next unless plugin_registered?(klass)

          klass.remove_plugin(HttpPlugin)
        end
        @patched_clients.clear
      end
      private_class_method :unpatch_existing_clients!

      def self.patch_existing_clients!
        ObjectSpace.each_object(Class) do |klass|
          next unless klass < ::Seahorse::Client::Base

          patch_client!(klass)
        end
      end
      private_class_method :patch_existing_clients!

      def self.patch_client!(client_class)
        return if plugin_registered?(client_class)

        client_class.add_plugin(HttpPlugin)
        @patched_clients[client_class] = true
      end
      private_class_method :patch_client!

      def self.unpatch_client!(client_class)
        return unless @patched_clients.delete(client_class)

        client_class.remove_plugin(HttpPlugin)
      end
      private_class_method :unpatch_client!

      def self.install_inherited_tracker!
        return if @inherited_tracker_installed

        ::Seahorse::Client::Base.singleton_class.prepend(InheritedTracker)
        @inherited_tracker_installed = true
      end
      private_class_method :install_inherited_tracker!

      def self.__track_client(klass)
        return unless @patched_base
        return unless klass.is_a?(Class)
        return unless klass < ::Seahorse::Client::Base

        MUTEX.synchronize do
          @patched_clients[klass] = true
        end
      end
      private_class_method :__track_client

      def self.plugin_registered?(client_class)
        client_class.plugins.any? do |plugin|
          plugin == HttpPlugin || (plugin.is_a?(Class) && plugin <= HttpPlugin)
        end
      end
      private_class_method :plugin_registered?

      def self.patched_base?
        @patched_base
      end
      private_class_method :patched_base?

      def self.resolve_client_class(service)
        if service.is_a?(Class) && service < ::Seahorse::Client::Base
          return service
        end

        if service.is_a?(Module) && service.const_defined?(:Client)
          client = service.const_get(:Client)
          return client if client < ::Seahorse::Client::Base
        end

        target = service.to_s.downcase.delete('_')
        ::Aws.constants.each do |const|
          next unless const.to_s.downcase == target

          mod = ::Aws.const_get(const)
          next unless mod.is_a?(Module) && mod.const_defined?(:Client)

          client = mod.const_get(:Client)
          return client if client < ::Seahorse::Client::Base
        end

        nil
      end
      private_class_method :resolve_client_class
    end
  end
end
