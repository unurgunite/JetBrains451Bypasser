# JbUpdater

A standalone **Crystal CLI** to list, update, install, and even **upgrade JetBrains IDEs themselves** — all without
launching the IDE.

* [JbUpdater](#jbupdater)
    * [Features](#features)
    * [Usage](#usage)
        * [Plugins mode](#plugins-mode)
        * [IDE upgrade mode](#ide-upgrade-mode)
        * [IDE upgrade with Homebrew Cask patch](#ide-upgrade-with-homebrew-cask-patch)
        * [All options](#all-options)
    * [Run from source](#run-from-source)
    * [Development](#development)
    * [CI/CD](#cicd)
    * [Notes](#notes)
    * [License](#license)
    * [Big‑picture next steps](#bigpicture-next-steps)

---


A standalone binary to list, update and install JetBrains IDE plugins even when the JetBrains Marketplace is blocked.

Rewritten in **Crystal** for zero dependencies and cross‑platform distribution.

---

## Features

- Lists installed plugins and marks their compatibility (✅ / ⚠️).
- Updates only incompatible or selected plugins.
- Installs new plugins by `xmlId`, pinned version, or direct CDN URL.
- Bypasses 451 HTTP errors by rewriting hosts to the JetBrains CDN.
- Upgrades entire IDEs via the JetBrains Releases API.
- Auto‑detects architecture (`arm` or `intel`) and fetches the right DMG/tarball.
- Compact progress bar while downloading.
- Zero runtime dependencies — just a single binary, no Crystal runtime needed.
- [WIP] Optional `--brew` mode patches the Homebrew Cask so `brew upgrade` just works.

---

## Usage

Grab prebuilt binaries from the latest [GitHub Release](../../releases),  
or build from source.

### Plugins mode

```shell
jb_updater \
  --plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
  --only-incompatible
```

### IDE upgrade mode

```shell
# auto‑detect architecture and download from CDN
jb_updater --product RubyMine --upgrade-ide
```

### All options

| Option                       | Description                                                                         |
|------------------------------|-------------------------------------------------------------------------------------|
| `--plugins-dir DIR`          | Path to `.../<ProductYYYY.X>/plugins` (required for plugin mode)                    |
| `--product NAME`             | IDE name (e.g. `RubyMine` or `RubyMine2025.2`)                                      |
| `--build BUILD`              | Override detected IDE build (`RM‑252.23892.415`)                                    |
| `--only IDS`                 | Comma‑separated list of plugin xmlIds to update                                     |
| `--only-incompatible`        | Update only plugins not matching current build                                      |
| `--downloads-host HOST`      | Rewrite Marketplace `/files/` host (default: `downloads.marketplace.jetbrains.com`) |
| `--pin xmlId=version`        | Force specific plugin version(s)                                                    |
| `--direct xmlId=https://...` | Provide direct plugin URL(s)                                                        |
| `--install-plugin IDS`       | Install one or more plugin IDs (comma or `@version`)                                |
| `--upgrade-ide`              | Upgrade the entire IDE via JetBrains Releases API                                   |
| `--brew`                     | Patch the local Homebrew Cask instead of direct download                            |
| `--arch arm/intel`           | Force architecture; autodetects via `uname ‑m`                                      |
| `--dry-run`                  | Show what would happen without changing files                                       |
| `--list`                     | List installed plugins with compatibility status                                    |
| `--help`                     | Show CLI help                                                                       |

---

## Run from source

```shell
git clone https://github.com/your-user/jb_updater
cd jb_updater/jb_updater
shards install
crystal build src/main.cr --release -o jb_updater
./jb_updater --help
```

## Development

Run unit tests:

```shell
crystal spec
```

Creating a static binary:

```shell
crystal build src/main.cr --release -o jb_updater
```

---

## CI/CD

Cross‑platform binaries are built automatically via **GitHub Actions**  
on tag pushes:

| OS      | Target triple              | Artifact         |
|---------|----------------------------|------------------|
| macOS   | `x86_64‑apple‑darwin`      | `jb_updater`     |
| Linux   | `x86_64‑unknown‑linux‑gnu` | `jb_updater`     |
| Windows | `x86_64‑windows‑gnu`       | `jb_updater.exe` |

Workflow: `.github/workflows/build.yml`  
→ runs tests → builds binaries → attaches them to GitHub Releases.

Create a release:

```bash
git tag -a v0.2.0 -m "Cross‑platform build"
git push origin v0.2.0
```

## Notes

- Close your JetBrains IDE before updating (to avoid locked plugin files).
- Requires system `unzip` tool — default on macOS and Linux.
- Tested on macOS (ARM and Intel); Linux/Windows binaries produced via CI.

---

## License

MIT © 2025 Unurgunite

---

## Big‑picture next steps

| Area                             | Planned Improvements                           |
|----------------------------------|------------------------------------------------|
| **Windows/Linux IDE installers** | auto‑replace `.exe` and `.tar.gz` paths        |
| **Config profiles**              | optional YAML `~/.config/jb_updater.yml`       |
| **Enhanced progress bar**        | multiline + spinner for multi‑file downloads   |
| **Plugin rollback**              | automatic restore from `*.bak.<timestamp>`     |
| **Release automation**           | publish checksums & brew formula automatically |
