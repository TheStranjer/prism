# Prism Auto-Translate Action

Auto-translate i18n JSON/YAML files when the source language changes. The action inspects the diff for the source locale file, translates changed keys, backfills missing keys in target locales, updates the target locale files, and delivers the changes via a pull request or direct push.

## What it does

1. Checks if the source locale file changed in the specified commit.
2. Extracts changed keys and their updated strings.
3. Sends each updated string to the configured engine (ChatGPT today).
4. Updates target locale files (JSON or YAML, with or without root locale).
5. Prunes stale entries: keys present in a target locale file but no longer in the source file are removed.
6. Commits the changes with either an LLM-generated message (if `llm_commit_messages: true`) or a default message.
7. Creates a pull request with the translated changes (or pushes directly if configured).

## Inputs

- `source_file` (required): Path to the source locale file (e.g. `src/locales/en.json`).
- `target_languages` (required): Comma-separated list of target locales (e.g. `fr,es,de`).
- `source_repo` (optional): `owner/name` repository slug (default: `${{ github.repository }}`).
- `source_commit` (optional): Commit SHA to compare against its parent (default: `${{ github.sha }}`).
- `author_name` (optional): Git author name for the translation commit (default: `TheStranjer`).
- `author_email` (optional): Git author email for the translation commit (default: `thestranjer@protonmail.com`).
- `engine` (optional): Translation engine name (default: `ChatGPT`).
- `api_token` (required): API token for the translation engine.
- `model` (optional): Model identifier for the translation engine (default: `gpt-5-mini`).
- `retries` (optional): Number of retry attempts when translations are incomplete (default: `5`). Use `0` to disable retries.
- `github_token` (required): Token used to push the branch and open PRs.
- `delivery_method` (optional): `pull_request` (default) or `push`. Use `push` to commit directly to the current branch.
- `llm_commit_messages` (optional): `true` or `false` (default). When enabled, uses the LLM to generate descriptive commit messages based on the translation changes. When disabled, uses a generic "Update translations" message.

## GitHub token permissions

The `github_token` is used to push the translation branch over HTTPS and, in `pull_request` mode, to read the default branch and open a pull request via the REST API. The default `GITHUB_TOKEN` works as long as the job-level `permissions` block (shown in the example below) grants what the delivery method needs. If you use a personal access token (PAT) instead:

### Fine-grained PAT

Repository access: **Only select repositories** (the target repo). Under *Repository permissions*:

| Permission | Access | Needed for |
| --- | --- | --- |
| Contents | Read and write | Pushing the translation branch (both delivery methods) |
| Pull requests | Read and write | Opening and checking for PRs (`delivery_method: pull_request`) |
| Metadata | Read (automatic) | Reading the repository's default branch; required for any fine-grained PAT |

For `delivery_method: push`, **Pull requests** is not required; **Contents: Read and write** is sufficient.

### Classic PAT

The `repo` scope covers everything the action does (push, branch reads, PR creation).

The action validates the token up front and fails fast with a specific reason (missing, expired, no push permission, or no pull permission for PR delivery) rather than after translating.

## Example workflow

