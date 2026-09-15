# Licensing: combining the macOS Wallpaper Engine projects

Recorded: 2026-09-14
Status: deferred; unresolved before distribution.

## Intent and current decision

Explore one macOS application combining Steam Workshop browsing/downloading with native Wallpaper Engine wallpaper rendering.

Proceed with private experimentation. Revisit licensing once the implementation demonstrates that the approach works. This deferral is not permission to publish a merged repository or distribute a combined application under incompatible licenses.

## Projects and evidence

### Workshop browser: Unayung/wallpaper-engine-mac

- Repository: https://github.com/Unayung/wallpaper-engine-mac
- License: GNU GPL version 3.
- License file: https://github.com/Unayung/wallpaper-engine-mac/blob/main/LICENSE
- Relevant functionality: integrated Workshop search, filters, and SteamCMD downloads; video/web playback and limited scene rendering.

### Renderer: bigsaltyfishes/wallpaper-engine-for-macos

- Repository: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos
- License file: GNU GPL version 2.
- License file: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/LICENSE
- Workspace package metadata explicitly declares `license = "GPL-2.0-only"`:
  https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/Cargo.toml
- Relevant functionality: native scene rendering, audio response, and partial SceneScript support.

These observations describe the upstream files checked on the recorded date. The links follow mutable branches, not pinned revisions. Before importing code, record the exact revisions and retain their license notices. This is not a complete file-by-file or dependency license audit.

## License issue

GPLv2-only and GPLv3 are incompatible for distributing a single combined derivative program. Both permit modifications, but their distribution requirements cannot simply be satisfied by labeling a merged application with both licenses.

The renderer's explicit `GPL-2.0-only` declaration matters: unlike GPLv2-or-later, it does not authorize us to choose GPLv3 for the covered code. Publishing the source, preserving attribution, or including both license texts does not by itself resolve the conflict.

Private combinations are permitted under the FSF's guidance. Publishing merged source or sharing a combined binary requires resolving the distribution issue first.

References:

- GPLv2/GPLv3 compatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- Private combinations: https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean
- Private modifications and release obligations: https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic

## Potential resolutions to revisit

### Preferred fallback: independently implement Workshop browsing

Use the bigsaltyfishes renderer project as the base and independently implement browsing/downloading from Steam's documented interfaces under GPLv2-compatible terms. Do not copy, translate, or adapt Unayung's GPLv3 implementation into this version.

This delivers the combined functionality without directly combining the two codebases. If the private prototype contains GPLv3-derived browser code, that code must be removed and independently replaced before relying on this route. Keep prototype provenance clear; do not relabel copied code as original work.

### Alternative: obtain compatible permissions

Request permission to use the relevant renderer code under GPLv3, or the relevant browser code under GPLv2-compatible terms. Permission must cover all relevant copyright holders and inherited code, not merely the current repository maintainer's own contributions. Retain written grants and audit dependency compatibility.

### Alternative: genuinely separate applications

Keep the browser and renderer as independent programs under their respective licenses, communicating through ordinary files or a simple command-line interface.

A subprocess boundary alone is not sufficient: tightly coupled components exchanging internal data structures may still constitute one combined work. Evaluate the actual architecture before relying on aggregation.

Reference: https://www.gnu.org/licenses/gpl-faq.html#MereAggregation

## Before any distribution

- Select and document a legally compatible integration route.
- Pin imported revisions and audit the actual reused files, dependencies, and assets.
- Preserve copyright, license, and warranty notices; identify modifications as required.
- Provide corresponding source and required build/install scripts under the applicable GPL terms.
- Review Steam/API terms and separate rights to Wallpaper Engine assets and Workshop content. These projects' GPL licenses do not authorize redistribution of Valve's software, proprietary Wallpaper Engine assets, or creators' wallpapers.
- Obtain qualified legal review if relying on special permissions or a disputed program-separation boundary.

Distribution review remains deferred. The implementation below avoids directly combining the GPLv3 browser with the GPLv2-only renderer, but this is not a completed dependency or distribution audit and is not legal advice.

## Implementation record

The native application is named **MacWallpaperEngine**; the project slug is `mac-wallpaper-engine`.

- Renderer source is in `upstream/renderer`, based on revision `8c19c002ff37930c68117dd591dfe3f44792e25e`.
- The Workshop browser and downloader were independently implemented for this client. No Unayung GPLv3 implementation was copied into it.
- Exact source provenance is recorded in `upstream/provenance.json`.
- Current Homebrew FFmpeg binaries include GPLv3-enabled components. The private bundle is not cleared for distribution; a GPLv2-compatible media build or appropriate permissions must be selected and audited before release.
- Valve SteamCMD is installed separately, not bundled with the application. Its copied runtime is used for authenticated downloads; the app does not distribute Workshop content or proprietary shared assets.
- Native lock-screen extension ABI research used the MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6) protocol/Codable layout as a reference. The app-specific asset publication, restoration and existing renderer integration are implemented here. Private `WallpaperExtensionKit` is not an Apple-supported public wallpaper API; this does not resolve the distribution issues above.

