# Building MacWallpaperEngine

Authoritative build document. Everything here is driven by `scripts/build.py` and
`scripts/package.py`; the Xcode project itself is generated from
[`project.yml`](../project.yml) and must never be edited by hand.

## Prerequisites

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon only. `project.yml` sets `ARCHS: arm64`, and release archives are named `-arm64`. |
| macOS | 26 or later. `project.yml` pins `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` to `26.0`; `scripts/build.py` exports the same value for the renderer. |
| Xcode | A full Xcode selected with `xcode-select`. The build reads `xcode-select -p` for the toolchain and `xcrun --sdk macosx --show-sdk-path` for the SDK. Command Line Tools alone are not enough. |
| Homebrew | Provides every renderer dependency; `brew --prefix` is queried at build time. |
| XcodeGen | `xcodegen` must be on `PATH`. The build regenerates the project on every run. |
| Python | System `python3` runs all of `scripts/`. |
| Rust | `cargo` must be on `PATH` for the renderer stage. |

Homebrew packages the renderer links against, exactly as listed in
`build_environment()` in `scripts/build.py`:

```sh
brew install quickjs-ng glslang ffmpeg@8 freetype lz4 vulkan-loader \
  vulkan-headers molten-vk eigen nlohmann-json argparse shaderc spirv-tools glm
```

Plus the build tooling those packages are compiled and consumed with:

```sh
brew install rust cmake ninja pkg-config xcodegen
```

Steam Workshop downloads additionally need `steamcmd`, which is a runtime
dependency of the app, not of the build. See
[features/workshop-downloads.md](features/workshop-downloads.md).

Licensing constraints on the resulting bundle (notably the Homebrew FFmpeg
build) are recorded in [../LICENSING.md](../LICENSING.md) and are not repeated
here.

