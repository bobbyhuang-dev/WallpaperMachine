# Appearance

**Settings -> Appearance** styles the app's own interface. Wallpaper colors,
playback and display settings are untouched.

## Options

| Setting | Values | Notes |
| --- | --- | --- |
| Appearance | **System (Auto)**, **Light**, **Dark** | System follows the macOS light/dark setting without reloading the panel; a manual choice also sets the native app appearance |
| Accent color | Color picker | Colors buttons, links and focus rings |
| Surface tone | **Neutral**, **Warm**, **Cool** | Warms or cools the window background |

Accent shades adapt so text, buttons and focus rings stay readable against the
resolved background. The theme runtime resolves appearance, tone and accent
tokens before first paint, so the panel does not flash an unstyled or
wrong-appearance frame.

Appearance preferences are stored natively and stay usable even when renderer
settings are unavailable.

## Persistence and reset

Changes apply immediately and are remembered for the next launch. **Reset
appearance** restores System, the default accent and the Neutral tone. It does
not touch wallpapers, playback or display configuration.

## Verification

See [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).