## Local build and use

This build targets Apple Silicon and macOS 26 or later. Xcode and Homebrew are required for building; packaged renderer libraries are included in the app for local use.

Build dependencies: `rust cmake ninja pkg-config eigen nlohmann-json glslang spirv-tools argparse quickjs-ng glm lz4 freetype ffmpeg@8 shaderc vulkan-headers vulkan-loader molten-vk xcodegen`. Steam downloads additionally require `steamcmd`.

```sh
python3 scripts/build.py --configuration Release
python3 scripts/package.py --configuration Release --install
python3 scripts/test.py
```

The installer places the app at `~/Applications/MacWallpaperEngine.app` and refuses to overwrite an existing installation. Managed wallpapers live at `~/Library/Application Support/mac-wallpaper-engine/Library`; imports leave original files untouched.

Open Library to apply the bundled Aurora Drift wallpaper immediately. Workshop supports public browsing without an API key. Downloading requires a Steam account that owns Wallpaper Engine; enter credentials only in the app's local prompts. Scene wallpapers additionally need Wallpaper Engine's shared assets. Use **Install scene assets…** in Settings or an installed scene's Workshop details, or **Locate assets…** to select an existing purchased installation. Scene compatibility is experimental; web and Windows application wallpapers are labeled unsupported.

Scene asset setup reuses the private SteamCMD login and cancellation flow, requests the Windows application with `app_update 431960 validate`, and retains only the validated `assets` tree at `~/Library/Application Support/mac-wallpaper-engine/SceneAssets`. Windows executables are never launched and are removed with the temporary installation. Steam sign-in retention follows the download form's remember-sign-in preference; submitted passwords and Guard codes are not stored. Steam must confirm installation completion before assets are published. Empty/incomplete directories are rejected without replacing existing assets; basic shader/material checks are not a guarantee of compatibility with every scene. Downloads can need several GB of temporary disk space. After setup, apply the already-downloaded wallpaper without restarting or downloading that wallpaper again.

SteamCMD password and Steam Guard prompts are read without waiting for a full terminal buffer, including prompts split across reads or without a trailing newline. Login failures are processed before credential prompts, and output is drained before process exit is handled. The five-minute inactivity timeout remains a safety limit, not a substitute for receiving login prompts.

**Keep me signed in on this Mac** is enabled by default for Workshop downloads and scene asset installation. After successful authentication, the app preserves Steam-issued cached credentials and machine-authentication files for the last account at `~/Library/Application Support/mac-wallpaper-engine/SteamSession`. The next download, including after an app restart, restores only that account's cache and pre-fills its login name. Cache directories are restricted to `0700` and files to `0600`; submitted passwords and Steam Guard codes are sent only to the private terminal, not saved by the app. Downloaded content, runtime programs, and logs are not retained in the sign-in cache. **Forget saved Steam sign-in**, or disabling the option, removes the local cache without signing out other Steam devices. Steam controls expiry, renewal, revocation, and additional security checks; indefinite authentication is not guaranteed.

Authentication state is preserved even when an already-authenticated download fails or is cancelled. Failed authentication does not replace a previously saved account. SteamCMD's invalid-cache warning may fall back to a password prompt; terminal cached-credential rejection clears the stale cache before an explicit retry. Each download still uses private temporary staging, and the child process is stopped before staging is removed.