```yaml
name: Auto-translate i18n

on:
  push:
    paths:
      - "src/locales/en.json"

jobs:
  translate:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Prism Auto-Translate
        uses: TheStranjer/prism@master
        with:
          source_file: "src/locales/en.json"
          target_languages: "fr,es,de"
          api_token: ${{ secrets.OPENAI_API_KEY }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Key Exceptions

You can exclude specific translation keys from automatic translation for certain locales by listing them in `.prism/exceptions.json`. This is useful for keys that have been manually translated and should not be overwritten by the automated process.

Create a `.prism/exceptions.json` file in your repository root containing a JSON object where keys are dot-notation translation keys and values are arrays of locale codes to exclude:

```json
{
  "app.brand_name": ["pl", "de"],
  "legal.terms_of_service": ["es", "fr", "ru"],
  "marketing.tagline": ["ja"]
}
```

In this example:
- `app.brand_name` has manual translations in Polish and German
- `legal.terms_of_service` has manual translations in Spanish, French, and Russian
- `marketing.tagline` has a manual translation in Japanese

These keys will still be auto-translated for other target locales not listed in their exclusion arrays.

The action searches for the exceptions file starting from the source file's directory and walking up to the repository root.

## Development

The Ruby version is declared once, in `.ruby-version`:

- `action.yml` hands `.ruby-version` to `ruby/setup-ruby` (resolved relative to the action directory, not the calling repo), so the Ruby that serves translation traffic in consumer workflows is the pinned one.
- `.github/workflows/ci.yml` does the same for the RuboCop and RSpec jobs, so CI and production agree.
- `.rubocop.yml` leaves `TargetRubyVersion` unset, which makes RuboCop read `.ruby-version` as well.
- `mise.toml` repeats the same version because the mise `ruby` plugin does not read `.ruby-version` on its own. Bump the two together.

Run everything with `./local-tests.sh`, which runs RSpec and then RuboCop.

### Linting

RuboCop loads the `officer_neetzsche` plugin through `plugins:` in `.rubocop.yml`. Every `NEETzsche/*` cop it ships is enabled, and they shape this source:

- `NEETzsche/NoComments` keeps comments out of the Ruby files, so why a method exists goes in its name, in the specs, or here. `action.yml`, `.rubocop.yml` and `mise.toml` are not Ruby, so their comments stay.
- `NEETzsche/MultilineConditionalBody` gives an `if`, `unless`, `while` or `until` body room for one statement, which is why branches delegate to small private methods.
- `NEETzsche/StatementModifier` writes each single-statement body as a modifier, so a guard stays on one line.

`Layout/LineLength` still caps a line at 120 characters and those cops ignore it, so a guard that no longer fits keeps its condition in a predicate and its message in a method instead of wrapping.

### Installing gems for each Ruby

Bundler installs into the gem home of whichever Ruby ran `bundle install`, so every interpreter on a machine needs its own install. When `mise install` adds a Ruby, or you switch versions, `bundle exec` fails with `Bundler::GemNotFound` even though `Gemfile.lock` is complete and correct. With the new Ruby active:

```sh
ruby -v          # confirm mise resolved the version you expect
bundle install
./local-tests.sh
```

`./local-tests.sh` runs `bundle check` first and prints this same instruction instead of letting Bundler fail in the middle of the suite.

## Notes

- The action expects the repo to be checked out with full history (`fetch-depth: 0`) so it can inspect diffs.
- Target locale files are inferred by swapping the source locale filename (e.g. `en.json` -> `fr.json`).
- Deleting a key from the source file prunes it from every target locale file on the next run, even when nothing needs translating.
- For `delivery_method: pull_request`, grant `pull-requests: write`; for `push`, `contents: write` is sufficient.
- For `delivery_method: push`, check out a branch ref (not a detached HEAD) so the commit has a branch to land on.

## LLM-Generated Commit Messages

When `llm_commit_messages: true` is set, the action calls the LLM to generate meaningful commit messages after translating strings and staging the changes. The LLM receives two pieces of context:

1. **The original commit** (via `git show <sha>`) - shows what changed in the source locale file that triggered the translation
2. **The staged translation changes** (via `git diff --cached`) - shows the translations that will be committed

This allows the LLM to understand both the intent of the original change and the resulting translations, enabling it to generate descriptive, context-aware messages.

### Push Mode

When `delivery_method: push`, the LLM generates a commit message using a tool that returns:

```json
{
  "commit_message": "Add French and German translations for new greeting strings"
}
```

### Pull Request Mode

When `delivery_method: pull_request`, the LLM generates both a commit message and PR metadata using a tool that returns:

```json
{
  "commit_message": "Add translations for updated welcome message",
  "pr_title": "Update translations for welcome message changes",
  "pr_description": "This PR adds French, Spanish, and German translations for the updated welcome message. The source text was changed from 'Hello' to 'Welcome back' and all target locales have been updated accordingly."
}
```

### Default Mode (llm_commit_messages: false)

When `llm_commit_messages` is not set or set to `false`, the action uses a simple default message:
- Commit message: "Update translations"
- PR title (if applicable): "Update translations"
- PR description (if applicable): "Automated translation updates."
