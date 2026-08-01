# Froozeify's GH Version Updater (gVu)

**Latest version:** `v1.0.6`

A GitHub Action that updates the version field in your project's config files whenever a release is published.

Supports `package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`, `pubspec.yaml`, and any custom file format via
regex rules.

---

## Features

- **Auto-detection**
- **Explicit file list**: pin exactly which files to update
- **Custom regex rules**: extend support to any file format without changing the action
- **Built-in commit**: optionally pushes the version bump back to your branch (enabled by default) or use any action to
  commit, like `stefanzweifel/git-auto-commit-action`
- **Configurable commit author**

---

## Quick start

```yaml
on:
  release:
    types: [ published ]

permissions:
  contents: write # Require for the commit step

jobs:
  update-version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: froozeify/gh-version-updater@v1
        # Auto-detects package.json / composer.json / etc. and commits the change.
```

---

## Inputs

| Input                 | Required | Default                                                     | Description                                                                                                                                 |
|-----------------------|----------|-------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `version`             | no       | `${{ github.event.release.tag_name \|\| github.ref_name }}` | Version string. A leading `v` is stripped automatically (`v1.2.3` → `1.2.3`).                                                               |
| `files`               | no       | `auto`                                                      | `auto` to detect known config files, `none` to skip built-in updates and rely solely on `custom-rules`, or a comma-separated list of paths. |
| `custom-rules`        | no       | `""`                                                        | Extra update rules for unsupported file formats (see below).                                                                                |
| `commit`              | no       | `true`                                                      | Set to `false` to skip the commit step.                                                                                                     |
| `commit-message`      | no       | `ci: Bump version to {version}`                             | Commit message. `{version}` is replaced with the clean version number.                                                                      |
| `commit-branch`       | no       | `main`                                                      | Branch to push the commit to.                                                                                                               |
| `commit-method`       | no       | `api`                                                       | `api` commits via GitHub's `createCommitOnBranch` (signed, shows as Verified). `git` commits locally via `git commit`/`push` instead.       |
| `commit-author-name`  | no       | `github-actions[bot]`                                       | Git author name for the commit. Only used when `commit-method: git`.                                                                        |
| `commit-author-email` | no       | `41898282+github-actions[bot]@users.noreply.github.com`     | Git author email for the commit. Only used when `commit-method: git`.                                                                       |
| `token`               | no       | `${{ github.token }}`                                       | Token used to push the commit. Requires `contents: write`.                                                                                  |

## Outputs

| Output          | Description                                            |
|-----------------|--------------------------------------------------------|
| `version`       | Clean version number written to files (no `v` prefix). |
| `files-updated` | Space-separated list of files that were modified.      |

---

## Commit identity

Commits are authored as `github-actions[bot]` — the real, GitHub-linked bot account behind `${{ github.token }}`.  
By default (`commit-method: api`) they're also made through GitHub's `createCommitOnBranch` API, so GitHub signs them server-side and they show a green **Verified** badge; the author always matches whichever token you pass, regardless of
`commit-author-name`/`commit-author-email`.

### Committing as a GitHub App

If you want commits attributed to your own bot, need to bypass branch protection, or want the version-bump commit to *trigger* other workflows (`GITHUB_TOKEN` pushes deliberately don't, to avoid infinite loops) — register your own GitHub App, install it on the repo, and mint a token for it with [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token):

```yaml
- uses: actions/create-github-app-token@v3
  id: app-token
  with:
    app-id: ${{ vars.APP_ID }}
    private-key: ${{ secrets.APP_KEY }}

- uses: froozeify/gh-version-updater@v1
  with:
    token: ${{ steps.app-token.outputs.token }}
```

With `commit-method: api` (the default) that's the whole change — the commit author follows the
token automatically.

## Auto-detected files

When `files` is set to `auto` (the default), the action updates every supported file it finds in the repository root:

| File             | Ecosystem         | Field updated     |
|------------------|-------------------|-------------------|
| `package.json`   | Node / Bun / Deno | `version: ...`    |
| `composer.json`  | PHP               | `version: ...`    |
| `pyproject.toml` | Python            | `version = "..."` |
| `Cargo.toml`     | Rust              | `version = "..."` |
| `pubspec.yaml`   | Dart / Flutter    | `version: ...`    |

---

## Explicit file list

Pin which files to update:

```yaml
- uses: froozeify/gh-version-updater@v1
  with:
    files: package.json, composer.json
```

---

## Custom rules

Add support for any file format by providing regex rules:

```yaml
- uses: froozeify/gh-version-updater@v1
  with:
    files: none
    custom-rules: |
      Chart.yaml:^version\:\s*.*$:version\: {version}
      build.gradle:version\s*=\s*"[^"]*":version = "{version}"
      version.txt:^.*$:{version}
```

**Rule format**: `file:search_regex:replacement_template`

- `file`: path to the file relative to the repository root
- `search_regex`: extended regex matching the line to replace
- `replacement_template`: replacement string; `{version}` is substituted with the clean version

One rule per line. Lines starting with `#` are treated as comments and ignored. A literal `:` inside
`search_regex` or `replacement_template` must be escaped as `\:` (as in the `Chart.yaml` example above, which
matches a YAML `version:` key) — otherwise it is misread as the field separator.

### Custom rules only

Set `files: none` when none of your version strings live in a natively-supported file
(`package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`, `pubspec.yaml`) — for example a PHP constant in a
plain `.php` file. Without `files: none`, `auto` still runs auto-detection first (and fails if it finds nothing to
update), and any other value is treated as an explicit file list.

---

## Full workflow example

```yaml
name: Release

on:
  release:
    types: [ published ]

permissions:
  contents: write

jobs:
  update-version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Update version
        id: bump
        uses: froozeify/gh-version-updater@v1
        with:
          files: package.json
          custom-rules: |
            Chart.yaml:^appVersion\:\s*"[^"]*":appVersion\: "{version}"
          commit-message: "ci: release {version}"

      - run: echo "Released ${{ steps.bump.outputs.version }}"
```
