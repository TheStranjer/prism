# Prism Auto-Translate Action

Auto-translate i18n JSON/YAML files when the source language changes. The action inspects the diff for the source locale file, translates changed keys, backfills missing keys in target locales, updates the target locale files, and delivers the changes via a pull request or direct push.

## What it does

1. Checks if the source locale file changed in the specified commit.
2. Extracts changed keys and their updated strings.
3. Sends each updated string to the configured engine (ChatGPT today).
4. Updates target locale files (JSON or YAML, with or without root locale).
5. Generates a commit message (and PR title/description if using `pull_request` delivery) using the LLM based on the staged changes.
6. Creates a pull request with the translated changes (or pushes directly if configured).

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

## Notes

- The action expects the repo to be checked out with full history (`fetch-depth: 0`) so it can inspect diffs.
- Target locale files are inferred by swapping the source locale filename (e.g. `en.json` -> `fr.json`).
- For `delivery_method: pull_request`, grant `pull-requests: write`; for `push`, `contents: write` is sufficient.
- For `delivery_method: push`, check out a branch ref (not a detached HEAD) so the commit has a branch to land on.

## LLM-Generated Commit Messages

After translating strings and staging the changes, the action calls the LLM to generate meaningful commit messages. The LLM receives two pieces of context:

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
