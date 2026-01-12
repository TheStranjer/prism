# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Prism::GitRepo do
  describe '#commit' do
    it 'handles commit messages with parentheses and single quotes' do
      Dir.mktmpdir do |dir|
        # Initialize a git repo
        system("git init #{dir}", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.email 'test@test.com'", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.name 'Test'", out: File::NULL, err: File::NULL)

        # Create and stage a file
        File.write(File.join(dir, 'test.txt'), 'hello')
        system("git -C #{dir} add test.txt", out: File::NULL, err: File::NULL)

        repo = described_class.new(dir)

        # This message contains parentheses and single quotes - the exact pattern that failed
        message = "Update translations for 'establishingConnection' to match source change " \
                  "('Connecting...') in de, es, fr, ja, ko, pt, ru, zh"

        output, status = repo.commit(message)

        expect(status.success?).to be(true), "Commit failed with output: #{output}"

        # Verify the commit message was preserved correctly
        log_output, = repo.capture('git log -1 --format=%s')
        expect(log_output.strip).to eq(message)
      end
    end

    it 'handles commit messages with backticks' do
      Dir.mktmpdir do |dir|
        system("git init #{dir}", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.email 'test@test.com'", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.name 'Test'", out: File::NULL, err: File::NULL)

        File.write(File.join(dir, 'test.txt'), 'hello')
        system("git -C #{dir} add test.txt", out: File::NULL, err: File::NULL)

        repo = described_class.new(dir)
        message = 'Update `config` with new values'

        output, status = repo.commit(message)

        expect(status.success?).to be(true), "Commit failed with output: #{output}"
      end
    end

    it 'handles commit messages with dollar signs' do
      Dir.mktmpdir do |dir|
        system("git init #{dir}", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.email 'test@test.com'", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.name 'Test'", out: File::NULL, err: File::NULL)

        File.write(File.join(dir, 'test.txt'), 'hello')
        system("git -C #{dir} add test.txt", out: File::NULL, err: File::NULL)

        repo = described_class.new(dir)
        message = 'Fix price display showing $100 incorrectly'

        output, status = repo.commit(message)

        expect(status.success?).to be(true), "Commit failed with output: #{output}"
      end
    end

    it 'handles commit messages with double quotes' do
      Dir.mktmpdir do |dir|
        system("git init #{dir}", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.email 'test@test.com'", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.name 'Test'", out: File::NULL, err: File::NULL)

        File.write(File.join(dir, 'test.txt'), 'hello')
        system("git -C #{dir} add test.txt", out: File::NULL, err: File::NULL)

        repo = described_class.new(dir)
        message = 'Update "welcome" message text'

        output, status = repo.commit(message)

        expect(status.success?).to be(true), "Commit failed with output: #{output}"
      end
    end

    it 'handles commit messages with newlines' do
      Dir.mktmpdir do |dir|
        system("git init #{dir}", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.email 'test@test.com'", out: File::NULL, err: File::NULL)
        system("git -C #{dir} config user.name 'Test'", out: File::NULL, err: File::NULL)

        File.write(File.join(dir, 'test.txt'), 'hello')
        system("git -C #{dir} add test.txt", out: File::NULL, err: File::NULL)

        repo = described_class.new(dir)
        message = "Add new feature\n\nThis is a longer description."

        output, status = repo.commit(message)

        expect(status.success?).to be(true), "Commit failed with output: #{output}"
      end
    end
  end
end
