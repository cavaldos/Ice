<div align="center">
    <img src="Ice/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width=200 height=200>
    <h1>Ice</h1>
    <p>A powerful, open-source menu bar manager for macOS, focused on stability and a smooth, distraction-free experience.</p>
</div>

![Banner](./Resources/Image/banner.png)

<div align="center">

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/cavaldos/Ice/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2014%2B-fa4e49?style=flat-square)
[![Sponsor](https://img.shields.io/badge/Sponsor%20%E2%9D%A4%EF%B8%8F-8A2BE2?style=flat-square)](https://ko-fi.com/calvados)
[![PayPal](https://img.shields.io/badge/PayPal-00457C?style=flat-square&logo=paypal&logoColor=white)](https://www.paypal.com/paypalme/nnkhanh29)
[![Website](https://img.shields.io/badge/Website-015FBA?style=flat-square)](https://icemenubar.app)
[![License](https://img.shields.io/github/license/cavaldos/Ice?style=flat-square)](LICENSE)

<br>

<a href="https://ko-fi.com/calvados" target="_blank">
    <img src="https://storage.ko-fi.com/cdn/kofi5.png?v=6" alt="Support me on Ko-fi" style="height: 60px !important;width: 217px !important;">
</a>

</div>

> [!NOTE]
> Ice is in active development. Grab the latest build from the [releases page](https://github.com/cavaldos/Ice/releases/latest).

## Install

Download `Ice.zip` from the [latest release](https://github.com/cavaldos/Ice/releases/latest) and move the unzipped app into `/Applications`.

Coming from upstream Ice installed via Homebrew? Run `brew uninstall --cask jordanbaird-ice` first, otherwise a later `brew upgrade` replaces this build with the upstream one. Your settings are kept — both builds use the same bundle ID.

For local development, see [script/README.md](script/README.md).

## Permissions

Ice needs two grants in **System Settings > Privacy & Security**:

* **Accessibility** — hiding and moving menu bar items
* **Screen Recording** — menu bar item images and the Ice Bar

> [!IMPORTANT]
> **After every update you will need to grant these again.**
>
> Releases are ad-hoc signed, so the app's designated requirement is a pinned
> `cdhash` instead of a stable Developer ID. Each build has a different hash, so
> the requirement macOS recorded when you first granted access no longer matches
> the new binary. The symptom is confusing: System Settings still shows the
> toggle **on** while Ice behaves as though it were denied.
>
> The stale entries have to be cleared before the grant can be re-recorded:
>
> ```bash
> ./script/fix-permissions.sh
> ```
>
> Or by hand: quit Ice, run `tccutil reset Accessibility com.jordanbaird.Ice`
> and `tccutil reset ScreenCapture com.jordanbaird.Ice`, relaunch, re-grant.

Because the builds are ad-hoc signed rather than notarized, Gatekeeper may also refuse the first launch. Right-click the app and choose **Open**, or clear the quarantine flag with `xattr -d com.apple.quarantine /Applications/Ice.app`.

## Features

**Menu bar management**
Hide items individually or all at once, with an optional "always-hidden" section. Reveal hidden items by hovering, clicking an empty area, or scrolling — with auto-rehide, drag-and-drop reordering, and a separate Ice Bar for notched MacBooks.

**Appearance**
Custom menu bar tint (solid or gradient), shadow, border, and shape (rounded and/or split).

**Hotkeys**
Toggle sections, the Ice Bar, divider icons, and application menus from the keyboard.

**Other**
Launch at login, automatic updates.

> Requires macOS 14 or later — ready for macOS 27. If you need a similar tool for macOS 13 or earlier, check out [Ice 0.11.x](https://github.com/jordanbaird/Ice/releases).

## Project Philosophy

Ice is built with a focus on **stability, performance, and a smooth user experience**.

Rather than adding features for the sake of having more features, the project prioritizes a small, focused, and reliable feature set. Every feature should have a clear purpose, integrate naturally with macOS, and maintain Ice's simplicity and performance.

Our goal is to make Ice feel fast, predictable, and unobtrusive — a tool that quietly does its job without unnecessary complexity. Ice will always remain **open-source** and **free**.

## Gallery

**Demo Always Hidden**

![Demo ](Resources/vid/demo-ah.gif)

**Demo**

![Demo ](Resources/vid/demo.gif)

**Fullscreen settings**

![Fullscreen settings](Resources/Image/fullscreen.png)


| Ice Bar                                                                                     | Drag & drop layout                                                                                  |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| ![Ice Bar](https://github.com/user-attachments/assets/f1429589-6186-4e1b-8aef-592219d49b9b) | ![Menu Bar Layout](./Resources/Image/MenuBarLayout.png) |

| Appearance settings                                                                                     | Item spacing                                                                                              |
| ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| ![Menu Bar Appearance](./Resources/Image/MenuBarAppearance.png) | ![Menu Bar Item Spacing](https://github.com/user-attachments/assets/b196aa7e-184a-4d4c-b040-502f4aae40a6) |

## Contributing

Contributions are welcome! Please read the [contribution guidelines](./Resources/document/CONTRIBUTING.md) before submitting a pull request.

## Support

<a href="https://ko-fi.com/calvados" target="_blank">
    <img src="https://storage.ko-fi.com/cdn/kofi5.png?v=6" alt="Support me on Ko-fi" style="height: 36px !important;width: 130px !important;">
</a>

<a href="https://www.paypal.com/paypalme/nnkhanh29" target="_blank">
    <img src="https://www.paypalobjects.com/webstatic/en_US/i/buttons/PP_logo_h_200x51.png" alt="Donate with PayPal" style="height: 36px !important;">
</a>

## Acknowledgments

A fork of [Ice](https://github.com/jordanbaird/Ice) by [Jordan Baird](https://github.com/jordanbaird) — huge thanks for the original work this project builds on.

## License

[GPL-3.0](LICENSE) — Ice is and will always remain open-source and free.

## Star History

<a href="https://star-history.com/#calvados/Ice&Date">
    <img src="https://api.star-history.com/svg?repos=calvados/Ice&type=Date" alt="Star History Chart" width="500">
</a>
