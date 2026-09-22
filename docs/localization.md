# Localization

How the app chooses a language, where each layer's strings live, and the exact
steps for shipping another language. English is the source language; Simplified
Chinese (`zh-Hans`) is the first translation. The user-facing behaviour is in
[Control panel → Language](features/control-panel.md#language).

## Which language the app shows

`AppLanguageStore` (`App/Services/Localization/AppLanguage.swift`) holds one
preference under `WallpaperMachine.appLanguage`: `system`, or the tag of a
shipped language. The effective language is

1. the saved tag, when the user chose one in **Settings → General → Language**;
2. otherwise the best match of the user's macOS language list against
   `AppLanguage.supported`, using `Bundle.preferredLocalizations(from:forPreferences:)`
   so the rules are the ones macOS applies to the bundle (`zh-CN`, `zh`,
   `zh-Hans-TW` → `zh-Hans`; `zh-TW`, `zh-Hant`, `en-GB`, `fr` → English).

The macOS list is read from the global defaults domain, not from
`Locale.preferredLanguages`, because the store also writes the user's choice into
the app-domain `AppleLanguages` override (and removes it on **System**). That
override is what makes `String(localized:)` — menus, alerts, notifications —
follow the choice on the next launch; the panel does not need it.

## Layers

| Layer | Strings | Mechanism |
| --- | --- | --- |
| Native (menus, dialogs, errors, Info.plist) | `App/Resources/Localizable.xcstrings`, `App/Resources/InfoPlist.xcstrings` | `String(localized:)`; the bundle resolves at launch from the `AppleLanguages` override above |
| Lock-screen extension (`Extension/`) | `Extension/Localizable.xcstrings` | `String(localized:)` against the extension's own bundle, which follows the macOS language list; literals reach it through `WallpaperRuntime.failure(_:)`, and text that is already final (the renderer's own errors) goes through `failure(detail:)` |
| Web panel (`WebUI/`) | `WebUI/locales/<tag>.js`, one ES module per language, registered in `WebUI/i18n.js` | `t(source, params)` for JavaScript, `data-i18n` / `data-i18n-label` for static markup; `applyStaticText()` refreshes the latter |
| Language picker | `AppLanguage.supported` | Each language is listed under its own name, untranslated, so it can be found from any interface language |

Keys are the English source strings on both sides; a key without a translation
renders as English. `i18n.js` resolves a tag by exact match first, then by
maximized language + script (`Intl.Locale.maximize()`), never across scripts, so
the panel and `AppLanguageStore` agree.

Swift injects `window.__appLanguage` at document start so the first paint is
already localized, and repeats the effective tag in every snapshot as
`state.language.effective`. `panel.js` calls `setLanguage()` from the snapshot;
because every string is translated where it is drawn, a change re-renders the
page in place without a reload. The `languageSetting` action validates the
value against the registry and refreshes the user script so a later reload or
WebContent recovery starts in the same language.

What is never translated: action identifiers, option values, paths, tags sent
to Steam, wallpaper titles, descriptions, creator names, custom property labels
and upstream diagnostic text. Two labels are ours rather than the author's and
are translated: the Wallpaper Engine editor's own token for the scheme colour it
adds to every scene, and the **Unnamed option** stand-in for a control whose
label was pure decoration.

## Keeping the native catalogs in sync

Command-line builds never update either `Localizable.xcstrings`, and nothing fails when
they drift: a `String(localized:)` whose key is missing renders English, and a
key no code uses stays in the catalog forever. Pass user-facing text as a
literal to `String(localized:)`, or through a `String.LocalizationValue`
parameter (as `AppDelegate.menuItem` does), so the compiler can see it; a
runtime `NSLocalizedString(variable, …)` is invisible to extraction.

To compare the catalogs with what the code actually uses, build once with
extraction on and diff the keys in the resulting `*.stringsdata` files
(`tables → Localizable → key`) against the catalog of the same target:
`WallpaperMachine.build` for `App/Resources/Localizable.xcstrings`,
`WallpaperMachineExtension.build` for `Extension/Localizable.xcstrings`.

```sh
xcodebuild -project WallpaperMachine.xcodeproj -scheme WallpaperMachine \
  -configuration Debug -derivedDataPath build SWIFT_EMIT_LOC_STRINGS=YES build
find build/Build/Intermediates.noindex/WallpaperMachine.build/Debug \
  -path '*WallpaperMachine*.build/Objects-normal/*' -name '*.stringsdata'
```

Hosted unit tests run in the app's preferences domain, so they see the
developer's own language choice. A test that checks a localized message
compares it with `String(localized:)`, never with the English text.

Add a translated entry for every missing key and delete the keys nothing
extracts. The catalog mixes Xcode's expanded layout with one-line entries, so
edit it as text rather than re-serialising the JSON.

## Adding a language

Use the BCP 47 tag Xcode uses for the locale (`zh-Hant`, `ja`, `de`, `pt-BR`…).
Every step is checked by `scripts/tests/test_panel_localization.py`, which runs
first in `python3 scripts/test.py` and fails until the three registries agree
and the catalogs are complete.

1. **Native catalogs.** In Xcode, open `App/Resources/Localizable.xcstrings`,
   `App/Resources/InfoPlist.xcstrings` and `Extension/Localizable.xcstrings`,
   add the language and translate every
   key; each unit must end in the `translated` state. Run
   `xcodegen generate` afterwards if you edited `project.yml`; the catalogs
   themselves need no project change.
2. **Panel catalog.** Copy `WebUI/locales/zh-Hans.js` to
   `WebUI/locales/<tag>.js` and translate every value. Keep the keys and every
   `{placeholder}` exactly; single-quoted strings, two-space indentation, one
   entry per line. A catalog must contain the same keys as every other catalog.
3. **Panel registry.** In `WebUI/i18n.js`, add
   `import <binding> from './locales/<tag>.js';` and `'<tag>': <binding>,` to
   `catalogs`.
4. **Native registry.** Append `AppLanguage(tag: "<tag>", name: "<own name>")`
   to `AppLanguage.supported`. The served-file allowlist in `WebPanelAssets`
   and the Settings picker derive from this list; nothing else needs a change.
5. **Verify.** `python3 scripts/test.py`. The Python check confirms the
   registries, key parity and placeholders; the hosted tests load the panel in
   each language offscreen, switch it live through `languageSetting`, and
   confirm the picker offers every shipped language.
6. **Document.** Add the language to
   [Control panel → Language](features/control-panel.md#language) and record the
   run in the [verification log](testing/verification-log.md).

Adding or changing a string in the app means adding it to every catalog in the
same change; the Python check fails on a key present in one catalog and missing
from another. English needs no catalog: the source string is the fallback.

## Removing a language

Delete its `WebUI/locales/<tag>.js`, its `i18n.js` import and registry entry,
its `AppLanguage.supported` entry and the locale from every `.xcstrings` file. A
saved preference naming a removed language falls back to **System** on the next
launch.
