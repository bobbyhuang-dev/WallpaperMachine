# Building WallpaperMachine

Authoritative build document. Everything here is driven by `scripts/build.py` and
`scripts/package.py`; the Xcode project itself is generated from
[`project.yml`](../project.yml) and must never be edited by hand.

## Prerequisites

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon only. `project.yml` sets `ARCHS: arm64`, and release disk images are named `-arm64`. |
| macOS | 26 or later. `project.yml` pins `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` to `26.0`; `scripts/build.py` passes the same value to the renderer as `OWE_MACOSX_DEPLOYMENT_TARGET`. |
| Xcode | A full Xcode selected with `xcode-select`. The build reads `xcode-select -p` for the toolchain and `xcrun --sdk macosx --show-sdk-path` for the SDK. Command Line Tools alone are not enough. |
| Homebrew | Provides every renderer dependency; `brew --prefix` is queried at build time. |
| XcodeGen | `xcodegen` must be on `PATH`. The build regenerates the project on every run. |
| Python | System `python3` runs all of `scripts/`. |
| Rust | `cargo` must be on `PATH` for the renderer stage. |

Homebrew packages the renderer links against, exactly as listed in
`build_environment()` in `scripts/build.py`:

```sh
brew install quickjs-ng glslang freetype lz4 vulkan-loader \
  vulkan-headers molten-vk eigen nlohmann-json argparse shaderc spirv-tools glm
python3 scripts/install_ffmpeg.py
```

Plus the build tooling those packages are compiled and consumed with:

```sh
brew install rust cmake ninja pkg-config xcodegen
```

Steam Workshop downloads additionally need `steamcmd`, which is a runtime
dependency of the app, not of the build. See
[features/workshop-downloads.md](features/workshop-downloads.md).

