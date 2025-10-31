A tiny Crystal CLI to list and update JetBrains IDE plugins on macOS without going through the IDE. It scans your
plugins directory, detects your IDE build, resolves the latest compatible plugin versions via the Marketplace,
downloads them (optionally via the downloads CDN), and installs them safely with backups.

* [JbUpdater](#jbupdater)
    * [Features](#features)
    * [Usage](#usage)
    * [Run from source](#run-from-source)
    * [Development](#development)
    * [Notes](#notes)
    * [License](#license)
    * [Developer ergonomics](#developer-ergonomics)
    * [Big‑picture next steps](#bigpicture-next-steps)

---

# JbUpdater

A standalone binary to list, update and install JetBrains IDE plugins even when the JetBrains Marketplace is blocked.

Rewritten in **Crystal** for zero dependencies and cross‑platform distribution.

---

## Features

- Lists installed plugins and marks compatibility (✅ or ⚠️).
- Updates only incompatible plugins (`--only-incompatible`).
- Installs new plugins by xmlId or pinned versions.
- Resolves Marketplace URLs directly or via CDN fallback.
- Works on macOS; Linux/Windows under development.
- Produces a single lightweight binary — no dependencies required.

---

## Usage

```shell
jb_updater --plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" [options]
```

| Option                       | Description                                                              |
|------------------------------|--------------------------------------------------------------------------|
| `--plugins-dir DIR`          | Path to `<ProductYYYY.X>/plugins` (required)                             |
| `--build BUILD`              | Specify explicit IDE build(e.g.`RM‑252.23892.415`)                       |
| `--only IDS`                 | Comma‑separated xmlIds to update                                         |
| `--only-incompatible`        | Update only incompatible plugins                                         |
| `--downloads-host HOST`      | Rewrite final `/files/` host (e.g.`downloads.marketplace.jetbrains.com`) |
| `--pin xmlId=version`        | Force specific version(s)                                                |
| `--direct xmlId=https://...` | Provide direct URL(s)                                                    |
| `--install-plugin IDS`       | Install plugin(s) by xmlIdorxmlId@version                                |
| `--dry-run`                  | Show plan without modifying anything                                     |
| `--list`                     | List installed plugins and compatibility                                 |
| `--help`                     | Show help text                                                           |

---

## Run from source

```shell
shards build
./bin/jb_updater --help
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

## Notes

- Close the IDE before updating (to avoid file locks).
- macOS tested; Linux/Windows planned.
- Built‑in "unzip" dependency required on PATH.

---

## License

MIT © 2025 Unurgunite

---

## Developer ergonomics

- Add `.editorconfig` for indentation and UTF‑8.
- Run `crystal tool format` to autoformat code.
- Add `crystal spec --order random` to CI to catch inter‑test coupling.
- In `shard.yml`, add:
  ```yaml
  development_dependencies:
    colorize:
      github: crystal-lang/colorize
  ```

---

## Big‑picture next steps

| Area                      | Opportunity                                               |
|---------------------------|-----------------------------------------------------------|
| **Windows/Linux support** | adapt `detect_build_info_*` paths and binary names        |
| **Progress bar**          | implement simple text progress via `IO.copy` callback     |
| **Config file**           | optional YAML‑based defaults (`~/.config/jb_updater.yml`) |
| **Releases**              | `crystal build --release` per‑platform → GitHub releases  |
