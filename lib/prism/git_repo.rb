# frozen_string_literal: true

require "open3"

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
      joined = paths.map { |path| shell_escape(path) }.join(" ")
      capture("git add #{joined}")
    end

    def commit(message)
      capture("git commit -m #{shell_escape(message)}")
    end

    def push(branch, remote: "origin")
      capture("git push #{remote} #{branch}")
    end

    def current_branch
      output, = capture("git rev-parse --abbrev-ref HEAD")
      output.strip
    end

    private

    def shell_escape(value)
      value.to_s.gsub("'", "'\\''").prepend("'").concat("'")
    end
  end
end
