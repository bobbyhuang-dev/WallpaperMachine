# Appearance

**Settings -> Appearance** styles the app's own interface. Wallpaper colors,
playback and display settings are untouched.

## Options

| Setting | Values | Notes |
| --- | --- | --- |
| Appearance | **System (Auto)**, **Light**, **Dark** | System follows the macOS light/dark setting without reloading the panel; a manual choice also sets the native app appearance |
| Accent color | Color picker | Colors buttons, links and focus rings |
| Surface tone | **Neutral**, **Warm**, **Cool** | Warms or cools the window background |
| App icon | **Minimal**, **Day**, **Night** | Changes the running Dock icon immediately and restores the choice at launch; Finder and the menu bar stay unchanged |

Accent shades adapt so text, buttons and focus rings stay readable against the
resolved background. The theme runtime resolves appearance, tone and accent
tokens before first paint, so the panel does not flash an unstyled or
wrong-appearance frame.

Appearance preferences are stored natively and stay usable even when renderer
settings are unavailable.

## Persistence and reset

Changes apply immediately and are remembered for the next launch. **Reset
appearance** restores System, the default accent, the Neutral tone and the Day
icon. It does not touch wallpapers, playback or display configuration.

## Logo and app icon

The brand mark combines an open display frame with an eight-tooth gear. The
bundled Finder icon has a single white background with a black mark in light appearance,
and a single black background with a white mark in dark appearance. Both retain
the cyan–blue–violet wallpaper panel. The display frame is centred on the native
background with equal opposing margins; the gear extends below and to its left.
The complete artwork fills roughly 72% of the background width. The panel meets the frame
without a background seam and uses an explicit curved cutout around the gear
instead of an SVG mask, so Icon Composer preserves the separation.
The native frame is a filled outline: macOS 26 recoloring fills an open stroked
path despite `fill="none"`. Icon regression exports explicitly select
`--design-generation 26` to match the deployment target rather than the newer
Icon Composer preview default.
macOS selects the Finder variant through its **Appearance → Icon & widget style**
setting; neither the panel theme nor the Dock icon preference overrides it.
The menu bar uses a monochrome template, and the panel shows the mark in its
title bar, first welcome page and Settings → About.

The Dock picker is independent of the panel's light/dark theme. **Minimal** uses
the same frame-and-gear geometry as Day and Night, in blue on white without the gradient wallpaper fill.
**Day** and **Night** use the white and black variants described above. The
selection is stored with the appearance preferences and applied with
`NSApplication.applicationIconImage`, without changing the app bundle or resetting
system icon caches. Day is the default. The selected icon applies while the app
is running; a pinned Dock entry can show the bundled icon after the app quits.

`scripts/brand.py` owns the geometry and colours. The Manrope wordmark is
stored as outlines in `scripts/lib/wordmark.py`, so rendering needs no font
installation. Regenerate the app assets on macOS with:

```sh
python3 scripts/brand.py
python3 scripts/brand.py --website ../WallpaperMachineWebiste
python3 scripts/brand.py --panel-glyph
```

The last command prints the glyph used by `brands.wallpaperMachine` in
`WebUI/panel.js`; update it when changing mark geometry. The app icon is generated
as `App/Resources/AppIcon.icon`: vector foreground layers plus solid light/dark
backgrounds. Xcode compiles this Icon Composer document into the app's assets
and fallback ICNS. macOS owns the outer mask; no inset tile or opaque canvas is
baked into the artwork. Website app-icon PNGs reuse the native Dock exports;
Quick Look and `sips` produce square website and tray PNGs. The tray export converts
black-on-white coverage to alpha with AppKit so
the background and enclosed holes stay transparent, including antialiased edges.
This step requires the Xcode Swift toolchain.

The same generator exports `WebUI/app-icons/{minimal,day,night}.png` for both
the picker previews and the native Dock image loader. These fixed-appearance
1024 px PNGs use Icon Composer's macOS 26 rendering, retain the 100 px transparent
outer margin used by the compiled icon, and load as 512-point Retina images.
All three Dock variants share the regular native mark geometry and frame weight;
the heavier small-size glyph remains reserved for the panel and menu bar. The
root README displays `day.png`; update its path there if the export is renamed.

Website export includes `brand/logo.svg` for light backgrounds,
`brand/logo-dark.svg` for dark backgrounds, and a centered `brand/mark.svg`.
`brand/app-icon-{minimal,day,night}.{svg,png}` provides all three current appearances;
the unqualified `brand/app-icon.svg` and `.png` use Day, the app default.
Every app-icon variant uses the enlarged native geometry with the display frame
centered on both axes. PNGs are copied from `WebUI/app-icons/` to preserve the
native rendering and transparent margin; SVGs share the geometry and colors,
without Icon Composer's lighting. Favicons use Day with no outer margin, and
touch/manifest icons use Day on a full square white background.

To refresh only website assets from the current generated Dock PNGs without
rewriting app resources, run:

```sh
python3 scripts/brand.py --skip-app --website ../WallpaperMachineWebiste
```

After changing native icon geometry, use the regular `--website` command instead
to regenerate both sets together. The website folder currently contains assets
only, with no pages or separate product photos; when adding its HTML, use:

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
```

## Verification

See [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).
