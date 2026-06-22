# Froozeify's GH Version Updater (gVu)

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

      - uses: froozeify/update-version@v1
        # Auto-detects package.json / composer.json / etc. and commits the change.
```

---

## Inputs

| Input                 | Required | Default                                                      | Description                                                                   |
|-----------------------|----------|--------------------------------------------------------------|-------------------------------------------------------------------------------|
| `version`             | no       | `${{ github.event.release.tag_name \|\| github.ref_name }}`  | Version string. A leading `v` is stripped automatically (`v1.2.3` → `1.2.3`). |
| `files`               | no       | `auto`                                                       | `auto` to detect known config files, or a comma-separated list of paths.      |
| `custom-rules`        | no       | `""`                                                         | Extra update rules for unsupported file formats (see below).                  |
| `commit`              | no       | `true`                                                       | Set to `false` to skip the commit step.                                       |
| `commit-message`      | no       | `ci: Bump version to {version}`                              | Commit message. `{version}` is replaced with the clean version number.        |
| `commit-branch`       | no       | `main`                                                       | Branch to push the commit to.                                                 |
| `commit-author-name`  | no       | `froozeify-gh-version-updater`                               | Git author name for the commit.                                               |
| `commit-author-email` | no       | `froozeify-gh-version-updater[bot]@users.noreply.github.com` | Git author email for the commit.                                              |
| `token`               | no       | `${{ github.token }}`                                        | Token used to push the commit. Requires `contents: write`.                    |

## Outputs

| Output          | Description                                            |
|-----------------|--------------------------------------------------------|
| `version`       | Clean version number written to files (no `v` prefix). |
| `files-updated` | Space-separated list of files that were modified.      |

---

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
- uses: froozeify/update-version@v1
  with:
    files: package.json, composer.json
```

---

## Custom rules

Add support for any file format by providing regex rules:

```yaml
- uses: froozeify/update-version@v1
  with:
    custom-rules: |
      Chart.yaml:^version:\s*.*$:version: {version}
      build.gradle:version\s*=\s*"[^"]*":version = "{version}"
      version.txt:^.*$:{version}
```

**Rule format**: `file:search_regex:replacement_template`

- `file`: path to the file relative to the repository root
- `search_regex`: extended regex matching the line to replace
- `replacement_template`: replacement string; `{version}` is substituted with the clean version

One rule per line. Lines starting with `#` are treated as comments and ignored.

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
        uses: froozeify/update-version@v1
        with:
          files: package.json
          custom-rules: |
            Chart.yaml:^appVersion:\s*"[^"]*":appVersion: "{version}"
          commit-message: "ci: release {version}"

      - run: echo "Released ${{ steps.bump.outputs.version }}"
```
