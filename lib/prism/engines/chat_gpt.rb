# frozen_string_literal: true

require "faraday"
require "json"

module Prism
  module Engines
    class ChatGPT < Base
      OPENAI_URL = "https://api.openai.com/v1/chat/completions"

      def initialize(api_token:, model:, http_client: nil)
        super(api_token: api_token, model: model)
        @http_client = http_client || Faraday.new
      end

      def get_translations(text, target_languages)
        payload = build_payload(text, target_languages)
        response = @http_client.post(OPENAI_URL, payload.to_json, headers)
        body = JSON.parse(response.body)
        tool_call = body.dig("choices", 0, "message", "tool_calls", 0)
        arguments = tool_call.dig("function", "arguments")
        JSON.parse(arguments)
      end

      private

      def headers
        {
          "Authorization" => "Bearer #{@api_token}",
          "Content-Type" => "application/json"
        }
      end

      def build_payload(text, target_languages)
        {
          model: @model,
          messages: [
            {
              role: "system",
              content: system_prompt(target_languages)
            },
            {
              role: "user",
              content: text
            }
          ],
          tools: [translation_tool],
          tool_choice: { type: "function", function: { name: translation_tool[:function][:name] } }
        }
      end

      def system_prompt(target_languages)
        "You translate i18n strings. Translate the user message into: #{target_languages.join(", ")}."
      end

      def translation_tool
        {
          type: "function",
          function: {
            name: "translations",
            description: "Return translations keyed by target locale.",
            parameters: {
              type: "object",
              properties: {
                translations: {
                  type: "object",
                  additionalProperties: { type: "string" }
                }
              },
              required: ["translations"]
            }
          }
        }
      end
    end
  end
end
