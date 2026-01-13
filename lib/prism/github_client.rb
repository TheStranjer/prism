# frozen_string_literal: true

require 'faraday'
require 'json'

module Prism
  class GitHubClient
    def initialize(token:, repo_slug:, http_client: nil)
      @token = token
      @repo_slug = repo_slug
      @http_client = http_client || Faraday.new(url: 'https://api.github.com')
    end

    def create_pull_request(head:, title:, body:, base: nil)
      base ||= default_branch
      payload = {
        title: title,
        head: head,
        base: base,
        body: body
      }

      response = @http_client.post("/repos/#{@repo_slug}/pulls", payload.to_json, headers)
      ensure_success!(response, 'create pull request')
      JSON.parse(response.body)
    end

    def default_branch
      response = @http_client.get("/repos/#{@repo_slug}", nil, headers)
      ensure_success!(response, 'fetch default branch')
      JSON.parse(response.body).fetch('default_branch')
    end

    def branch_head_sha(branch)
      response = @http_client.get("/repos/#{@repo_slug}/branches/#{branch}", nil, headers)
      ensure_success!(response, "fetch branch #{branch}")
      JSON.parse(response.body).dig('commit', 'sha')
    end

    def pull_request_for_branch(branch)
      owner = @repo_slug.split('/').first
      response = @http_client.get("/repos/#{@repo_slug}/pulls", { head: "#{owner}:#{branch}", state: 'open' }, headers)
      ensure_success!(response, "fetch pull requests for #{branch}")
      JSON.parse(response.body).first
    end

    def validate_token(delivery_method:)
      return false if @token.nil? || @token.strip.empty?

      response = @http_client.get("/repos/#{@repo_slug}", nil, headers)
      return false unless response.success?

      data = JSON.parse(response.body)
      permissions = data['permissions'] || {}

      return false unless permissions['push']
      return false if delivery_method == 'pull_request' && !permissions['pull']

      true
    rescue StandardError
      false
    end

    def validate_token_with_reason(delivery_method:)
      return { valid: false, reason: :missing } if @token.nil? || @token.strip.empty?

      response = @http_client.get("/repos/#{@repo_slug}", nil, headers)

      unless response.success?
        reason = response.status == 401 ? :expired : :no_access
        return { valid: false, reason: reason }
      end

      data = JSON.parse(response.body)
      permissions = data['permissions'] || {}

      return { valid: false, reason: :no_push_permission } unless permissions['push']

      if delivery_method == 'pull_request' && !permissions['pull']
        return { valid: false, reason: :no_pull_request_permission }
      end

      { valid: true, reason: nil }
    rescue StandardError => e
      { valid: false, reason: :error, message: e.message }
    end

    private

    def headers
      {
        'Authorization' => "Bearer #{@token}",
        'Content-Type' => 'application/json',
        'Accept' => 'application/vnd.github+json'
      }
    end

    def ensure_success!(response, action)
      return if response.status.between?(200, 299)

      message = response.body.to_s.strip
      details = message.empty? ? 'no response body' : message
      raise "GitHub API failed to #{action} (status #{response.status}): #{details}"
    end
  end
end
