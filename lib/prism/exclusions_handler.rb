# frozen_string_literal: true

require 'json'

module Prism
  class ExclusionsHandler
    EXCEPTIONS_FILENAME = '.prism/exceptions.json'

    def initialize(exceptions_path: nil, source_file: nil)
      @exceptions_path = exceptions_path || find_exceptions_file(source_file)
      @exclusions = load_exceptions
    end

    def excluded?(key, locale)
      locales = @exclusions[key]
      return false unless locales

      locales.include?(locale)
    end

    def excluded_locales(key)
      @exclusions[key]&.dup || []
    end

    def filter(hash, locale)
      hash.reject { |key, _| excluded?(key, locale) }
    end

    def exclusions
      @exclusions.transform_values(&:dup)
    end

    private

    def find_exceptions_file(source_file)
      return nil unless source_file

      dir = File.dirname(File.expand_path(source_file))
      loop do
        candidate = File.join(dir, EXCEPTIONS_FILENAME)
        return candidate if File.exist?(candidate)

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end

      nil
    end

    def load_exceptions
      return {} unless @exceptions_path && File.exist?(@exceptions_path)

      content = File.read(@exceptions_path)
      return {} if content.strip.empty?

      data = JSON.parse(content)
      unless data.is_a?(Hash)
        Logging.log("Warning: #{@exceptions_path} must contain a JSON object, ignoring")
        return {}
      end

      data.each_with_object({}) do |(key, locales), result|
        next unless key.is_a?(String)

        if locales.is_a?(Array)
          valid_locales = locales.select { |l| l.is_a?(String) }
          result[key] = Set.new(valid_locales) if valid_locales.any?
        end
      end
    rescue JSON::ParserError => e
      Logging.log("Warning: Failed to parse #{@exceptions_path}: #{e.message}")
      {}
    end
  end
end