The download form includes **Steam Guard sign-in help** (also translated into Simplified Chinese). When SteamCMD requests mobile approval, open the Steam mobile app’s shield tab for the same account and approve only the sign-in you initiated. For an authenticator or email code, enter the current code in the app’s code field and submit it. Keep the download open; it continues after verification. Never disable Steam Guard or share passwords, verification codes, or recovery codes. Valve’s [mobile-authenticator instructions](https://help.steampowered.com/en/faqs/view/6891-E071-C9D9-0134) describe the supported sign-in methods; [email-code help](https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode) covers delivery delays.

After authentication is rejected or times out, **Retry Steam sign-in** starts a new private SteamCMD session for the selected wallpaper or scene asset installation and the account name still in the form. The prior process is stopped and its private staging removed first. Supply a password or fresh code when Steam asks; rejected requests are not reused, approval is not bypassed, and retries are never automatic. If Steam reports rate limiting, wait before retrying. Workshop content-access errors are separate and do not offer an authentication retry.

If the current Valve SteamCMD package produces a damaged Breakpad framework warning, `python3 scripts/setup-steamcmd.py` prepares a private complete runtime and repairs that copied framework's resource seal with an ad-hoc signature. It does not disable system security. The app checks the framework before launching it. Complete prepared runtimes do not automatically self-update during downloads; update the official runtime and repeat setup when a newer version is needed.

Automated test results are saved as `build/E2E-*.xcresult`. Actual Steam account downloads, complex third-party scene fidelity, audio capture permission, and multiple physical displays require separate verification with the appropriate account, content, permissions, and hardware.

## Verification record

- `build/E2E-20260914-173811.xcresult`: 24 passing native tests, zero failures. Covers import safety, live Workshop queries, download cancellation cleanup, launch/reopen, settings navigation, selection persistence, apply/pause/resume/relaunch, invalid-media recovery, and Workshop navigation persistence.
- `build/E2E-Recovery-Confirmed.xcresult`: invalid-video activation and subsequent valid-wallpaper recovery passed against the real desktop UI.
- `build/verification/`: actual native UI and renderer pixel captures plus `report.json` recording exercised behavior and unverified prerequisites.
- Installed release path: `~/Applications/MacWallpaperEngine.app`. Code signature and bundled dynamic-library paths were checked locally.
- Invalid-video recovery was additionally exercised against the installed release: an actionable decoding error appeared, and Aurora Drift applied successfully afterward without restarting the app.
- `build/LoginFix.xcresult`: 20 passing native tests, zero failures, including short/split password and Guard prompts, mobile-approval transitions, authentication rejection, and errors emitted immediately before process exit.
- SteamCMD login prompt repair: the original downloader did not surface a password prompt during a 15-second local probe; the fixed downloader surfaced the real installed SteamCMD prompt in 3.33 seconds. The updated installed release displayed its password field in 3.28 seconds; `build/verification/login-password-prompt.png` captures that native dialog. The disposable session was cancelled without submitting a password; successful account authentication and an account-owned Workshop download were not claimed.
- `build/SteamGuardRetry.xcresult`: 22 passing native tests, zero failures. Includes denied mobile approval followed by a fresh password/code session and successful local fixture import; distinguishes authentication rejection from Workshop content-access denial.
- Actual native UI smoke with a disposable local SteamCMD fixture: mobile instructions appeared, simulated `FAILED (Access Denied)` exposed **Retry Steam sign-in**, the button requested fresh credentials, and a subsequent code submission imported the fixture into an isolated library. `build/verification/steam-guard-*.png` records mobile/code guidance, the retry button, and Chinese instructions in the installed release. This does not claim a real Steam account approval or a protected Workshop download.
- `build/SceneAssetsFix.xcresult`: 25 passing native tests, zero failures. Covers Windows app asset installation, authenticated terminal interaction, keeping only validated resources, incomplete-install preservation, cancellation cleanup, and existing download/import behavior. The installation-completion tests use a disposable local SteamCMD fixture, not a purchased Steam download.
- Scene asset setup was exercised in a separately identified native app with an isolated library: Settings and installed-Workshop recovery actions opened the setup sheet; Apply was disabled while assets were missing and enabled after a disposable resource fixture appeared in the same session. The real installed SteamCMD reached its password prompt from the asset-install action; the session was cancelled without a password and staging cleanup was confirmed. `build/verification/scene-assets-setup.png` and `build/verification/scene-assets-password-prompt.png` capture the native setup and real prompt. This does not claim authenticated asset acquisition or third-party scene rendering.
- `build/SceneAssetsIntegration.xcresult`: all three asset installation/preservation/cancellation regression cases passed again after the concurrent remembered-session integration. The packaged Release build was signed and its bundled-library paths verified; a separately identified copy opened the asset setup sheet and reached the real SteamCMD password prompt without submitting credentials.
- `build/RememberSteamLogin.xcresult`: 34 passing native tests, zero failures, including cross-launch cached downloads, case-insensitive account matching, account switching, expired-cache fallback and explicit retry, forgetting/opt-out, rejected-login isolation, post-authentication failure/cancellation retention, and private cache permissions. Session scenarios use disposable SteamCMD fixtures, not real account credentials. The installed SteamCMD's `help login` was separately run in an isolated runtime and confirms native cached authentication without storing the password.
- `build/RememberSteamUISmoke.xcresult`: disposable native UI smoke passed. A separately identified copy of the current app signed into a local SteamCMD fixture through password and Guard fields, imported one wallpaper, restarted, auto-filled the account, and imported a different wallpaper without submitting credentials. The fixture recorded one fresh login followed by one cached login. **Forget saved Steam sign-in** removed the cache and reset the form. Captures are in `build/verification/remember-steam-login/`; the disposable UI driver was removed afterward. Real Steam token lifetime and protected downloads remain account-dependent and unverified.
- `build/RememberSteamFinalTests.xcresult`: final 22 downloader tests passed after cleanup, including failed-account-switch preservation and rejecting credential symlinks without reading or modifying the outside file. Release compilation succeeded. Simplified Chinese remember/forget labels and remembered-account presentation were checked in the native UI.
- The remembered-session Release was packaged, signed, and installed at `~/Applications/MacWallpaperEngine.app`; the previous app is retained at `build/pre-remember-session/MacWallpaperEngine.app`. The installed bundle passed deep strict signature verification. Wallpaper/library data and the user's separately installed SteamCMD were left unchanged.

The account-dependent download/apply verification remains open. The private prototype is usable locally, but this record does not claim every Workshop scene or every hardware configuration works.
