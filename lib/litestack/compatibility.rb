# frozen_string_literal: true

module Litestack
  # Raised when a Rails-facing entry point loads against an unsupported framework version.
  class UnsupportedFrameworkVersionError < StandardError; end

  # Rails support band for optional integrations. Rails is never a runtime dependency of the gem;
  # this gate runs only when a Railtie or Rails adapter is loaded.
  RAILS_REQUIREMENT = Gem::Requirement.new(">= 8.1", "< 9").freeze

  module Compatibility
    module_function

    # Verify that the loaded Rails version is within the supported band.
    # Call only from Railtie / adapter entry points — never from `require "litestack"`.
    #
    # @param rails_version [String, Gem::Version, nil] defaults to Rails::VERSION::STRING when Rails is loaded
    # @raise [UnsupportedFrameworkVersionError] when Rails is absent or outside >= 8.1, < 9
    # @return [true]
    def assert_rails_supported!(rails_version = nil)
      version = resolve_rails_version(rails_version)
      if version.nil?
        raise UnsupportedFrameworkVersionError,
          "Litestack Rails integrations require Rails #{RAILS_REQUIREMENT}, but Rails is not loaded."
      end

      unless RAILS_REQUIREMENT.satisfied_by?(Gem::Version.new(version.to_s))
        raise UnsupportedFrameworkVersionError,
          "Litestack requires Rails #{RAILS_REQUIREMENT} (got #{version}). " \
          "Ruby versions below 4.0 and Rails versions below 8.1 are unsupported."
      end

      true
    end

    # @return [Boolean]
    def rails_supported?(rails_version = nil)
      version = resolve_rails_version(rails_version)
      return false if version.nil?

      RAILS_REQUIREMENT.satisfied_by?(Gem::Version.new(version.to_s))
    rescue ArgumentError
      false
    end

    def resolve_rails_version(rails_version)
      return rails_version if rails_version

      if defined?(Rails::VERSION::STRING)
        return Rails::VERSION::STRING
      end
      # Adapters may load after Active Support / Action Cable without full Rails constant.
      if defined?(ActiveSupport::VERSION::STRING)
        return ActiveSupport::VERSION::STRING
      end
      if defined?(ActionCable::VERSION::STRING)
        return ActionCable::VERSION::STRING
      end
      nil
    end
    private_class_method :resolve_rails_version
  end
end
