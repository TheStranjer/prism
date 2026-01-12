# frozen_string_literal: true

module Prism
  class Logging
    class << self
      attr_accessor :output

      def log(message)
        stream = output || $stdout
        stream.puts(message)
        stream.flush
      end

      def reset!
        @output = nil
      end
    end
  end
end
