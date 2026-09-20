/* Panel localization. Keys are the English source strings, the same convention as
   String(localized:) on the Swift side, so an untranslated key renders as English.
   Native injects window.__appLanguage (the app's effective language) at document start
   and repeats it in every snapshot as state.language.effective; without either the
   browser language decides, and anything unknown stays English.
   `{name}` placeholders are filled from the params object; a missing param is left as is.

   One catalog module per language lives in locales/<tag>.js. To ship a language, add
   its module to the import list and the registry below, allowlist the file in
   WebPanelAssets and list the tag in AppLanguage.supported; see docs/localization.md. */

import zhHans from './locales/zh-Hans.js';

// Tags are BCP 47 and must match the Swift registry and the .xcstrings locale.
const catalogs = {
  'zh-Hans': zhHans,
};

const supported = Object.keys(catalogs);

function maximize(tag) {
  try { return new Intl.Locale(tag).maximize(); } catch { return null; }
}

const maximized = new Map(supported.map(tag => [tag, maximize(tag)]));

// An exact tag wins; otherwise the first catalog whose language and script agree with
// the request once both are maximized. That keeps the region loose (zh-Hans-TW is still
// Simplified, en-GB would still be an English catalog) while never crossing scripts, so
// Traditional Chinese falls back to English until it ships its own catalog.
// Unsupported or malformed tags resolve to '' and render English.
function resolve(tag) {
  const value = String(tag || '').trim();
  if (supported.includes(value)) return value;
  const wanted = maximize(value);
  if (!wanted) return '';
  for (const candidate of supported) {
    const own = maximized.get(candidate);
    if (own && own.language === wanted.language && own.script === wanted.script) return candidate;
  }
  return '';
}

let active = '';
let catalog = null;

export function setLanguage(tag) {
  active = resolve(tag);
  catalog = active ? catalogs[active] : null;
  document.documentElement.lang = active || 'en';
  return active || 'en';
}

export function language() { return active || 'en'; }

export function t(source, params) {
  if (typeof source !== 'string') return source;
  const text = catalog && Object.prototype.hasOwnProperty.call(catalog, source) ? catalog[source] : source;
  if (!params) return text;
  return text.replace(/\{(\w+)\}/g, (match, name) => Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match);
}

// Markup that ships in index.html carries its English text as data-i18n / data-i18n-label
// so the same key is used there and here.
export function applyStaticText(root = document) {
  for (const node of root.querySelectorAll('[data-i18n]')) node.textContent = t(node.dataset.i18n);
  for (const node of root.querySelectorAll('[data-i18n-label]')) node.setAttribute('aria-label', t(node.dataset.i18nLabel));
}

setLanguage(window.__appLanguage || navigator.language);
