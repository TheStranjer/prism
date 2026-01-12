# Prism Auto-Translate Action

Auto-translate i18n JSON/YAML files when the source language changes. The action inspects the diff for the source locale file, translates changed keys, backfills missing keys in target locales, updates the target locale files, and opens a pull request.

## What it does

1. Checks if the source locale file changed in the specified commit.
2. Extracts changed keys and their updated strings.
3. Sends each updated string to the configured engine (ChatGPT today).
4. Updates target locale files (JSON or YAML, with or without root locale).
5. Creates a pull request with the translated changes.

## Inputs

- `source_file` (required): Path to the source locale file (e.g. `src/locales/en.json`).
- `target_languages` (required): Comma-separated list of target locales (e.g. `fr,es,de`).
- `source_repo` (required): `owner/name` repository slug. Usually `${{ github.repository }}`.
- `source_commit` (required): Commit SHA to compare against its parent. Usually `${{ github.sha }}`.
- `author_name` (required): Git author name for the translation commit.
- `author_email` (required): Git author email for the translation commit.
- `engine` (required): Translation engine name (use `ChatGPT`).
- `api_token` (required): API token for the translation engine.
- `model` (required): Model identifier for the translation engine.
- `retries` (optional): Number of retry attempts when translations are incomplete (default: `5`). Use `0` to disable retries.
- `github_token` (required): Token used to push the branch and open PRs.

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
          source_repo: ${{ github.repository }}
          source_commit: ${{ github.sha }}
          author_name: "Prism Bot"
          author_email: "prism-bot@example.com"
          engine: "ChatGPT"
          api_token: ${{ secrets.OPENAI_API_KEY }}
          model: "gpt-4o-mini"
          retries: "5"
          github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Notes

- The action expects the repo to be checked out with full history (`fetch-depth: 0`) so it can inspect diffs.
- Target locale files are inferred by swapping the source locale filename (e.g. `en.json` -> `fr.json`).