`ffmpeg@8` is keg-only and reached through `pkg-config`, but Homebrew links
whichever FFmpeg formula is not keg-only into the shared `/opt/homebrew/include`
— and several other dependencies put that prefix on the include path. The two
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
| `CMAKE_PREFIX_PATH` | `;`-joined `opt/<package>` roots plus the Homebrew prefix | CMake resolves each dependency from its own keg, including keg-only ones like `ffmpeg@8`, instead of guessing. |
| `PKG_CONFIG_PATH` | `:`-joined `opt/<package>/lib/pkgconfig` | `pkg-config` consumers (FFmpeg, freetype, lz4) find the matching `.pc` files. |
| `OWE_NIX_LIBRARY_PATH` | `:`-joined `opt/<package>/lib` plus `<prefix>/lib` | The vendored scene engine's build scripts use this to locate native libraries to link. |
| `LIBCLANG_PATH` | `$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib` | Rust `bindgen`/`uniffi` need `libclang` from the selected Xcode toolchain. |
| `SDKROOT` | `xcrun --sdk macosx --show-sdk-path` | Pins C/C++/Rust compilation to the selected macOS SDK. |
| `CC` / `CXX` | `/usr/bin/clang`, `/usr/bin/clang++` | Apple Clang, not a Homebrew LLVM that happens to be first on `PATH`. |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` | Keeps renderer objects compatible with the Xcode targets. |
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
   `mac-wallpaper-engine.xcodeproj` from `project.yml`.
4. **Xcode build** — `xcodebuild -project mac-wallpaper-engine.xcodeproj -scheme
   MacWallpaperEngine -configuration <cfg> -derivedDataPath build build`. The app
   target embeds the `MacWallpaperExtension` ExtensionKit extension.
   It also builds and embeds the unlinked `MediaRemoteAdapter.framework` from
   the pinned BSD-3-Clause sources under `upstream/mediaremote-adapter`, and
   includes its Perl entry point and license as app resources. Building or
   testing does not launch that helper.

Products:

| Path | Contents |
|---|---|
| `build/Build/Products/Debug/MacWallpaperEngine.app` | Debug app, used by `scripts/test.py` |
| `build/Build/Products/Release/MacWallpaperEngine.app` | Release app; this is the bundle the user runs |
| `upstream/renderer/target/release/` | Renderer static library, `uniffi-bindgen`, renderer check binaries |
| `App/Bridge/Generated/` | Generated uniffi Swift bindings |

`build/` is Git-ignored and disposable; `python3 scripts/clean.py --all` removes
it entirely.

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
`build/Build/Products/<configuration>/MacWallpaperEngine.app` and makes it
self-contained. It exits with `Build the application first using
scripts/build.py` when that bundle is absent.

1. **Dylib relocation.** Starting from `libMoltenVK.dylib` and the app and
   extension binaries, it walks `otool -L` transitively. Every dependency under
   the Homebrew prefix is copied into `Contents/Frameworks`, given an
   `@rpath/<name>` install name, and rewritten in its dependents with
   `install_name_tool -change`. Absolute `LC_RPATH` entries pointing into the
   Homebrew prefix or the repository are deleted, and
   `@executable_path/../Frameworks` (or `@executable_path/../../../../Frameworks`
   for the embedded `.appex`) is added instead.
2. **MoltenVK ICD.** A `MoltenVK_icd.json` is written into the app's `Resources`
   and into each extension's `Resources`, each pointing at the bundled
   `libMoltenVK.dylib` with the correct relative depth, so Vulkan resolves the
   portability driver inside the bundle.
3. **License payload.** `upstream/renderer/LICENSE` is copied in as
   `Renderer-LICENSE.txt` and `upstream/provenance.json` as `provenance.json`.
4. **Ad-hoc signing.** Each bundled dylib, then each extension
   (`--preserve-metadata=entitlements`), then the app are signed with `-`, and
   the result is checked with `codesign --verify --deep --strict`.
5. **Dependency audit.** Every binary is re-scanned. A remaining Homebrew-prefixed
   load command fails with `Unbundled dependency: …`; an `@rpath` dependency with
   no matching file in `Contents/Frameworks` fails with `Missing bundled
   dependency: …` (Swift runtime libraries are exempt).
6. **Archive.** The version is read from the bundle's
   `CFBundleShortVersionString` with `PlistBuddy`, and `ditto -c -k --keepParent`
   writes `MacWallpaperEngine-<version>-arm64.zip` beside the app. The in-app
   updater depends on that name; see [release.md](release.md).
7. **`--install`.** Copies the bundle to `~/Applications/MacWallpaperEngine.app`.
   It refuses to overwrite an existing installation: quit and remove the old copy
   first.

After a successful Release build, quit and reopen the app to load it.

## Runtime data locations

The app never writes into the repository. Managed wallpapers live at
`~/Library/Application Support/mac-wallpaper-engine/Library`; imports copy files
there and leave the originals untouched. Sibling directories under
`~/Library/Application Support/mac-wallpaper-engine/` hold scene assets
(`SceneAssets`), the private SteamCMD runtime (`SteamCMD`) and the optional saved
Steam sign-in (`SteamSession`). Setting `MAC_WALLPAPER_ENGINE_HOME` relocates the
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
| `An installation already exists: …` | `--install` will not replace `~/Applications/MacWallpaperEngine.app` | Quit and remove the installed copy, then rerun. |
| `CodeSign` fails with `resource fork, Finder information, or similar detritus not allowed in object file` | The built `.app`/`.appex` **directory** in `build/` picked up `com.apple.FinderInfo` or File Provider xattrs (`com.apple.fileprovider.fpfs#P`). It comes from the file provider syncing the checkout's parent directory, not from anything committed: source files carry only `com.apple.provenance`, which codesign accepts | `xattr -cr build/Build/Products/<configuration>` and rerun the same command. It recurs on synced checkouts; clearing the products directory is the fix, not a rebuild |
| `codesign --verify --deep --strict` fails | A dylib or the extension was modified after signing | Rerun packaging on a fresh build rather than re-signing pieces by hand. |

## Related documents

- [testing/README.md](testing/README.md) — how to verify a build.
- [testing/renderer.md](testing/renderer.md) — headless renderer and GPU checks.
- [release.md](release.md) — versioning, CI, and published archives.
- [repository-layout.md](repository-layout.md) — where each source tree lives.
