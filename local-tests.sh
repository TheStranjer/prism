#!/usr/bin/env bash
#
# local-tests.sh — run the full local check suite: rspec + rubocop.
# Exits 0 only if both succeed, 1 otherwise.

set -u

cd "$(dirname "$0")"

status=0

# Gems are installed per Ruby interpreter, so a Ruby version that was just
# added by `mise install` has none of them and every `bundle exec` below fails
# with Bundler::GemNotFound. Say so plainly instead of letting Bundler guess.
if ! bundle check >/dev/null 2>&1; then
  echo "Bundler: the locked gems are not installed for this Ruby ($(ruby -e 'print RUBY_VERSION'))."
  echo "Run 'bundle install' with this Ruby selected, then re-run ./local-tests.sh."
  exit 1
fi

echo "==> rspec"
bundle exec rspec || status=1

echo "==> rubocop"
bundle exec rubocop || status=1

if [ "$status" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "PASSED"
exit 0
