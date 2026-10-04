#!/usr/bin/env bash
#
# local-tests.sh — run the full local check suite: rspec + rubocop.
# Exits 0 only if both succeed, 1 otherwise.

set -u

cd "$(dirname "$0")"

status=0

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
