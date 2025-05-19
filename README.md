# JetBrains451Bypasser

![JetBrains451Bypasser stats](https://repobeats.axiom.co/api/embed/dd3831e387cbda882cc55ea449dc4b0cad6bc69d.svg "Repobeats analytics image")

---
This repository contains scripts to bypass 451 error in JetBrains

* [JetBrains451Bypasser](#jetbrains451bypasser)
    * [Usage](#usage)
        * [Tampermonkey](#tampermonkey)
    * [TODO](#todo)
    * [License](#license)

## Usage

### Tampermonkey

1. Install [Tampermonkey](https://tampermonkey.net/) extension;
2. In your browser settings (`chrome://extensions`, for example) turn on developer mode;
3. Copy content from `tampermonkey/redirect_on_451.user.js` script and install into Tampermonkey;
4. After the installation, navigate to the download page of any plugin or IDE under the `https://jetbrains.com` domain,
   and you will see successful downloading process.

If any questions, please [open an issue](https://github.com/unurgunite/JetBrains451Bypasser/issues) or navigate to
TamperMonkey FAQ page.

## TODO

| Script                  | Completed                             |
|-------------------------|---------------------------------------|
| Tampermonkey            | :white_check_mark:                    |
| Windows PS script       | In progress :arrows_counterclockwise: |
| Linux/UNIX shell script | In progress :arrows_counterclockwise: |
| JetBrains plugin        | In progress :arrows_counterclockwise: |

## License

This repository is distributed under
the [MIT License](https://github.com/unurgunite/JetBrains451Bypasser/blob/main/LICENSE.txt)
