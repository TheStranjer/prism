# frozen_string_literal: true

module Prism
  module Engines
    class Base
      def initialize(api_token:, model:)
        @api_token = api_token
        @model = model
      end

      def get_translations(_text, _target_languages)
        raise NotImplementedError, 'Implement in subclass'
      end
    end
  end
end
