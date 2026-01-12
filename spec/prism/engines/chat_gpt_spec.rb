# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "json"

RSpec.describe Prism::Engines::ChatGPT do
  it "builds a tool-call request and parses translations" do
    stubs = Faraday::Adapter::Test::Stubs.new
    client = Faraday.new do |builder|
      builder.adapter :test, stubs
    end

    response_body = {
      "choices" => [
        {
          "message" => {
            "tool_calls" => [
              {
                "function" => {
                  "arguments" => { "translations" => { "fr" => "Bonjour" } }.to_json
                }
              }
            ]
          }
        }
      ]
    }

    stubs.post("https://api.openai.com/v1/chat/completions") do |env|
      body = JSON.parse(env.body)
      expect(body["messages"][0]["role"]).to eq("system")
      expect(body["messages"][1]["role"]).to eq("user")
      expect(body["messages"][1]["content"]).to eq("Hello")
      expect(body["tool_choice"]["function"]["name"]).to eq("translations")
      [200, { "Content-Type" => "application/json" }, response_body.to_json]
    end

    engine = described_class.new(api_token: "token", model: "gpt-4o-mini", http_client: client)
    result = engine.get_translations("Hello", ["fr"])

    expect(result).to eq({ "translations" => { "fr" => "Bonjour" } })
    stubs.verify_stubbed_calls
  end
end
