# frozen_string_literal: true

require 'open3'

module Prism
  class GitRepo
    def initialize(path)
      @path = path
    end

    def capture(command)
      Open3.capture2e(command, chdir: @path)
    end

    def capture3(command)
      Open3.capture3(command, chdir: @path)
    end

    def git_show(commit, file)
      output, status = capture("git show #{commit}:#{file}")
      return nil unless status.success?

      output
    end

    def diff_names(commit, file)
      output, status = capture("git diff --name-only #{commit}^ #{commit} -- #{file}")
      return [] unless status.success?

      output.split("\n").map(&:strip).reject(&:empty?)
    end

    def set_identity(name, email)
      capture("git config user.name #{shell_escape(name)}")
      capture("git config user.email #{shell_escape(email)}")
    end

    def checkout_new_branch(branch)
      capture("git checkout -b #{branch}")
    end

    def add(paths)
      joined = paths.map { |path| shell_escape(path) }.join(' ')
      capture("git add #{joined}")
    end

    def commit(message)
      # Use array form to bypass shell interpretation - this safely handles
      # messages with parentheses, quotes, backticks, and other special characters
      Open3.capture2e('git', 'commit', '-m', message, chdir: @path)
    end

    def push(branch, remote: 'origin')
      capture("git push #{remote} #{branch}")
    end

    def current_branch
      output, = capture('git rev-parse --abbrev-ref HEAD')
      output.strip
    end

    def head_sha
      output, status = capture('git rev-parse HEAD')
      return nil unless status.success?

      output.strip
    end

    def changed_files(commit)
      output, status = capture("git diff --name-only #{commit}^ #{commit}")
      return [] unless status.success?

      output.split("\n").map(&:strip).reject(&:empty?)
    end

    def staged_diff
      output, status = capture('git diff --cached')
      return nil unless status.success?

      output
    end

    def show_commit(commit)
      output, status = capture("git show #{commit}")
      return nil unless status.success?

      output
    end

    def relative_path(path)
      absolute = Pathname.new(path).cleanpath
      base = Pathname.new(@path).cleanpath
      return absolute.relative_path_from(base).to_s if absolute.to_s.start_with?("#{base}/")

      path
    end

    private

    def shell_escape(value)
      value.to_s.gsub("'", "'\\''").prepend("'").concat("'")
    end
  end
end
