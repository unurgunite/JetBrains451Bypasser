# JetBrains451Bypasser

![JetBrains451Bypasser stats](https://repobeats.axiom.co/api/embed/dd3831e387cbda882cc55ea449dc4b0cad6bc69d.svg "Repobeats analytics image")

---
This repository contains scripts to bypass 451 error in JetBrains

* [JetBrains451Bypasser](#jetbrains451bypasser)
    * [Usage](#usage)
        * [Tampermonkey](#tampermonkey)
        * [UNIX utility](#unix-utility)
    * [TODO](#todo)
    * [License](#license)

## Usage

### Tampermonkey

1. Install [Tampermonkey](https://tampermonkey.net/) extension;
2. In your browser settings (`chrome://extensions`, for example) turn on developer mode;
3. Click [here][1] to install script;
4. After the installation, navigate to the download page of any plugin or IDE under the `https://jetbrains.com` domain,
   and you will see successful downloading process.

If any questions, please [open an issue](https://github.com/unurgunite/JetBrains451Bypasser/issues) or navigate to
TamperMonkey FAQ page.

### UNIX utility

1. Install Ruby 3.0 or newer;
2. Clone this repository;
3. Run `./unix/jb_updater --help` to see available options;
4. For additional information, navigate
   to [README.md](https://github.com/unurgunite/JetBrains451Bypasser/blob/master/unix/README.md).

## TODO

| Script            | Completed                             |
|-------------------|---------------------------------------|
| Tampermonkey      | :white_check_mark:                    |
| macOS utility     | :white_check_mark:                    |
| Windows PS script | In progress :arrows_counterclockwise: |
| Linux             | In progress :arrows_counterclockwise: |

## License

This repository is distributed under
the [MIT License](https://github.com/unurgunite/JetBrains451Bypasser/blob/main/LICENSE.txt)

[1]: https://github.com/unurgunite/JetBrains451Bypasser/raw/master/jetbrains451bypasser.user.js
