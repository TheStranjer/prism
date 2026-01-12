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
        return error_payload("HTTP #{response.status}: #{response.body}") unless response.success?

        body = JSON.parse(response.body)
        puts "Response body: #{JSON.pretty_generate(body)}"
        message = body.dig("choices", 0, "message") || {}
        arguments = tool_arguments_from(message)
        return error_payload("No tool call or JSON content in response") unless arguments

        parsed = JSON.parse(arguments)
        return error_payload("Tool call arguments are not a JSON object") unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        error_payload("Invalid JSON in tool call arguments: #{e.message}")
      rescue StandardError => e
        error_payload("Unexpected error parsing translation response: #{e.message}")
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
        "You translate i18n strings. Translate the user message into each of: #{target_languages.join(", ")}. " \
          "Return translations for every locale using those exact locale keys. " \
          "If a locale cannot be translated, include an error message for that locale."
      end

      def translation_tool
        {
          type: "function",
          function: {
            name: "translations",
            description: "Return translations keyed by target locale, and optional per-locale errors.",
            parameters: {
              type: "object",
              properties: {
                translations: {
                  type: "object",
                  additionalProperties: { type: "string" }
                },
                errors: {
                  type: "object",
                  additionalProperties: { type: "string" }
                }
              },
              required: ["translations"]
            }
          }
        }
      end

      def tool_arguments_from(message)
        tool_call = message["tool_calls"]&.first
        arguments = tool_call&.dig("function", "arguments")
        return arguments if arguments

        function_call = message["function_call"]
        arguments = function_call&.dig("arguments")
        return arguments if arguments

        content = message["content"]
        return content if content && content.strip.start_with?("{")

        nil
      end

      def error_payload(message)
        { "translations" => {}, "errors" => { "_request" => message } }
      end
    end
  end
end
