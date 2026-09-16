/* Theme runtime. Loaded synchronously in <head> ahead of the stylesheets so the
   resolved appearance, tone and accent tokens are on <html> before first paint.
   Native injects window.__appTheme at document start; without it the defaults
   below apply and a system appearance is resolved from the media query. */
(function () {
  'use strict';

  var DEFAULT_MODE = 'system';
  var DEFAULT_ACCENT = '#80bbff';
  var DEFAULT_TONE = 'neutral';

  var HEX6 = /^#[0-9a-f]{6}$/;
  var WHITE = 0xffffff;
  var INK = 0x14161a;

  /* Worst-case neutral surface per appearance, mirroring panel.css: the
     lightest dark surface and the darkest light surface across all tones.
     Text accents are fitted against these so every tone stays legible. */
  var SURFACE_REF = { dark: 0x3b414b, light: 0xe3e8f0 };


  /* Contrast targets: AA body text for accents and filled-button labels,
     AA non-text for focus rings and control glyphs. */
  var TEXT_RATIO = 4.5;
  var FILL_RATIO = 4.6;
  var GRAPHIC_RATIO = 3.2;
  var GLYPH_RATIO = 3;
  /* Below this lightness a hue-preserving fill is too dark to still read as the
     chosen accent, so the label flips to ink instead. */
  var FILL_FLOOR = 0.34;
  var STATE_STEP = 0.055;

  var LINEAR = new Float64Array(256);
  for (var i = 0; i < 256; i++) {
    var channel = i / 255;
    LINEAR[i] = channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
  }

  function luminance(rgb) {
    return 0.2126 * LINEAR[(rgb >> 16) & 255] + 0.7152 * LINEAR[(rgb >> 8) & 255] + 0.0722 * LINEAR[rgb & 255];
  }

  function contrast(a, b) {
    var la = luminance(a) + 0.05;
    var lb = luminance(b) + 0.05;
    return la > lb ? la / lb : lb / la;
  }

  /* HSL scratch: read once, then synthesise variants without allocating. */
  var hslH = 0;
  var hslS = 0;
  var hslL = 0;

  function readHsl(rgb) {
    var r = ((rgb >> 16) & 255) / 255;
    var g = ((rgb >> 8) & 255) / 255;
    var b = (rgb & 255) / 255;
    var max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    var min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    var span = max - min;
    var l = (max + min) / 2;
    var h = 0;
    var s = 0;
    if (span > 0) {
      s = l > 0.5 ? span / (2 - max - min) : span / (max + min);
      if (max === r) h = (g - b) / span + (g < b ? 6 : 0);
      else if (max === g) h = (b - r) / span + 2;
      else h = (r - g) / span + 4;
      h /= 6;
    }
    hslH = h;
    hslS = s;
    hslL = l;
  }

  function hueChannel(p, q, t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  function packHsl(h, s, l) {
    var r;
    var g;
    var b;
    if (s === 0) {
      r = l;
      g = l;
      b = l;
    } else {
      var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      var p = 2 * l - q;
      r = hueChannel(p, q, h + 1 / 3);
      g = hueChannel(p, q, h);
      b = hueChannel(p, q, h - 1 / 3);
    }
    return (Math.round(r * 255) << 16) | (Math.round(g * 255) << 8) | Math.round(b * 255);
  }

  function shiftLightness(rgb, delta) {
    readHsl(rgb);
    var l = hslL + delta;
    if (l < 0) l = 0;
    else if (l > 1) l = 1;
    return packHsl(hslH, hslS, l);
  }

  /* Move `rgb` along its own lightness axis - hue and saturation preserved -
     until it clears `ratio` against `ref`, staying as close to the input as
     possible. Direction is whichever endpoint can reach further, so black
     accents brighten and white accents darken without special cases. */
  function fit(rgb, ref, ratio) {
    if (contrast(rgb, ref) >= ratio) return rgb;
    readHsl(rgb);
    var h = hslH;
    var s = hslS;
    var start = hslL;
    var up = contrast(packHsl(h, s, 1), ref) >= contrast(packHsl(h, s, 0), ref);
    var lo = up ? start : 0;
    var hi = up ? 1 : start;
    var best = packHsl(h, s, up ? hi : lo);
    if (contrast(best, ref) < ratio) return best;
    for (var step = 0; step < 14; step++) {
      var mid = (lo + hi) / 2;
      var candidate = packHsl(h, s, mid);
      if (contrast(candidate, ref) >= ratio) {
        best = candidate;
        if (up) hi = mid;
        else lo = mid;
      } else if (up) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return best;
  }

  function hex(rgb) {
    return '#' + (0x1000000 | rgb).toString(16).slice(1);
  }

  /* Same six-digit contract as the native store and the colour picker. */
  function parseAccent(value) {
    if (typeof value !== 'string') return DEFAULT_ACCENT;
    var raw = value.trim().toLowerCase();
    return HEX6.test(raw) ? raw : DEFAULT_ACCENT;
  }

  function parseMode(value) {
    return value === 'light' || value === 'dark' || value === 'system' ? value : DEFAULT_MODE;
  }

  function parseTone(value) {
    return value === 'warm' || value === 'cool' || value === 'neutral' ? value : DEFAULT_TONE;
  }

  /* Accent-derived tokens. Every result is contrast-checked, so an arbitrary
     hex - including pure white or black - can never produce an unreadable
     filled button, link or focus ring. */
  function tokens(accent, appearance) {
    var base = parseInt(accent.slice(1), 16);
    var ref = SURFACE_REF[appearance];
    var primary;
    var onPrimary;

    if (contrast(WHITE, base) >= FILL_RATIO) {
      primary = base;
      onPrimary = WHITE;
    } else {
      readHsl(base);
      if (hslS < 0.12) {
        onPrimary = INK;
        primary = fit(base, INK, FILL_RATIO);
      } else {
        var darkened = fit(base, WHITE, FILL_RATIO);
        readHsl(darkened);
        if (hslL >= FILL_FLOOR) {
          primary = darkened;
          onPrimary = WHITE;
        } else {
          onPrimary = INK;
          primary = fit(base, INK, FILL_RATIO);
        }
      }
    }

    /* Prefer the conventional direction (lighter under a white label, darker
       under an ink label) and fall back to the other when the preferred one
       would drop the label below AA. */
    var preferred = onPrimary === WHITE ? STATE_STEP : -STATE_STEP;
    var probe = shiftLightness(primary, preferred);
    var direction = probe !== primary && contrast(probe, onPrimary) >= TEXT_RATIO ? preferred : -preferred;

    return {
      accentBase: accent,
      accent: hex(fit(base, ref, TEXT_RATIO)),
      primary: hex(primary),
      primaryHover: hex(fit(shiftLightness(primary, direction), onPrimary, TEXT_RATIO)),
      primaryActive: hex(fit(shiftLightness(primary, direction * 2), onPrimary, TEXT_RATIO)),
      primaryLine: hex(fit(primary, ref, GRAPHIC_RATIO)),
      onPrimary: hex(onPrimary),
      focus: hex(fit(base, ref, GRAPHIC_RATIO)),
      control: hex(fit(base, WHITE, GLYPH_RATIO))
    };
  }

  var media = typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  var root = document.documentElement;

  var mode = DEFAULT_MODE;
  var accent = DEFAULT_ACCENT;
  var tone = DEFAULT_TONE;

  var liveMode = '';
  var liveTone = '';
  var liveAccent = '';
  var liveAppearance = '';

  function resolve() {
    if (mode !== 'system') return mode;
    return media ? (media.matches ? 'dark' : 'light') : 'dark';
  }

  function paint() {
    var appearance = resolve();
    if (mode === liveMode && tone === liveTone && accent === liveAccent && appearance === liveAppearance) return;

    if (mode !== liveMode) root.dataset.themeMode = mode;
    if (tone !== liveTone) root.dataset.tone = tone;
    if (appearance !== liveAppearance) {
      root.dataset.theme = appearance;
      root.style.colorScheme = appearance;
    }
    if (accent !== liveAccent || appearance !== liveAppearance) {
      var derived = tokens(accent, appearance);
      var style = root.style;
      style.setProperty('--accent-base', derived.accentBase);
      style.setProperty('--accent', derived.accent);
      style.setProperty('--primary', derived.primary);
      style.setProperty('--primary-hover', derived.primaryHover);
      style.setProperty('--primary-active', derived.primaryActive);
      style.setProperty('--primary-line', derived.primaryLine);
      style.setProperty('--on-primary', derived.onPrimary);
      style.setProperty('--focus', derived.focus);
      style.setProperty('--control', derived.control);
    }

    liveMode = mode;
    liveTone = tone;
    liveAccent = accent;
    liveAppearance = appearance;
  }

  function adopt(theme) {
    if (!theme || typeof theme !== 'object') return;
    mode = parseMode(theme.mode);
    accent = parseAccent(theme.accent);
    tone = parseTone(theme.tone);
  }

  window.appTheme = {
    /* Called with snapshot.theme on every native snapshot; unchanged values
       touch neither the DOM nor the colour math. */
    apply: function (theme) {
      adopt(theme);
      paint();
    }
  };

  adopt(window.__appTheme);
  paint();

  if (media) {
    media.addEventListener('change', function () {
      /* An explicit Light/Dark override stays authoritative even when the
         native appearance - and with it this media query - changes. */
      if (mode === 'system') paint();
    });
  }
}());