FFmpeg is not Homebrew's `ffmpeg` formula but the repository's own
`Formula/mwe-ffmpeg.rb`: the same FFmpeg release configured as an
LGPL-2.1-or-later library set (`--disable-gpl --disable-version3
--disable-nonfree --disable-autodetect`, native decoders and encoders plus the
VideoToolbox/AudioToolbox encoders, no network or device support), because
Homebrew's build is GPLv3 and links OpenSSL, neither of which the GPL-2.0-only
application may bundle ([../LICENSING.md](../LICENSING.md)).
`scripts/install_ffmpeg.py` publishes the formula into a local git-less tap
(`WallpaperMachine/local`), installs it, and reinstalls it when the formula
file or the installed receipt differs from it; `--check` only reports.
`scripts/package.py` refuses to bundle FFmpeg libraries that are not an LGPL
build (see [Packaging and installing](#packaging-and-installing)).

`mwe-ffmpeg` is keg-only and reached through `pkg-config`, but Homebrew links
whichever FFmpeg formula is not keg-only into the shared `/opt/homebrew/include`
— and several other dependencies put that prefix on the include path. Different
majors' `AVFrame` and `AVCodecContext` differ by removed members, so compiling
against one and linking the other is accepted by the compiler and then reads
frame metadata at the wrong offsets at runtime. The renderer's CMake therefore
pins the resolved FFmpeg prefix ahead of every other include directory
(`wescene_prefer_ffmpeg_headers`), and the decode and probe entry points refuse
to run when the loaded libav* majors are not the compiled ones. If you see that
refusal, an include path is reaching a second FFmpeg before the one
`pkg-config` chose.

## The build environment

`scripts/build.py` does not rely on your shell environment for the renderer. It
copies the current environment and overrides the variables below, so the same
command produces the same build from a terminal, an editor, or CI.

| Variable | Value | Why |
|---|---|---|
| `PATH` | `$(brew --prefix)/bin` prepended | Finds Homebrew `cmake`, `ninja`, `glslangValidator` and friends ahead of anything else. |
| `CMAKE_PREFIX_PATH` | `;`-joined `opt/<package>` roots plus the Homebrew prefix | CMake resolves each dependency from its own keg, including keg-only ones like `mwe-ffmpeg`, instead of guessing. |
| `PKG_CONFIG_PATH` | `:`-joined `opt/<package>/lib/pkgconfig` | `pkg-config` consumers (FFmpeg, freetype, lz4) find the matching `.pc` files. |
| `OWE_NIX_LIBRARY_PATH` | `:`-joined `opt/<package>/lib` plus `<prefix>/lib` | The vendored scene engine's build scripts use this to locate native libraries to link. |
| `LIBCLANG_PATH` | `$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib` | Rust `bindgen`/`uniffi` need `libclang` from the selected Xcode toolchain. |
| `SDKROOT` | `xcrun --sdk macosx --show-sdk-path` | Pins C/C++/Rust compilation to the selected macOS SDK. |
| `CC` / `CXX` | `/usr/bin/clang`, `/usr/bin/clang++` | Apple Clang, not a Homebrew LLVM that happens to be first on `PATH`. |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` | Set for `xcodegen` and `xcodebuild`. Deliberately **not** in cargo's environment: cargo builds proc-macro crates for the host and dlopens them in the running compiler, and a pinned host dylib is rejected at load with `mis-aligned LINKEDIT`, which the compiler reports as `can't find crate for <macro>`. |
| `OWE_MACOSX_DEPLOYMENT_TARGET` | `26.0` | The same value under a name cargo ignores. The renderer crate's build script passes it as `CMAKE_OSX_DEPLOYMENT_TARGET`, so the C++ engine keeps the minimum the app links against. |
| `GIT_SHORT_COMMIT` | `git rev-parse --short HEAD` in the repository root | Stamps the build with the revision it was built from; Settings shows it as `Git revision`. The renderer build runs with `upstream/renderer` as its working directory, so HEAD is resolved against the repository root explicitly. |

## Stages and outputs

```sh
python3 scripts/build.py                          # Debug, everything
python3 scripts/build.py --configuration Release  # Release, everything
python3 scripts/build.py --swift-only             # skip the renderer
python3 scripts/build.py --renderer-only          # renderer + bindings only
```

`--configuration` accepts `Debug` (default) or `Release`.

1. **Renderer** — `cargo build --workspace --release` in `upstream/renderer`.
   The Rust crates and the C++ scene engine are always built in release mode,
   independently of `--configuration`. Output lands in
   `upstream/renderer/target/release`, including the static library
   `libwallpaper_bridge.a` the app links as `-lwallpaper_bridge`.
2. **Swift bindings** — `upstream/renderer/target/release/uniffi-bindgen generate
   --library …/libwallpaper_bridge.a --language swift --no-format --out-dir
   App/Bridge/Generated`. This writes `WallpaperBridge.swift` plus the FFI header
   and module map. `App/Bridge/Generated` is build output: never edit it, and
   regenerate it whenever the bridge crate's interface changes.
3. **Project generation** — `xcodegen generate` rewrites
   `WallpaperMachine.xcodeproj` from `project.yml`.
4. **Xcode build** — `xcodebuild -project WallpaperMachine.xcodeproj -scheme
   WallpaperMachine -configuration <cfg> -derivedDataPath build build`. The app
   target embeds the `WallpaperMachineExtension` ExtensionKit extension.
   It also builds and embeds the unlinked `MediaRemoteAdapter.framework` from
   the pinned BSD-3-Clause sources under `upstream/mediaremote-adapter`, and
   includes its Perl entry point and license as app resources. Building or
   testing does not launch that helper.

Products:

| Path | Contents |
|---|---|
| `build/Build/Products/Debug/WallpaperMachine.app` | Debug app, used by `scripts/test.py` |
| `build/Build/Products/Release/WallpaperMachine.app` | Release app; this is the bundle the user runs |
| `upstream/renderer/target/release/` | Renderer static library, `uniffi-bindgen`, renderer check binaries |
| `App/Bridge/Generated/` | Generated uniffi Swift bindings |

`build/` is Git-ignored and disposable; `python3 scripts/clean.py --all` removes
it entirely.

Each stage's complete output is written to `artifacts/build/<stage>-<timestamp>.log`
(`cargo`, `bindgen`, `xcodegen`, `xcodebuild-<Configuration>`); the terminal only
shows compile errors, `The following build commands failed:` and the final
product path. Pass `--verbose` to see the raw stream as well, or open the log
named in the failure line.

### Choosing a mode

| Mode | Use when | Requires |
|---|---|---|
| Full (no flag) | Renderer, bridge crate, or first build of a clean checkout. | All prerequisites. |
| `--swift-only` | Only Swift, `WebUI/`, resources, or `project.yml` changed. | `upstream/renderer/target/release/libwallpaper_bridge.a` and `App/Bridge/Generated` must already exist from an earlier full build. |
| `--renderer-only` | Iterating on Rust/C++ or the uniffi interface without needing an app bundle. | Nothing further; it stops after regenerating bindings. |

`--swift-only` and `--renderer-only` together are accepted by `argparse` but
meaningless: `--swift-only` skips the renderer and `--renderer-only` then returns
before Xcode runs, so nothing is built.

## Packaging and installing

```sh
python3 scripts/package.py --configuration Release
python3 scripts/package.py --configuration Release --install
```

`scripts/package.py` takes the already-built bundle at
`build/Build/Products/<configuration>/WallpaperMachine.app`, makes it
self-contained, and wraps it in the drag-to-install disk image
`WallpaperMachine-<version>-arm64.dmg` with its `.sha256` sidecar beside the app.
It exits with `Build the application first using scripts/build.py` when that
bundle is absent.

0. **Preflight**, before anything is modified (`--check` runs only this step
   and leaves the bundle unchanged):
   - The bundle must be fresh build output. A bundle that already carries
     `Contents/Frameworks/*.dylib`, or whose app/extension binaries already
     load a non-Swift `@rpath` dependency, is refused: packaging is one-way and
     never deletes anything from an existing bundle. An incremental
     `scripts/build.py` run does not clear `Contents/Frameworks`, so the fix is
     a clean build. **`python3 scripts/clean.py --all` deletes `build/`
     entirely, including `build/Build/Products/Release/WallpaperMachine.app`,
     the locally delivered app.** Preview with `--dry-run`, keep a copy of any
     app you still need, and only then clean and rebuild; nothing cleans
     automatically.
   - Every FFmpeg library the app links (`libav*`, `libsw*`, `libpostproc`) is
     inspected at the resolved Homebrew file it would copy: the license string
     FFmpeg's configure embeds must be exactly `LGPL version 2.1 or later` and
     the embedded configure line must not contain `--enable-gpl`,
     `--enable-version3` or `--enable-nonfree`. Otherwise it exits 1 with
     `MISSING Refusing to bundle FFmpeg libraries that are not an LGPL build
     (install the project's with python3 scripts/install_ffmpeg.py; see
     LICENSING.md):` and one line per offending library.
   - The notice payload must exist: repository `LICENSE`, `LICENSING.md`,
     `upstream/renderer/LICENSE`, `upstream/provenance.json`, the
     Xcode-bundled `Resources/LICENSE` (mediaremote-adapter, BSD-3-Clause) and
     the extension's `Phosphene-LICENSE.txt`, and a `LICENSE*`/`COPYING*`/
     `COPYRIGHT*`/`NOTICE*` file in every Homebrew keg the link closure
     reaches. Otherwise `MISSING Missing license payload:` lists what is
     absent.
   - The disk image's inputs must be usable: `Packaging/dmg/background.png`, its
     `@2x` twin at exactly twice its pixel size, and the bundle's
     `Resources/AppIcon.icns`. Otherwise `Missing disk image input:` or
     `… not twice …` names the file, and since nothing has been touched yet,
     regenerating the art and rerunning is enough.
1. **Dylib relocation.** Starting from `libMoltenVK.dylib` and the app and
   extension binaries, it walks `otool -L` transitively. Every dependency under
   the Homebrew prefix is copied into `Contents/Frameworks`, given an
   `@rpath/<name>` install name, and rewritten in its dependents with
   `install_name_tool -change`. Absolute `LC_RPATH` entries pointing into the
   Homebrew prefix or the repository are deleted, and
   `@executable_path/../Frameworks` (or `@executable_path/../../../../Frameworks`
   for the embedded `.appex`) is added instead. `@rpath` dependencies are no
   longer guessed against `<prefix>/lib`.
2. **MoltenVK ICD.** A `MoltenVK_icd.json` is written into the app's `Resources`
   and into each extension's `Resources`, each pointing at the bundled
   `libMoltenVK.dylib` with the correct relative depth, so Vulkan resolves the
   portability driver inside the bundle.
3. **License payload.** The root `LICENSE` is copied in as
   `WallpaperMachine-LICENSE.txt`, `LICENSING.md` as `LICENSING.md`,
   `upstream/renderer/LICENSE` as `Renderer-LICENSE.txt`,
   `upstream/provenance.json` as `provenance.json`, each bundled keg's notices
   under `Licenses/<formula>-<version>/`, and the vendored miniaudio and
   spirv_reflect notices under `Licenses/renderer-third-party/`. `Licenses/` is
   rebuilt on every run.
4. **Ad-hoc signing.** Each bundled dylib, then each extension
   (`--preserve-metadata=entitlements`), then the app are signed with `-`, and
   the result is checked with `codesign --verify --deep --strict`. No Developer
   ID identity is used and nothing is notarized; see
   [../LICENSING.md](../LICENSING.md#signing-and-notarization).
5. **Dependency audit.** Every binary is re-scanned. A remaining Homebrew-prefixed
   load command fails with `Unbundled dependency: …`; an `@rpath` dependency with
   no matching file in `Contents/Frameworks` fails with `Missing bundled
   dependency: …` (Swift runtime libraries are exempt).
6. **Disk image.** The version is read from the bundle's
   `CFBundleShortVersionString` with `PlistBuddy`, and
   [`scripts/lib/dmg.py`](../scripts/lib/dmg.py) writes
   `WallpaperMachine-<version>-arm64.dmg`: an HFS+ volume named
   `WallpaperMachine <version>` holding the bundle (copied with `ditto`, so its
   signatures survive; its extended attributes and resource forks stay behind, so
   the File Provider attributes described under Troubleshooting never reach the
   image) and an `Applications` link, compressed with LZFSE
   (`ULFO`). The window a user sees is laid out without Finder: the script writes
   the volume's `.DS_Store` itself, record for record what dmgbuild 1.6.7 writes,
   so packaging runs headless in CI and never needs Automation permission. The
   window is 660 × 440 points without toolbar, sidebar or status bar; the app
   and Applications icons, 128 points with 13-point labels, sit at (180, 205) and
   (480, 205) over `Packaging/dmg/background.png` and its `@2x` twin, joined into
   one HiDPI TIFF; the volume icon is the app's `AppIcon.icns`. The background is
   referenced by a version 2 alias record only, because from macOS 26.2 Finder
   draws no background for a `.DS_Store` that also carries a bookmark (`pBBk`).
7. **Verification and checksum.** The image is mounted read-only and out of
   sight: the bundle in it must be `app.wallpapermachine` at the version the name
   claims and pass `codesign --verify --deep --strict`, and the `Applications`
   link and the window layout must be there. Only then is
   `WallpaperMachine-<version>-arm64.dmg.sha256` written, in the format
   `shasum -a 256 -c` reads. The in-app updater depends on the image name; see
   [release.md](release.md). The image is labelled as not cleared for
   distribution: it is for local use until [../LICENSING.md](../LICENSING.md)
   records the blockers as resolved.
8. **`--install`.** Copies the bundle to `~/Applications/WallpaperMachine.app`.
   It refuses to overwrite an existing installation: quit and remove the old copy
   first.

The background art is generated, not drawn by hand: `python3 scripts/brand.py
--dmg` renders both PNGs with CoreGraphics from `scripts/lib/dmg.py`'s window
geometry and the brand palette, and changes nothing else. Regenerate it whenever
that geometry or the palette changes. Finder draws icon labels in black on a
custom background whatever the appearance, so the art stays light.
`scripts/tests/test_dmg.py` holds the `.DS_Store` and alias writers to the bytes
ds_store 1.3.3 and mac_alias 2.2.3 produce for fixed inputs (recorded once, since
no test can run Finder), and builds an image of a small signed bundle that carries
Finder info, then opens it the way a Mac does: its layout records, the background
alias resolving to the file on the volume, the volume icon, the link, and
verification passing for its version only.

After a successful Release build, quit and reopen the app to load it.

## Runtime data locations

The app never writes into the repository. Managed wallpapers live at
`~/Library/Application Support/WallpaperMachine/Library`; imports copy files
there and leave the originals untouched. Sibling directories under
`~/Library/Application Support/WallpaperMachine/` hold scene assets
(`SceneAssets`), the private SteamCMD runtime (`SteamCMD`) and the optional saved
Steam sign-in (`SteamSession`). Setting `WALLPAPER_MACHINE_HOME` relocates the
whole tree, which is how tests stay isolated from your real library.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cargo`/CMake stops with a missing header, library or `.pc` file | One of the Homebrew packages above is not installed, so its `opt/<package>` root contributed nothing to `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` | Install the package list, then rebuild. |
| `cargo`/CMake configure fails once, immediately after the environment changed, and an unmodified retry succeeds | The renderer's CMake configure step is not robust to a changed `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` on its first run in a directory | Retry the same command once before investigating. Do not hand-set `LIBRARY_PATH=/opt/homebrew/lib` to work around it: that puts the non-keg-only FFmpeg back on the link line and reproduces the ABI mismatch above. Running `cargo` with a bare shell environment fails outright for the same reason |
| `brew: command not found` or `xcode-select` failure during startup | `build_environment()` shells out to `brew --prefix`, `xcode-select -p` and `xcrun` before any stage runs | Install Homebrew; select a full Xcode with `sudo xcode-select -s /Applications/Xcode.app`. |
| Linker reports `library 'wallpaper_bridge' not found`, or Swift cannot find the generated bridge module | `--swift-only` was used without an earlier full build, so `upstream/renderer/target/release` and `App/Bridge/Generated` are empty | Run `python3 scripts/build.py` once without `--swift-only`. |
| `xcodegen: command not found` | XcodeGen missing; both `scripts/build.py` and `scripts/test.py` regenerate the project | `brew install xcodegen`. |
| Renderer changes have no effect on the app | The run used `--swift-only` | Rebuild without the flag. |
| `Unbundled dependency:` or `Missing bundled dependency:` during packaging | A new native dependency is reachable from a binary but was not copied into `Contents/Frameworks` — usually loaded through an `@rpath` name with no Homebrew `lib/<name>` counterpart | Add the library to the Homebrew package list so the relocation walk can find it, then repackage. Never ship the bundle with the audit bypassed. |
| `Refusing to bundle FFmpeg libraries that are not an LGPL build` during packaging | The app was linked against Homebrew's GPLv3 `ffmpeg@8` (or another non-LGPL build) instead of `mwe-ffmpeg` | `python3 scripts/install_ffmpeg.py`, then a fresh `python3 scripts/build.py` so the link resolves to the project's build. Never bypass the check; see [../LICENSING.md](../LICENSING.md). |
| `Packaging requires fresh, unrelocated build output` | The bundle in `build/` was packaged before; incremental builds keep `Contents/Frameworks` and the rewritten load commands, and packaging never undoes them | Preview `python3 scripts/clean.py --all --dry-run`, copy any delivered app you still need out of `build/`, then `python3 scripts/clean.py --all` and rebuild. `--all` deletes the delivered Release app. |
| `Missing license payload:` during packaging | A repository notice file, an Xcode-bundled notice, or a keg `LICENSE*`/`COPYING*` file is absent | Restore the listed file; the payload list is in [Packaging and installing](#packaging-and-installing). |
| `An installation already exists: …` | `--install` will not replace `~/Applications/WallpaperMachine.app` | Quit and remove the installed copy, then rerun. |
| `CodeSign` fails with `resource fork, Finder information, or similar detritus not allowed in object file` | The built `.app`/`.appex` **directory** in `build/` picked up `com.apple.FinderInfo` or File Provider xattrs (`com.apple.fileprovider.fpfs#P`). It comes from the file provider syncing the checkout's parent directory, not from anything committed: source files carry only `com.apple.provenance`, which codesign accepts | `xattr -cr build/Build/Products/<configuration>` and rerun the same command. It recurs on synced checkouts; clearing the products directory is the fix, not a rebuild |
| `codesign --verify --deep --strict` fails | A dylib or the extension was modified after signing | Rerun packaging on a fresh build rather than re-signing pieces by hand. |
| `Missing disk image input:` or `… not twice …` during the preflight | The DMG background under `Packaging/dmg/` or the bundle's `AppIcon.icns` is missing, or the 1x and 2x PNGs no longer pair up | `python3 scripts/brand.py --dmg`, then rerun packaging; the preflight stopped before the bundle was touched. |
| `Could not detach …` while packaging | Something kept the volume busy past the retries (a Finder window on a leftover mount, an indexer), or a mount from an interrupted run is still attached | `hdiutil info` lists attached images; `hdiutil detach -force <device>` the leftover, then rerun packaging on a fresh build. |

## Related documents

- [testing/README.md](testing/README.md) — how to verify a build.
- [testing/renderer.md](testing/renderer.md) — headless renderer and GPU checks.
- [release.md](release.md) — versioning, CI, notes, and the published disk image.
- [repository-layout.md](repository-layout.md) — where each source tree lives.
