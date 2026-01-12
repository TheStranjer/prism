# frozen_string_literal: true

require "faraday"
require "json"

module Prism
  class GitHubClient
    def initialize(token:, repo_slug:, http_client: nil)
      @token = token
      @repo_slug = repo_slug
      @http_client = http_client || Faraday.new(url: "https://api.github.com")
    end

    def create_pull_request(head:, title:, body:, base: nil)
      base ||= default_branch
      payload = {
        title: title,
        head: head,
        base: base,
        body: body
      }

      @http_client.post("/repos/#{@repo_slug}/pulls", payload.to_json, headers)
    end

    def default_branch
      response = @http_client.get("/repos/#{@repo_slug}", nil, headers)
      JSON.parse(response.body).fetch("default_branch")
    end

    private

    def headers
      {
        "Authorization" => "Bearer #{@token}",
        "Content-Type" => "application/json",
        "Accept" => "application/vnd.github+json"
      }
    end
  end
end
