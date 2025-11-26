# JetBrains451Bypasser

![JetBrains451Bypasser stats](https://repobeats.axiom.co/api/embed/dd3831e387cbda882cc55ea449dc4b0cad6bc69d.svg "Repobeats analytics image")

---

This repository contains tools to bypass HTTP **451** errors when downloading JetBrains IDEs and plugins:

- a **Tampermonkey userscript** that rewrites blocked JetBrains download links in the browser;
- a standalone **CLI + GUI utility** (`jb_updater`) that updates plugins and IDEs via the JetBrains APIs and CDN.

---

* [JetBrains451Bypasser](#jetbrains451bypasser)
    * [Usage](#usage)
        * [Tampermonkey userscript](#tampermonkey-userscript)
        * [CLI / GUI utility (`jb_updater`)](#cli--gui-utility-jb_updater)
            * [Prebuilt binaries](#prebuilt-binaries)
            * [Basic CLI usage](#basic-cli-usage)
            * [GUI usage](#gui-usage)
    * [Status / TODO](#status--todo)
    * [License](#license)

## Usage

### Tampermonkey userscript

1. Install [Tampermonkey](https://tampermonkey.net/) in your browser.
2. In your browser’s extensions page (`chrome://extensions`, `edge://extensions`, etc.), enable **Developer mode**.
3. Click [this link][1] to install the userscript.
4. After installation, navigate to any JetBrains plugin or IDE download page under the `https://jetbrains.com` domain.  
   The script will rewrite blocked URLs so the download starts normally.

If you have any questions or issues, please [open an issue](https://github.com/unurgunite/JetBrains451Bypasser/issues)
or check the Tampermonkey FAQ.

---

### CLI / GUI utility (`jb_updater`)

The `jb_updater` subdirectory contains a standalone utility written in **Crystal**. It can:

- list and update plugins in JetBrains IDEs;
- install new plugins by ID;
- upgrade whole IDEs (fetching DMGs / tarballs from JetBrains Releases API);
- work through JetBrains CDN mirrors to bypass 451 errors;
- and it ships with a simple **GUI** built on libui (via `uing`).

#### Prebuilt binaries

Prebuilt binaries are attached to the latest [GitHub Releases](../../releases) as:

- **CLI only** archives (`jb_updater-*`),
- **GUI only** archives (`jb_updater-gui-*`),
- and **bundle** archives that contain both CLI and GUI together.

On **macOS**, there is also a `JBUpdater.app` bundle with both binaries embedded in `Contents/MacOS/`.

#### Basic CLI usage

From a shell:

```bash
jb_updater --help
```

For example, to update plugins for RubyMine:

```bash
jb_updater \
  --plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
  --only-incompatible
```

To upgrade an IDE:

```bash
jb_updater --product RubyMine --upgrade-ide
# or
jb_updater --ide-path /Applications/WebStorm.app --upgrade-ide
```

#### GUI usage

On macOS:

- Download the `jb_updater-gui-macos-*.zip` artifact.
- Unzip and drag `JBUpdater.app` into `/Applications`.
- Because the app is unsigned and not notarized, you may need to clear the quarantine flag:

  ```bash
  xattr -cr /Applications/JBUpdater.app
  open /Applications/JBUpdater.app
  ```

The GUI lets you:

- auto‑detect installed JetBrains IDEs (config/plugins directories),
- list, install and update plugins,
- run IDE upgrades,
- see progress and logs in a single window.

For detailed CLI/GUI options and development instructions, see [jb_updater/README.md](./jb_updater/README.md).

---

## Status / TODO

| Part            | Status                               |
|-----------------|--------------------------------------|
| Tampermonkey    | ✅ Stable                             |
| macOS CLI / GUI | ✅ Stable (ARM + Intel builds via CI) |
| Windows utility | ✅ Stable (binaries via CI)           |
| Linux utility   | ✅ Stable (binaries via CI)           |

---

## License

This repository is distributed under the [MIT License](./LICENSE.txt).

[1]: https://github.com/unurgunite/JetBrains451Bypasser/raw/refs/heads/master/tampermonkey/redirect_on_451.user.js
