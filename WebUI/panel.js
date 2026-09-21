import { renderSettings } from './settings.js';
import { createWelcome, SIGN_IN_ID } from './welcome.js';
import { glyphs } from './icons.js';
import { t, applyStaticText, setLanguage, language } from './i18n.js';

const $ = (id) => document.getElementById(id);
const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
// GitHub brand mark: kept from the original panel; Lucide ships no brand icons.
const brands = { github: '<path fill="currentColor" stroke="none" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>' };
function icon(name, size = 16) { const px = Number(size) || 16; return `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${glyphs[name] || brands[name] || glyphs.info}</svg>`; }
const pending = new Set();
const drafts = new Map();
let state = null;
const inFlight = new Map();
let localError = '';
let popover = null;
let popoverTrigger = '';
let queueExpanded = false;
let dialogTarget = null;
let dialogTrigger = null;
// Job whose finished sign-in the dialog is confirming, and the timer that then lets it close on its own.
let dialogHandoff = null;
let handoffTimer = 0;
let workshopDraft = null;
let dialogAccount = null;
// Password / Steam Guard requests the user closed with "Not now": keyed by job and request so the
// same request stays quiet while a new one still opens the dialog.
const dismissedAuth = new Set();
let searchTimer;
// Installed keeps Discover's filter model (required tags, excluded tags) and applies it in
// the page to each wallpaper's own tags: its manifest facts from the snapshot, its kind, and
// the page's Favorite / Active facts. Nothing is excluded by default: the library is the
// user's own, so every box starts ticked.
const installed = { text: '', sort: 'title', descending: false, tags: [], excludedTags: [] };
// Workshop sort keys mirror `WorkshopSort` raw values; Swift maps them to Steam's browse query.
const workshopSorts = [['toprated', 'Highest rated'], ['trend-today', 'Most popular today'], ['trend', 'Trending this week'], ['trend-month', 'Most popular this month'], ['trend-year', 'Most popular this year'], ['totaluniquesubscribers', 'Most subscribed'], ['mostrecent', 'Newest'], ['textsearch', 'Relevance']];
// Installed sort keys with the direction each one starts in: names read A→Z, while favorites,
// size and date are asked for to see the biggest / newest / starred first.
const installedSorts = [['title', 'Name', false], ['type', 'Type', false], ['favorites', 'Favorites', true], ['size', 'File size', true], ['added', 'Date added', true]];
// Multi-select lives only in the page: ids of installed wallpapers checked for a batch action.
const selection = new Set();
let selectionAnchor = null;
let selecting = false; // Toolbar "Select" mode keeps every tile's check visible.
// Wallpaper Engine's own Workshop sidebar, tag for tag. "Show only" boxes start unchecked and
// checking one sends the tag as `requiredtags[]`. Every other box starts checked and unchecking
// it sends the tag as `excludedtags[]`, so a group with everything ticked filters nothing.
// Entries are `tag` or `[tag, label, off]`; `off` marks the boxes Wallpaper Engine leaves
// unchecked by default. Application and Asset are never offered, so they are always excluded.
const showOnlyTags = ['Approved', 'Audio responsive', 'Customizable'];
// Installed leads with the two facts only a library has, then Discover's three.
const installedShowOnlyTags = ['Favorite', 'Active', ...showOnlyTags];
const showOnlyLabels = { Favorite: 'Favorites', Active: 'Active on target display' };
// Approved keeps Wallpaper Engine's green trophy so the mark matches what users know from Workshop.
const showOnlyIcons = { Approved: 'trophy', 'Audio responsive': 'audioLines', Customizable: 'slidersVertical', Favorite: 'heart', Active: 'play' };
const hiddenExcludedTags = ['Application', 'Asset'];
const resolutionSection = (key, title, prefix, sizes) => ({ key, title, quick: true, tags: [[`${prefix}Standard Definition`, prefix ? `${title} (standard)` : 'Standard definition'], ...sizes.map(size => [`${prefix}${size}`, size])] });
// `discoverOnly` marks what Steam knows but a wallpaper's manifest does not carry (its
// Workshop category and resolution), so Installed leaves those boxes out.
const excludeGroups = [
  { key: 'type', title: 'Type', sections: [{ key: 'type', tags: ['Scene', 'Video', 'Web'] }, { key: 'category', discoverOnly: true, tags: ['Wallpaper', 'Preset'] }] },
  { key: 'rating', title: 'Age rating', sections: [{ key: 'rating', tags: [['Everyone', 'Everyone (G)'], ['Questionable', 'Questionable (PG-13)', true], ['Mature', 'Mature (R-18)', true]] }] },
  { key: 'resolution', title: 'Resolution', discoverOnly: true, sections: [
    resolutionSection('widescreen', 'Widescreen', '', ['1280 x 720', '1366 x 768', '1920 x 1080', '2560 x 1440', '3840 x 2160']),
    resolutionSection('ultrawide', 'Ultrawide', 'Ultrawide ', ['2560 x 1080', '3440 x 1440']),
    resolutionSection('dual', 'Dual monitor', 'Dual ', ['3840 x 1080', '5120 x 1440', '7680 x 2160']),
    resolutionSection('triple', 'Triple monitor', 'Triple ', ['4096 x 768', '5760 x 1080', '7680 x 1440', '11520 x 2160']),
    resolutionSection('portrait', 'Portrait monitor / phone', 'Portrait ', ['720 x 1280', '1080 x 1920', '1440 x 2560', '2160 x 3840']),
    { key: 'other-resolution', tags: ['Other resolution', 'Dynamic resolution'] }
  ] },
  { key: 'genre', title: 'Tags', sections: [{ key: 'genre', quick: true, tags: ['Abstract', 'Animal', 'Anime', 'Cartoon', 'CGI', 'Cyberpunk', 'Fantasy', 'Game', 'Girls', 'Guys', 'Landscape', 'Medieval', 'Memes', ['MMD', 'MMD (Miku Miku Dance)'], 'Music', 'Nature', 'Pixel art', 'Relaxing', 'Retro', 'Sci-Fi', 'Sports', 'Technology', 'Television', 'Vehicle', ['Unspecified', 'Unspecified genre', true]] }] }
];
const tagEntry = (entry) => Array.isArray(entry) ? { tag: entry[0], label: entry[1] || entry[0], off: Boolean(entry[2]) } : { tag: entry, label: entry, off: false };
const excludeSections = excludeGroups.flatMap(group => group.sections);
const excludeEntries = excludeSections.flatMap(section => section.tags.map(tagEntry));
const defaultExcludedTags = [...hiddenExcludedTags, ...excludeEntries.filter(entry => entry.off).map(entry => entry.tag)];
const installedGroups = excludeGroups.filter(group => !group.discoverOnly).map(group => ({ ...group, sections: group.sections.filter(section => !section.discoverOnly) }));
const genreTags = excludeGroups.find(group => group.key === 'genre').sections[0].tags.map(tagEntry).filter(entry => entry.tag !== 'Unspecified').map(entry => entry.tag.toLowerCase());
const uniqueTags = (values) => [...new Set(values)];
// The page's filter draft and its defaults: Discover's are Wallpaper Engine's, Installed's are empty.
const filterDraft = (discover) => discover ? workshopDraft : installed;
const filterDefaults = (discover) => discover ? defaultExcludedTags : [];
const actionKey = (action, args = {}) => `${action}:${args.id ?? ''}:${args.displayID ?? ''}:${args.propertyID ?? args.key ?? ''}`;
const busy = (action, args = {}) => pending.has(actionKey(action, args));
const disabled = (value) => value ? ' disabled' : '';
const checked = (value) => value ? ' checked' : '';
const keyAttr = (value) => `data-key="${escapeHTML(value)}"`;
function button(label, action, args = {}, options = {}) {
  const attributes = Object.entries(args).map(([key, value]) => `data-${key.replace(/ID$/, 'Id').replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)}="${escapeHTML(typeof value === 'object' ? JSON.stringify(value) : value)}"`).join(' ');
  return `<button type="button" data-action="${action}" ${attributes} class="${options.className || ''}"${disabled(options.disabled || busy(action, args))}${options.title ? ` title="${escapeHTML(options.title)}" aria-label="${escapeHTML(options.title)}"` : ''}${options.expanded !== undefined ? ` aria-expanded="${options.expanded ? 'true' : 'false'}"` : ''}${options.controls ? ` aria-controls="${escapeHTML(options.controls)}"` : ''}>${options.icon ? icon(options.icon) : ''}${label ? `<span class="button-label">${escapeHTML(label)}</span>` : ''}</button>`;
}
function selectOptions(values, current) { return values.map((entry) => { const [value, label] = Array.isArray(entry) ? entry : [entry, entry]; return `<option value="${escapeHTML(value)}"${String(current) === String(value) ? ' selected' : ''}>${escapeHTML(label)}</option>`; }).join(''); }
function safeLink(url) { if (!url) return ''; try { const parsed = new URL(url); return parsed.protocol === 'https:' ? parsed.href : ''; } catch { return ''; } }
function safeImage(url) { if (!url) return ''; try { const parsed = new URL(url); return ['https:', 'mwe-ui:'].includes(parsed.protocol) ? parsed.href : ''; } catch { return ''; } }
function preview(url, className = '') { const source = safeImage(url); return `${icon('image', 32)}${source ? `<img ${keyAttr(source)} class="${className}" src="${escapeHTML(source)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer">` : ''}`; }
function tags(values = []) { return `<div class="tags">${values.map(value => `<span class="tag">${escapeHTML(value)}</span>`).join('')}</div>`; }
function bytes(value) { if (!Number.isFinite(value) || value <= 0) return ''; const units = ['B', 'KB', 'MB', 'GB']; const exponent = Math.min(Math.floor(Math.log(value) / Math.log(1024)), 3); return `${(value / 1024 ** exponent).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[exponent]}`; }
function speed(value) {
  if (!Number.isFinite(value) || value < 0) return '';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  const exponent = value > 0 ? Math.min(Math.max(Math.floor(Math.log10(value) / 3), 0), 3) : 0;
  return `${(value / 1000 ** exponent).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[exponent]}`;
}
function rate(value) { const pace = speed(value); return pace ? t('Network speed: {speed}', { speed: pace }) : ''; }
function transfer(item, { includePercent = true } = {}) { const percent = Number.isFinite(item?.progress) ? `${Math.round(clamp(item.progress) * 100)}%` : ''; const received = bytes(item?.bytesReceived); const expected = bytes(item?.bytesExpected); const amount = received && expected ? t('{received} of {expected}', { received, expected }) : received; return [includePercent ? percent : '', amount, rate(item?.bytesPerSecond)].filter(Boolean).join(' · '); }

// Keyed reconciliation keeps loaded preview images, open disclosures and active fields alive.
function morph(parent, html) {
  const template = document.createElement('template'); template.innerHTML = html;
  reconcile(parent, template.content);
}
function reconcile(parent, source) {
  const old = [...parent.childNodes];
  const keys = new Map(old.filter(node => node.nodeType === 1 && node.dataset.key).map(node => [node.dataset.key, node]));
  const used = new Set();
  let cursor = parent.firstChild;
  for (const fresh of [...source.childNodes]) {
    let node = fresh.nodeType === 1 && fresh.dataset.key ? keys.get(fresh.dataset.key) : old.find(candidate => !used.has(candidate) && !(candidate.nodeType === 1 && candidate.dataset.key) && candidate.nodeType === fresh.nodeType && candidate.nodeName === fresh.nodeName);
    if (!node || node.nodeName !== fresh.nodeName) { node = fresh.cloneNode(true); parent.insertBefore(node, cursor); }
    else { if (node !== cursor) parent.insertBefore(node, cursor); patch(node, fresh); }
    used.add(node); cursor = node.nextSibling;
  }
  for (const node of old) if (!used.has(node)) node.remove();
}
function patch(node, fresh) {
  if (node.nodeType === 3) { if (node.nodeValue !== fresh.nodeValue) node.nodeValue = fresh.nodeValue; return; }
  if (node.nodeType !== 1) return;
  const focused = node === document.activeElement;
  for (const attribute of [...node.attributes]) {
    if (attribute.name === 'open' && node.tagName === 'DETAILS') continue;
    if (!fresh.hasAttribute(attribute.name) && !(focused && ['value', 'checked'].includes(attribute.name))) node.removeAttribute(attribute.name);
  }
  for (const attribute of [...fresh.attributes]) {
    if (attribute.name === 'open' && node.tagName === 'DETAILS') continue;
    if (focused && ['value', 'checked'].includes(attribute.name)) continue;
    if (node.getAttribute(attribute.name) !== attribute.value) node.setAttribute(attribute.name, attribute.value);
  }
  // Secrets are never part of the markup, so a password field keeps what was typed across renders.
  if (node.tagName === 'INPUT') { if (!focused) { if (node.name !== 'response' && node.type !== 'password' && node.value !== fresh.value) node.value = fresh.value; node.checked = fresh.checked; } return; }
  if (node.tagName === 'TEXTAREA') { if (!focused && node.value !== fresh.value) node.value = fresh.value; return; }
  if (node.tagName === 'SELECT' && focused) return;
  reconcile(node, fresh);
  if (node.tagName === 'SELECT') node.value = fresh.value;
}

async function send(action, args = {}) {
  const bridge = window.webkit?.messageHandlers?.native;
  if (!bridge) { localError = t('The native connection is unavailable. Open this panel in MacWallpaperEngine, then reconnect.'); renderError(); throw new Error(localError); }
  const key = actionKey(action, args);
  if (pending.has(key)) {
    if (['property', 'wallpaperSetting', 'displayConfig', 'workshopSearch', 'navigate', 'target'].includes(action)) {
      await inFlight.get(key);
      return send(action, args);
    }
    return state;
  }
  pending.add(key); localError = ''; render();
  try {
    const request = bridge.postMessage({ action, ...args });
    inFlight.set(key, request);
    const response = await request;
    if (response && typeof response === 'object') receive(response);
    return response;
  } catch (error) {
    localError = error?.message || String(error); renderError(); throw error;
  } finally { pending.delete(key); inFlight.delete(key); render(); }
}
function receive(snapshot) {
  if (!snapshot || typeof snapshot !== 'object') return;
  state = snapshot;
  if (selection.size) { const ids = new Set((snapshot.wallpapers || []).map(item => item.id)); for (const id of selection) if (!ids.has(id)) selection.delete(id); }
  if (selectionAnchor && !selection.has(selectionAnchor)) selectionAnchor = null;
  window.appTheme.apply(snapshot.theme);
  // Every string is translated where it is drawn, so a language change only needs the
  // static markup refreshed before the render below redraws the rest.
  const shown = language();
  if (snapshot.language?.effective && setLanguage(snapshot.language.effective) !== shown) applyStaticText();
  if (!workshopDraft) workshopDraft = { text: snapshot.workshop?.text || '', sort: snapshot.workshop?.sort || 'trend-year', tags: [...(snapshot.workshop?.tags || [])], excludedTags: [...(snapshot.workshop?.excludedTags || defaultExcludedTags)] };
  // The first-run guide opens from the first snapshot that reports it unseen and closes for
  // good once the user finishes or leaves it; a snapshot that arrives before native has
  // stored that choice cannot reopen it.
  if (snapshot.welcomeSeen === false) welcome.openIfUndecided();
  render();
}
window.wallpaperUI = { receive };
function renderError() {
  const error = localError || state?.error || state?.downloadError;
  if (!state && error) morph($('browser-empty'), `<h1>${escapeHTML(t('Native connection unavailable'))}</h1><p>${escapeHTML(t('Open this panel in MacWallpaperEngine. Use Reconnect above to try again.'))}</p>`);
  $('error-banner').hidden = !error;
  if (error) morph($('error-banner'), `<p>${escapeHTML(error)}</p>${button(t('Reconnect'), 'ready', {}, { icon: 'refresh' })}${button('', 'dismissError', {}, { icon: 'close', title: t('Dismiss error'), className: 'quiet icon-button' })}`);
}
function render() {
  renderError();
  if (!state) return;
  const discover = state.page === 'discover';
  const settings = state.page === 'settings';
  document.querySelectorAll('.tabs [data-page]').forEach(tab => { if (tab.dataset.page === state.page) tab.setAttribute('aria-current', 'page'); else tab.removeAttribute('aria-current'); tab.disabled = busy('navigate', { page: tab.dataset.page }); });
  document.documentElement.style.setProperty('--window-controls-inset', `${Math.max(0, Number(state.windowControlsInset) || 0)}px`);
  morph($('app-identity'), `<span class="app-title"><span class="app-name">MacWallpaperEngine</span>${state.version ? `<span class="app-version">${escapeHTML(state.version)}</span>` : ''}</span>${safeLink(state.repositoryURL) ? button('', 'openExternal', { url: state.repositoryURL }, { icon: 'github', title: t('MacWallpaperEngine on GitHub'), className: 'quiet icon-button github-link' }) : ''}`);
  morph($('top-actions'), `<label class="sr-only" for="target-display">${escapeHTML(t('Target display'))}</label><select id="target-display" data-change="target" aria-label="${escapeHTML(t('Target display'))}"${disabled(state.busy)}>${(state.displays || []).map(display => `<option value="${escapeHTML(display.id)}"${display.id === state.targetDisplayID ? ' selected' : ''}${disabled(!display.enabled || display.mode === 'mirror')}>${escapeHTML(display.title)}${display.mode === 'mirror' ? escapeHTML(t(' (mirrored)')) : !display.enabled ? escapeHTML(t(' (disabled)')) : ''}</option>`).join('')}</select>${queueButton()}`);
  $('library-page').hidden = settings;
  $('settings-content').hidden = !settings;
  if (settings) renderSettings($('settings-content'), state, { send, escapeHTML, icon, requestAssets: (element) => run(requestDownload(null, element)), openDownloadDialog: (id, element) => openDialog(id, element), openWelcome: () => welcome.open() });
  else {
    // Both library pages share one right-hand filter sidebar; the toolbar's Filter button
    // opens and closes it, and each page remembers its own choice natively.
    const filtersOpen = !filtersCollapsed();
    $('library-page').classList.toggle('discover', discover);
    $('library-page').classList.toggle('filters-open', filtersOpen);
    $('filter-sidebar').hidden = !filtersOpen;
    renderToolbar(discover);
    if (filtersOpen) renderFilters(discover);
    renderGrid(discover);
    renderInspector(discover);
  }
  renderActivity(); renderPopover(); renderDialog(); welcome.render(state); surfaceAuthRequests();
}
const filtersCollapsed = () => Boolean(state?.filtersCollapsed?.[state.page]);
// Active filters on a page: every required tag plus every box that differs from the page's
// defaults, so the count reads zero right after Clear.
function filterCount(discover) {
  const draft = filterDraft(discover), defaults = filterDefaults(discover);
  return draft.tags.length + defaults.filter(tag => !draft.excludedTags.includes(tag)).length + draft.excludedTags.filter(tag => !defaults.includes(tag)).length;
}
const filterCountPill = (count) => count ? `<span class="filter-count" title="${escapeHTML(t('{count} active', { count }))}">${count}</span>` : '';
// The one control that opens and closes the sidebar: a filled button so it reads as the
// place to go, a funnel so it reads as filtering, and the active count riding along. It
// leads the toolbar so it sits right beside the sidebar it controls.
function filterButton(count) {
  const open = !filtersCollapsed();
  return `<button type="button" data-action="toggleFilters" class="filter-button" aria-expanded="${open}" aria-controls="filter-sidebar" title="${escapeHTML(open ? t('Hide filters') : t('Show filters'))}"${disabled(busy('toggleFilters'))}>${icon('filter')}<span class="button-label">${escapeHTML(t('Filter'))}</span>${filterCountPill(count)}</button>`;
}
function renderToolbar(discover) {
  const search = discover ? workshopDraft.text : installed.text;
  const sortLabel = t(installedSorts.find(([key]) => key === installed.sort)?.[1] || 'Name');
  morph($('browser-toolbar'), `${filterButton(filterCount(discover))}<form class="search-form" data-form="search" ${keyAttr(discover ? 'workshop-search' : 'installed-search')}>${icon('search')}<label class="sr-only" for="wallpaper-search">${escapeHTML(discover ? t('Search Steam Workshop') : t('Search installed wallpapers'))}</label><input id="wallpaper-search" type="search" autocomplete="off" placeholder="${escapeHTML(discover ? t('Search Workshop') : t('Search wallpapers'))}" value="${escapeHTML(search)}" data-input="search">${discover ? `<button type="submit" title="${escapeHTML(t('Search Workshop'))}">${escapeHTML(t('Search'))}</button>` : ''}</form><label class="sr-only" for="browser-sort">${escapeHTML(t('Sort wallpapers'))}</label><select id="browser-sort" data-change="sort">${selectOptions((discover ? workshopSorts : installedSorts).map(([key, label]) => [key, t(label)]), discover ? workshopDraft.sort : installed.sort)}</select>${discover ? `${button('', 'refreshWorkshop', {}, { icon: 'refresh', title: t('Refresh Workshop'), disabled: state.workshop.loading })}` : `${button('', 'toggleSortDirection', {}, { icon: installed.descending ? 'sortDescending' : 'sortAscending', title: installed.descending ? t('{sort}, descending. Click to sort ascending', { sort: sortLabel }) : t('{sort}, ascending. Click to sort descending', { sort: sortLabel }), className: 'icon-button sort-direction' })}${button(selecting ? t('Done') : t('Select'), 'toggleSelecting', {}, { icon: selecting ? 'close' : 'check', title: selecting ? t('Leave selection mode') : t('Select wallpapers to move to Trash'), className: selecting ? 'selecting' : '' })}${button('', 'refresh', {}, { icon: 'refresh', title: t('Refresh library'), disabled: state.libraryLoading })}${button(t('Import'), 'openImport', {}, { icon: 'plus', disabled: state.import?.busy })}`}`);
}
const filterGroup = (key, title, body, open) => `<details class="filter-group"${open ? ' open' : ''} ${keyAttr(key)}><summary>${escapeHTML(t(title))}${icon('chevronRight', 13)}</summary><div class="filter-options">${body}</div></details>`;
const filterHeading = (count, clearAction) => `<div class="filter-heading"><h3>${escapeHTML(t('Filters'))}${filterCountPill(count)}</h3>${button(t('Clear'), clearAction, {}, { className: 'link', disabled: !count })}</div>`;
// One sidebar for both pages: Discover's boxes go to Steam as `requiredtags[]` /
// `excludedtags[]`; Installed's apply the same rules to the library in the page.
function renderFilters(discover) {
  const draft = filterDraft(discover);
  const showOnly = discover ? showOnlyTags : installedShowOnlyTags;
  // Tags travel to Steam in English; only their labels are translated.
  const required = (tag) => `<label class="check-label" ${keyAttr(tag)}><input type="checkbox" data-change="filterTag" value="${escapeHTML(tag)}"${checked(draft.tags.includes(tag))}>${showOnlyIcons[tag] ? `<span class="check-icon${tag === 'Approved' ? ' approved' : ''}">${icon(showOnlyIcons[tag], 14)}</span>` : ''}<span>${escapeHTML(t(showOnlyLabels[tag] || tag))}</span></label>`;
  const other = draft.tags.filter(tag => !showOnly.includes(tag));
  const section = ({ key, title, quick, tags: entries }) => {
    const values = entries.map(tagEntry);
    const onCount = values.filter(({ tag }) => !draft.excludedTags.includes(tag)).length;
    const head = title || quick ? `<div class="filter-section-head">${title ? `<h4>${escapeHTML(t(title))}</h4>` : ''}${quick ? `<span class="filter-quick">${button(t('All'), 'includeSection', { section: key }, { className: 'link', disabled: onCount === values.length })}${button(t('None'), 'excludeSection', { section: key }, { className: 'link', disabled: onCount === 0 })}</span>` : ''}</div>` : '';
    return `<div class="filter-section" ${keyAttr(key)}>${head}${values.map(({ tag, label }) => `<label class="check-label" ${keyAttr(tag)}><input type="checkbox" data-change="filterExclude" value="${escapeHTML(tag)}"${checked(!draft.excludedTags.includes(tag))}><span>${escapeHTML(t(label))}</span></label>`).join('')}</div>`;
  };
  morph($('filter-sidebar'), `${filterHeading(filterCount(discover), discover ? 'clearWorkshop' : 'clearInstalled')}${filterGroup('show-only', 'Show only', `${showOnly.map(tag => required(tag)).join('')}${other.length ? `<div class="filter-section" ${keyAttr('other')}><div class="filter-section-head"><h4>${escapeHTML(t('Other selected tags'))}</h4></div>${other.map(tag => required(tag)).join('')}</div>` : ''}`, true)}${(discover ? excludeGroups : installedGroups).map(group => filterGroup(group.key, group.title, group.sections.map(section).join(''), true)).join('')}`);
}
function setExcluded(draft, tags, excluded) {
  const set = new Set(draft.excludedTags);
  for (const tag of tags) if (excluded) set.add(tag); else set.delete(tag);
  draft.excludedTags = [...set];
}
// Ticking a box on the current page: Discover asks Steam again, Installed re-filters in place.
function applyFilterChange() {
  render();
  return state.page === 'discover' ? searchWorkshop() : Promise.resolve();
}
// Everything an installed wallpaper can be filtered on, lower-cased for matching: the
// manifest's tags from the snapshot, the kind as Steam's type tag, the page's own Favorite
// and Active facts, and `Unspecified` when no genre was tagged, as Steam would list it.
function installedTags(item, target) {
  const tags = [item.kind, ...(item.tags || [])].map(tag => String(tag).toLowerCase());
  if (item.approved) tags.push('approved');
  if (state.favorites.includes(item.id)) tags.push('favorite');
  if (target?.wallpaperID === item.id) tags.push('active');
  if (!tags.some(tag => genreTags.includes(tag))) tags.push('unspecified');
  return new Set(tags);
}
function matchesInstalledFilters(item, target) {
  const tags = installedTags(item, target);
  return installed.tags.every(tag => tags.has(tag.toLowerCase())) && !installed.excludedTags.some(tag => tags.has(tag.toLowerCase()));
}
// Installed sorts in the page: a primary key in the chosen direction, names breaking ties.
// Wallpapers whose size or date has not been measured yet sort last either way.
const byTitle = (a, b) => a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' });
function sortValue(item) {
  switch (installed.sort) {
    case 'favorites': return Number(state.favorites.includes(item.id));
    case 'size': return Number.isFinite(item.size) ? item.size : null;
    case 'added': return Number.isFinite(item.addedAt) ? item.addedAt : null;
    default: return null;
  }
}
function compareInstalled(a, b) {
  const direction = installed.descending ? -1 : 1;
  if (installed.sort === 'title') return byTitle(a, b) * direction;
  if (installed.sort === 'type') return a.kind.localeCompare(b.kind) * direction || byTitle(a, b);
  const left = sortValue(a), right = sortValue(b);
  if (left === null || right === null) return (left === null) - (right === null) || byTitle(a, b);
  return (left - right) * direction || byTitle(a, b);
}
function visibleWallpapers() {
  const target = (state.displays || []).find(display => display.id === state.targetDisplayID);
  return (state.wallpapers || []).filter(item => (!installed.text || `${item.title} ${(item.tags || []).join(' ')}`.toLocaleLowerCase().includes(installed.text.toLocaleLowerCase())) && matchesInstalledFilters(item, target)).sort(compareInstalled);
}
function renderGrid(discover) {
  const workshop = state.workshop;
  const items = discover ? workshop.items || [] : visibleWallpapers();
  const loading = discover ? workshop.loading : state.libraryLoading;
  const selectedID = discover ? workshop.selectedID : state.selectedID;
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  $('wallpaper-grid').setAttribute('aria-busy', String(Boolean(loading)));
  const count = t(items.length === 1 ? '{count} wallpaper' : '{count} wallpapers', { count: items.length.toLocaleString() });
  morph($('browser-summary'), loading ? escapeHTML(discover ? t('Searching Steam Workshop…') : t('Loading your library…')) : discover ? escapeHTML(workshop.loaded ? t('{count} results', { count: Number(workshop.totalCount).toLocaleString() }) : t('Steam Workshop')) : selection.size ? `<div class="selection-bar"><span class="selection-count">${escapeHTML(t('{count} selected', { count: selection.size.toLocaleString() }))}</span>${button(t('Select all'), 'selectAllVisible', {}, { className: 'link', disabled: items.every(item => selection.has(item.id)) })}${button(t('Clear'), 'clearSelection', {}, { className: 'link' })}${button(selection.size === 1 ? t('Move to Trash') : t('Move {count} to Trash', { count: selection.size.toLocaleString() }), 'deleteSelected', {}, { icon: 'trash', className: 'danger', disabled: state.busy || busy('deleteMany') })}</div>` : `<div class="selection-bar"><span>${escapeHTML(count)}</span>${items.length && selecting ? `<span class="muted">${escapeHTML(t('Click tiles to select them.'))}</span>${button(t('Select all'), 'selectAllVisible', {}, { className: 'link' })}` : ''}</div>`);
  $('wallpaper-grid').classList.toggle('selecting', !discover && (selecting || selection.size > 0));
  retireLivePreviews(new Set(items.map(item => item.id)));
  morph($('wallpaper-grid'), items.map(item => `<article class="wallpaper-tile${selection.has(item.id) ? ' checked' : ''}${live.get(item.id)?.playing ? ' playing' : ''}" ${keyAttr(item.id)}><button type="button" class="tile-select" data-action="${discover ? 'workshopSelect' : 'select'}" data-id="${escapeHTML(item.id)}" aria-pressed="${item.id === selectedID}" aria-label="${escapeHTML(item.title)}, ${escapeHTML(t(item.kind))}${tileMarkNames(item, discover).map(name => `, ${escapeHTML(t(tileMarkGlyphs[name][1]))}`).join('')}${item.id === selectedID ? `, ${escapeHTML(t('selected'))}` : ''}"><span class="tile-placeholder">${icon('image', 28)}</span>${discover && ['loading', 'ready'].includes(live.get(item.id)?.status) ? `<img ${keyAttr(`live-${item.id}`)} class="tile-live" src="${escapeHTML(safeImage(item.animated))}" alt="" decoding="async" crossorigin="anonymous" referrerpolicy="no-referrer">` : ''}${safeImage(item.thumbnail || item.preview) ? `<img ${keyAttr(item.thumbnail || item.preview)} class="tile-still" src="${escapeHTML(safeImage(item.thumbnail || item.preview))}" alt=""${discover ? '' : ' loading="lazy"'} decoding="async"${safeImage(item.thumbnail || item.preview).startsWith('mwe-ui:') ? ' crossorigin="anonymous"' : ''} referrerpolicy="no-referrer">` : ''}<span class="tile-caption"><span class="tile-title">${escapeHTML(item.title)}</span><span class="tile-kind">${escapeHTML(t(item.kind))}</span></span></button>${tileMarksMarkup(item, discover)}${discover ? tileDownloadMarkup(item) : ''}${!discover ? `<button type="button" class="tile-check" data-action="toggleSelect" data-id="${escapeHTML(item.id)}" aria-pressed="${selection.has(item.id)}" aria-label="${escapeHTML(selection.has(item.id) ? t('Deselect: {title}', { title: item.title }) : t('Select: {title}', { title: item.title }))}">${icon('check', 14)}</button><button type="button" class="tile-favorite" data-action="favorite" data-id="${escapeHTML(item.id)}" aria-pressed="${state.favorites.includes(item.id)}" aria-label="${escapeHTML(state.favorites.includes(item.id) ? t('Remove favorite: {title}', { title: item.title }) : t('Add favorite: {title}', { title: item.title }))}"${disabled(busy('favorite', { id: item.id }))}>${icon('heart', 14)}</button>${target?.wallpaperID === item.id ? `<span class="active-badge">${escapeHTML(t('Active'))}</span>` : item.active ? `<span class="active-badge">${escapeHTML(t('Other display'))}</span>` : ''}` : ''}</article>`).join(''));
  const empty = $('browser-empty'); empty.hidden = items.length > 0;
  $('wallpaper-grid').hidden = !items.length;
  if (!items.length) morph(empty, loading ? `<h1>${escapeHTML(discover ? t('Loading Workshop') : t('Loading wallpapers'))}</h1><p>${escapeHTML(discover ? t('Fetching wallpapers from Steam.') : t('Reading your wallpaper library.'))}</p>` : workshop.error && discover ? `<h1>${escapeHTML(t('Workshop unavailable'))}</h1><p>${escapeHTML(workshop.error)}</p>${button(t('Try again'), 'workshopRetry', {}, { icon: 'refresh' })}` : `<h1>${escapeHTML(discover ? t('No wallpapers found') : state.wallpapers.length ? t('No matching wallpapers') : t('Your wallpaper library is empty'))}</h1><p>${escapeHTML(discover ? t('Try a different search or remove some filters. Every selected tag must match.') : state.wallpapers.length ? t('Change your search or clear filters to see more wallpapers.') : t('Import a wallpaper folder or find something on the Workshop.'))}</p><div class="actions">${discover ? button(t('Clear search and filters'), 'clearWorkshopSearch') : state.wallpapers.length ? button(t('Clear search and filters'), 'clearInstalledSearch') : `${button(t('Import wallpapers'), 'openImport', {}, { icon: 'plus' })}${button(t('Browse Workshop'), 'navigate', { page: 'discover' }, { className: 'primary' })}`}</div>`);
  // Steam's public browse page stops at 1,000 pages of 30, whatever the result count says;
  // a page is exactly one of Steam's, so the panel never offers more than that.
  const pages = Math.min(workshopMaxPages(), Math.max(1, Number(workshop.totalPages) || 1));
  if (discover) queueLivePreviews();
  morph($('pagination'), discover ? `${workshop.error && items.length ? `<p class="error">${escapeHTML(workshop.error)}</p>${button(t('Retry'), 'workshopRetry')}` : ''}${button('', 'workshopPage', { workshopPage: Math.max(1, workshop.page - 1) }, { icon: 'chevronLeft', title: t('Previous page'), disabled: loading || workshop.page <= 1 })}<form class="page-jump" data-form="workshopPage" aria-label="${escapeHTML(t('Go to page'))}" novalidate><label>${escapeHTML(t('Page'))} <input type="number" name="page" ${keyAttr('workshop-page')} inputmode="numeric" min="1" max="${pages}" step="1" value="${workshop.page || 1}" title="${escapeHTML(t('Type a page number and press Return'))}" aria-label="${escapeHTML(t('Page number'))}"${disabled(loading || pages <= 1)}></label><span>${escapeHTML(t('of {pages}', { pages: pages.toLocaleString() }))}</span><button type="submit" class="link"${disabled(loading || pages <= 1)}>${escapeHTML(t('Go'))}</button></form>${button('', 'workshopPage', { workshopPage: workshop.page + 1 }, { icon: 'chevronRight', title: t('Next page'), disabled: loading || workshop.page >= pages })}` : '');
}
// The marks a tile wears in its top-left corner, the way Wallpaper Engine flags its own tiles:
// a check on Discover once the wallpaper is in the library, the green trophy for a wallpaper
// Wallpaper Engine staff approved, and a heart for one of the user's favorites. Approval comes
// from Steam's tag on Discover and from project.json in the library; favorites are the user's
// own list, so a Discover tile shows the heart too once its wallpaper is installed and loved.
const tileMarkGlyphs = { installed: ['check', 'In your library'], approved: ['trophy', 'Approved by Wallpaper Engine'], favorite: ['heart', 'Favorite'] };
function tileMarkNames(item, discover) {
  const names = [];
  if (discover && state.wallpapers.some(wallpaper => wallpaper.id === item.id)) names.push('installed');
  if (item.approved) names.push('approved');
  if (state.favorites.includes(item.id)) names.push('favorite');
  return names;
}
function tileMarksMarkup(item, discover) {
  const names = tileMarkNames(item, discover);
  return names.length ? `<span class="tile-marks">${names.map(name => `<span class="tile-mark ${name}" title="${escapeHTML(t(tileMarkGlyphs[name][1]))}">${icon(tileMarkGlyphs[name][0], 12)}</span>`).join('')}</span>` : '';
}
// A Discover tile wears its download state as a ring over the still, the way Wallpaper Engine's
// own library does: live progress while transferring, one click to cancel, a shield when Steam
// needs the user, and a retry mark after a failure. Once the wallpaper is in the library the
// tile's corner marks carry the check instead.
function tileDownloadMarkup(item) {
  const request = requestByID(item.id);
  const job = jobByID(item.id);
  if (request) return tileRing({ kind: 'attention', glyph: 'shield', action: 'continueSetup', id: item.id, label: t('Continue setup to download {title}', { title: item.title }) });
  if (job?.pending) {
    if (job.queued) return tileRing({ kind: 'queued', glyph: 'download', hoverGlyph: 'close', action: 'downloadCancel', id: item.id, label: t('{title} is waiting to download. Click to remove it from the queue', { title: item.title }) });
    if (job.prompt || job.challenge) return tileRing({ kind: 'attention', glyph: 'shield', action: 'continueSetup', id: item.id, label: t('Finish the Steam sign-in to download {title}', { title: item.title }) });
    const percent = Number.isFinite(job.progress) ? Math.round(clamp(job.progress) * 100) : null;
    const pace = speed(job.bytesPerSecond);
    const phase = phaseWord(job.phase);
    const progressText = percent === null ? job.status || t('Downloading') : t('Downloading {percent}%', { percent });
    // Bytes only move once Steam has been contacted, signed in and asked for the item. Until then
    // the ring sweeps and the phase word inside names that step, so the wait never reads as a stall;
    // a transfer that is measuring but has no percentage yet shows its speed instead. After the
    // last byte, "Finishing" replaces a frozen 100% while the files are validated and imported.
    const finishing = job.phase === 'finishing' && percent === 100;
    const word = finishing ? phase : percent === null && (job.phase !== 'transferring' || !pace) ? phase : '';
    return tileRing({ kind: percent === null ? 'busy' : 'progress', progress: percent === null ? null : clamp(job.progress), text: word || (percent === null ? '' : `${percent}%`), word: !!word, speed: pace, phase: job.phase, hoverGlyph: 'close', action: 'downloadCancel', id: item.id, label: t('{progress}: {title}. Click to cancel', { progress: pace ? t('{progress} at {speed}', { progress: progressText, speed: pace }) : progressText, title: item.title }) });
  }
  if (job && needsReview(job)) return tileRing({ kind: 'failed', glyph: 'refresh', action: 'downloadRetry', id: item.id, label: t('{error} Click to try again', { error: job.error || t('Download cancelled.') }), disabled: !state.setup?.ready });
  return '';
}
// pathLength="100" makes the dash offset a percentage, and the busy sweep travels by dash offset rather
// than a rotate() transform: rotating a layer whose centre lands between pixels shimmers in WebKit.
function tileRing({ kind, glyph = '', hoverGlyph = '', progress = null, text = '', word = false, speed: pace = '', phase = '', action, id, label, disabled: off = false }) {
  const dashOffset = kind === 'busy' ? 100 : progress === null ? 0 : 100 * (1 - progress);
  const value = kind === 'progress' || kind === 'busy' ? `<circle class="ring-value" cx="36" cy="36" r="32" pathLength="100" stroke-dasharray="${kind === 'busy' ? '26 74' : '100'}" stroke-dashoffset="${dashOffset.toFixed(1)}" transform="rotate(-90 36 36)"/>` : '';
  const copy = text || pace ? `<span class="ring-copy"><span class="ring-label${word ? ' ring-phase' : ''}">${escapeHTML(text)}</span>${pace ? `<span class="ring-speed">${escapeHTML(pace)}</span>` : ''}</span>` : `<span class="ring-label">${glyph ? icon(glyph, 18) : ''}</span>`;
  return `<button type="button" class="tile-download ${kind}" data-action="${action}" data-id="${escapeHTML(id)}"${phase ? ` data-phase="${escapeHTML(phase)}"` : ''} aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}"${disabled(off)}><svg class="ring" viewBox="0 0 72 72" aria-hidden="true"><circle class="ring-track" cx="36" cy="36" r="32"/>${value}</svg>${copy}${hoverGlyph ? `<span class="ring-hover">${icon(hoverGlyph, 18)}</span>` : ''}</button>`;
}
// One short word per SteamCMD step, sized to sit inside the ring; the full sentence stays in the
// tooltip, the inspector and the downloads list.
const phaseWords = { preparing: 'Preparing', connecting: 'Connecting', updating: 'Updating', signingIn: 'Signing in', requesting: 'Requesting', transferring: 'Downloading', finishing: 'Finishing' };
const phaseWord = (phase) => phaseWords[phase] ? t(phaseWords[phase]) : '';
// Double-clicking a Discover tile downloads it; once it is in the library the same gesture applies it.
function tileDoubleClickAction(id) {
  if (state.wallpapers.some(item => item.id === id)) {
    const target = state.displays.find(display => display.id === state.targetDisplayID);
    const kind = state.wallpapers.find(item => item.id === id)?.kind;
    return !['Application', 'Unknown'].includes(kind) && target?.enabled && target.mode !== 'mirror' && !state.busy ? 'activate' : 'workshopSelect';
  }
  if (jobByID(id)?.pending) return 'workshopSelect';
  return requestByID(id) ? 'continueSetup' : 'requestDownload';
}

// GitHub's new-issue form, pre-filled with the wallpaper so a report names what failed. Nothing
// is sent from here: the browser opens the draft and the user decides whether to submit it.
function issueLink(item) {
  const repository = safeLink(state.repositoryURL);
  if (!repository) return '';
  const url = new URL(`${repository.replace(/\/$/, '')}/issues/new`);
  const workshop = /^\d+$/.test(item.id) ? `https://steamcommunity.com/sharedfiles/filedetails/?id=${item.id}` : item.id;
  url.searchParams.set('title', `[${item.kind}] ${item.title}`);
  url.searchParams.set('body', [`**Wallpaper:** ${item.title}`, `**Workshop item:** ${workshop}`, `**Type:** ${item.kind}`, `**App version:** ${state.version || 'unknown'}`, '', '**What went wrong?**', '', ''].join('\n'));
  return url.href;
}

function renderInspector(discover) {
  const item = discover ? state.workshop.items.find(item => item.id === state.workshop.selectedID) : state.wallpapers.find(item => item.id === state.selectedID);
  if (!item) { morph($('inspector'), `<div class="inspector-empty"><h2>${escapeHTML(t('Select a wallpaper'))}</h2><p>${escapeHTML(t('Preview, details and options appear here.'))}</p></div>`); return; }
  const isInstalled = state.wallpapers.some(wallpaper => wallpaper.id === item.id);
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  const canActivate = isInstalled && !['Application', 'Unknown'].includes(item.kind) && target?.enabled && target.mode !== 'mirror';
  const download = state.downloads.find(download => download.id === item.id);
  const request = requestByID(item.id);
  const percent = Number.isFinite(download?.progress) ? Math.round(clamp(download.progress) * 100) : null;
  const downloadAction = request
    ? button(t('Continue setup'), 'continueSetup', { id: request.id }, { icon: 'shield', className: 'primary' })
    : download?.pending
      ? `${download.prompt || download.challenge ? button(t('Finish sign-in'), 'continueSetup', { id: item.id }, { icon: 'shield', className: 'primary' }) : button(download.queued ? t('Waiting to download') : percent === null ? t('Downloading') : t('Downloading {percent}%', { percent }), 'openDownloads', {}, { icon: 'download', className: 'primary' })}${button(download.queued ? t('Remove from queue') : t('Cancel'), 'downloadCancel', { id: item.id }, { className: 'quiet' })}`
      : button(download?.error ? t('Download again') : t('Download'), 'requestDownload', { id: item.id }, { icon: 'download', className: 'primary' });
  const options = !discover && state.options?.id === item.id ? state.options : null;
  const compatibility = { Scene: t('Scene renderer is experimental.'), Video: t('Playback depends on the video codec.'), Web: t('Runs in a built-in web view. Mouse input and audio response reach the page; keyboard input does not.'), Application: t('Application wallpapers cannot run on macOS.'), Unknown: t('This wallpaper type is not supported.') }[item.kind] || '';
  const meta = [t(item.kind), bytes(item.size), discover && Number.isFinite(item.subscriptions) ? t('{count} subscribers', { count: item.subscriptions.toLocaleString() }) : ''].filter(Boolean).map(escapeHTML).join('<span aria-hidden="true"> · </span>');
  const report = issueLink(item);
  const secondary = `${discover ? button(t('View on Steam Workshop'), 'openExternal', { url: `https://steamcommunity.com/sharedfiles/filedetails/?id=${encodeURIComponent(item.id)}` }, { icon: 'external', className: 'wide' }) : isInstalled ? button(t('Show in Finder'), 'reveal', { id: item.id }, { icon: 'folder', className: 'wide' }) : ''}${!discover && isInstalled ? button('', 'favorite', { id: item.id }, { icon: 'heart', title: state.favorites.includes(item.id) ? t('Remove from favorites') : t('Add to favorites'), className: `icon-button${state.favorites.includes(item.id) ? ' favorite-selected' : ''}` }) : ''}${!discover && isInstalled ? button('', 'delete', { id: item.id }, { icon: 'trash', className: 'icon-button danger', title: t('Move wallpaper to Trash'), disabled: state.busy }) : ''}${report ? button('', 'openExternal', { url: report }, { icon: 'triangleAlert', className: 'icon-button', title: t('Report a problem on GitHub') }) : ''}`;
  const showInLibrary = discover && isInstalled && !(download && !download.pending && !download.error) ? button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' }) : '';
  morph($('inspector'), `<div ${keyAttr(`inspector-${item.id}-${discover}`)}><div class="inspector-heading"><div class="inspector-preview">${preview(item.preview)}</div><h2>${escapeHTML(item.title)}</h2>${discover && item.creator ? `<p class="inspector-creator">${escapeHTML(item.creator)}</p>` : ''}<p class="inspector-meta">${meta}</p>${tags(item.tags)}<div class="actions inspector-actions">${isInstalled ? button(target?.wallpaperID === item.id ? t('Reapply wallpaper') : t('Apply wallpaper'), 'activate', { id: item.id }, { icon: 'play', className: 'primary', disabled: !canActivate || state.busy }) : downloadAction}${secondary}</div>${!isInstalled && download?.pending && !download.queued ? `<progress class="inspector-progress" max="1"${Number.isFinite(download.progress) ? ` value="${clamp(download.progress)}"` : ''} aria-label="${escapeHTML(t('{title} download progress', { title: item.title }))}"></progress><p class="muted"><small>${escapeHTML(download.status)}${transfer(download, { includePercent: false }) ? ` · ${transfer(download, { includePercent: false })}` : ''}</small></p>` : ''}${request ? `<p class="muted"><small>${escapeHTML(stageHint(request.stage))}</small></p>` : ''}${!isInstalled && download?.error && !download.pending ? `<p class="notice error">${escapeHTML(download.error)}</p>` : ''}${isInstalled && download && !download.pending && !download.error ? button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' }) : ''}${download || request ? button(t('Show in downloads'), 'openDownloads', {}, { className: 'link' }) : ''}${compatibility ? `<p class="muted"><small>${escapeHTML(compatibility)}</small></p>` : ''}${item.kind === 'Scene' && !state.settings.sceneAssetsReady ? `<div class="notice warning">${escapeHTML(t('Shared scene resources are required before playback.'))}${button(t('Get shared resources'), 'requestAssets', {}, { className: 'link' })}</div>` : ''}${showInLibrary}</div>${discover ? (item.summary ? `<section class="inspector-section"><p>${escapeHTML(item.summary)}</p></section>` : '') : `${options ? renderOptions(options) : `<section class="inspector-section"><p class="muted">${escapeHTML(t('Loading wallpaper options…'))}</p></section>`}`}</div>`);
}
const draftKey = (id, propertyID) => `${id}\u0000${propertyID}`;
// The audio and media status lines report the user's own setting and what it does not
// promise. Whether a page registered a listener, and whether the system will report what
// is playing, are facts the wallpaper host holds and the panel has no way to read, so
// neither is asserted here and nothing stands in for them.
function renderAudioAndMedia(options, lock) {
  const id = options.id;
  const web = options.kind === 'Web';
  const check = (key, label, on) => `<label class="check-label"><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="${escapeHTML(key)}"${checked(on)}${disabled(lock)}>${escapeHTML(label)}</label>`;
  const note = (text) => `<p class="muted"><small>${escapeHTML(text)}</small></p>`;
  const status = (text) => `<p class="muted" role="status"><small>${escapeHTML(text)}</small></p>`;
  // Three distinct things: the user's setting, whether the page asked for data,
  // and whether anything can answer. Never collapse them into one sentence.
  const delivering = options.audioDelivering;
  const audioStatus = !options.audioResponseEnabled
    ? t('Off. No audio is captured for this wallpaper.')
    : !web
      ? t('On for this wallpaper. Scenes that declare audio-reactive layers respond; the rest are unaffected.')
      : delivering === true
        ? t('On, and the wallpaper has registered an audio listener. Spectrum data is being delivered to the page.')
        : delivering === false
          ? t('On, but this wallpaper has not registered an audio listener, so it receives nothing. That is the wallpaper\u2019s choice, not a fault.')
          : t('On for this wallpaper. Delivery starts only once the wallpaper registers an audio listener; with no desktop wallpaper running, the panel cannot tell whether it has.');
  const media = !(web || options.kind === 'Scene') ? '' : check('mediaIntegrationEnabled', t('Media integration'), options.mediaIntegrationEnabled)
    + note(t('Share song titles, artists and artwork from system Now Playing. Supports Spotify, Apple Music and compatible browsers and local players.'))
    + status(!options.mediaIntegrationEnabled
      ? t('Off. The wallpaper is told media integration is disabled and receives no media events.')
      : options.mediaAvailable === true
        ? t('On, and a media source is available. Only fields the system actually reports are sent; nothing is substituted for the rest.')
        : options.mediaAvailable === false
          ? t('On, but no media source is available: {reason} The wallpaper is told nothing rather than being given a placeholder track.', { reason: options.mediaUnavailableReason || t('the system declined to report what is playing.') })
          : t('On for this wallpaper. With no desktop wallpaper running, the panel cannot tell whether a media source is available.'));
  return check('audioResponseEnabled', t('Audio response'), options.audioResponseEnabled)
    + note(t('Reactive wallpapers use sound playing in other apps. macOS may request system audio recording permission.'))
    + status(audioStatus)
    + media;
}
function renderOptions(options) {
  const id = options.id;
  const lock = state.busy || busy('apply', { id }) || busy('revert', { id });
  const changed = options.dirty || [...drafts.keys()].some(key => key.startsWith(`${id}\u0000`));
  return `${!options.supported ? `<section class="inspector-section"><p class="notice warning">${escapeHTML(t('This wallpaper cannot be rendered on this Mac.'))}</p></section>` : ''}<section class="inspector-section"><details open ${keyAttr(`general-${id}`)}><summary>${escapeHTML(t('General configuration'))}${icon('chevronRight', 14)}</summary><div class="section-content"><label class="check-label"><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="muted"${checked(options.muted)}${disabled(lock)}>${escapeHTML(t('Mute wallpaper audio'))}</label><div class="field"><label for="wallpaper-volume">${escapeHTML(t('Volume'))}</label><div class="range-field"><input id="wallpaper-volume" type="range" min="0" max="100" step="1" value="${Number(options.volume) * 100}" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="volume"${disabled(lock || options.muted)}><output>${Math.round(options.volume * 100)}%</output></div></div>${renderAudioAndMedia(options, lock)}</div></details></section><section class="inspector-section"><details open ${keyAttr(`displays-${id}`)}><summary>${escapeHTML(t('Displays'))}${icon('chevronRight', 14)}</summary><div class="section-content">${(options.displays || []).map(display => `<details class="display-options" open ${keyAttr(display.id)}><summary>${escapeHTML(display.title)}${icon('chevronRight', 13)}</summary><div class="section-content"><label class="check-label"><input type="checkbox" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="enabled"${checked(display.enabled)}${disabled(lock)}>${escapeHTML(t('Enabled'))}</label><label class="field">${escapeHTML(t('Scaling mode'))}<select data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingMode"${disabled(lock)}>${selectOptions([['none', t('Original size')], ['stretch', t('Stretch')], ['match', t('Fit')], ['fill', t('Fill')]], display.scalingMode)}</select></label><label class="field">${escapeHTML(t('Scale factor'))}<input type="number" min="${Number.MIN_VALUE}" step="any" value="${Number(display.scalingFactor)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingFactor"${disabled(lock)}></label><label class="field">${escapeHTML(t('Frame rate'))}<input type="number" min="1" max="${Number(display.maxFps) || 240}" step="1" value="${Number(display.fps)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="fps"${disabled(lock)}></label>${button(t('Remove from display'), 'eject', { id, displayID: display.id }, { className: 'link', disabled: lock })}</div></details>`).join('') || `<p class="muted">${escapeHTML(t('Apply this wallpaper to a display to configure playback.'))}</p>`}</div></details></section>${options.properties?.length ? `<section class="inspector-section"><details open ${keyAttr(`properties-${id}`)}><summary>${escapeHTML(t('Wallpaper properties'))}${icon('chevronRight', 14)}</summary><div class="section-content">${options.properties.map(property => renderProperty(id, property, lock)).join('')}</div></details></section>` : ''}<div class="inspector-save"><p>${escapeHTML(changed ? t('You have unapplied changes.') : t('Audio, scaling mode and frame rate update immediately.'))}</p>${button(t('Revert'), 'revert', { id }, { disabled: lock || !changed })}${button(t('Apply changes'), 'apply', { id }, { className: 'primary', disabled: lock || !changed || !options.supported })}</div>`;
}
// A `file` or `directory` property is a path the user picked, not a value typed into the
// page: the field is read-only and carries the display name, never the staged path the
// wallpaper actually reads. Every part of it — name, accepted types, staging failure —
// is attacker-influenced, so it goes through escapeHTML like everything else here.
function assetProperty(id, property, fieldID, unavailable, name) {
  const directory = property.kind === 'directory';
  const chosen = property.fileName || '';
  const empty = directory ? t('No folder chosen') : t('No file chosen');
  const types = (property.fileTypes || []).join(', ');
  const count = Number(property.fileCount);
  const limit = Number(property.fileLimit);
  const notes = [];
  // Both lines describe the folder, never an import outcome: a failed link or copy is
  // skipped and logged by the importer, so the staged count can be under the cap.
  if (types) notes.push(directory ? t('Uses {types} files from the chosen folder.', { types }) : t('Accepts {types}.', { types }));
  if (directory && chosen) {
    if (Number.isFinite(count)) {
      notes.push(property.truncated && Number.isFinite(limit)
        ? t('More than {limit} files match; only the first {limit} are used.', { limit })
        : t(count === 1 ? '{count} matching file in this folder.' : '{count} matching files in this folder.', { count }));
    } else {
      notes.push(t('This folder could not be read. Choose it again, or pick another.'));
    }
    notes.push(property.directoryMode === 'fetchAll'
      ? t('The wallpaper receives the whole list of files.')
      : t('The wallpaper picks files from the folder itself.'));
  }
  const missing = chosen && property.assetMissing === true;
  // Where the file lives now. A missing asset is the one state the user has to
  // act on, so it gets a visible alert and the picker, and the where-it-lives
  // note is dropped: telling someone an asset is safely copied and also gone
  // reads as a contradiction rather than as two facts.
  if (chosen && !missing && property.assetManaged === true) {
    notes.push(t('Copied into this app’s managed folder, so it survives cache cleans and wallpaper updates.'));
  } else if (chosen && !missing && property.assetManaged === false) {
    notes.push(property.assetSourcePath
      ? t('Used in place from {path}. Moving or deleting it there breaks the wallpaper.', { path: property.assetSourcePath })
      : t('Used in place from where you chose it. Moving or deleting it there breaks the wallpaper.'));
  }
  return `<input type="text" id="${escapeHTML(fieldID)}" class="asset-value" readonly value="${escapeHTML(chosen || empty)}">`
    + `<div class="actions">${button(missing ? t('Reselect…') : t('Choose…'), 'choosePropertyPath', { id, propertyID: property.id }, { icon: 'folder', title: directory ? t('Choose a folder for {name}', { name }) : t('Choose a file for {name}', { name }), disabled: unavailable })}`
    + `${button(t('Clear'), 'clearPropertyPath', { id, propertyID: property.id }, { title: t('Clear {name}', { name }), disabled: unavailable || !chosen })}</div>`
    + (missing ? `<p class="notice warning" role="alert">${escapeHTML(property.assetSourcePath ? (directory ? t('Missing — this folder is no longer at {path}. Reselect it.', { path: property.assetSourcePath }) : t('Missing — this file is no longer at {path}. Reselect it.', { path: property.assetSourcePath })) : (directory ? t('Missing — this folder can no longer be found. Reselect it.') : t('Missing — this file can no longer be found. Reselect it.')))}</p>` : '')
    + notes.map(note => `<p class="muted"><small>${escapeHTML(note)}</small></p>`).join('')
    + (property.error ? `<p class="notice error" role="alert">${escapeHTML(property.error)}</p>` : '');
}
function renderProperty(id, property, lock) {
  const name = property.label || property.id;
  const fieldID = `property-${encodeURIComponent(id)}-${encodeURIComponent(property.id)}`;
  const value = drafts.has(draftKey(id, property.id)) ? drafts.get(draftKey(id, property.id)) : property.value;
  const unavailable = lock || property.enabled === false || busy('property', { id, propertyID: property.id });
  const attributes = `id="${escapeHTML(fieldID)}" data-change="property" data-id="${escapeHTML(id)}" data-property-id="${escapeHTML(property.id)}"${disabled(unavailable)}`;
  let control;
  switch (property.kind) {
    case 'boolean': control = `<label class="check-label"><input type="checkbox" ${attributes}${checked(value)}>${escapeHTML(t('Enabled'))}</label>`; break;
    case 'slider': control = `<div class="range-field"><input type="range" ${attributes} min="${Number(property.min ?? 0)}" max="${Number(property.max ?? 100)}" step="${Number(property.step) > 0 ? Number(property.step) : 'any'}" value="${Number(value)}"><output>${escapeHTML(value)}</output></div>`; break;
    case 'combo': control = `<select ${attributes}>${(property.options || []).map(option => `<option value="${escapeHTML(JSON.stringify(option.value))}"${JSON.stringify(value) === JSON.stringify(option.value) ? ' selected' : ''}>${escapeHTML(t(option.label))}</option>`).join('')}</select>`; break;
    case 'color': control = `<input type="color" ${attributes} value="${/^#[0-9a-f]{6}$/i.test(value) ? value : '#ffffff'}">`; break;
    case 'textInput': control = `<input type="text" ${attributes} data-input="property" value="${escapeHTML(value)}" autocomplete="off">`; break;
    // A scene texture is not a user-chosen file: it keeps the image picker it always had.
    case 'texture': control = `<p class="file-value">${escapeHTML(value || t('No image selected'))}</p><div class="actions">${button(t('Choose image'), 'choosePropertyFile', { id, propertyID: property.id }, { icon: 'folder', disabled: unavailable })}${value ? button(t('Clear'), 'clearProperty', { id, propertyID: property.id }, { disabled: unavailable }) : ''}</div>`; break;
    case 'file': case 'directory': control = assetProperty(id, property, fieldID, unavailable, name); break;
    case 'text': return `<p ${keyAttr(property.id)} class="muted">${escapeHTML(name)}${value && value !== name ? `<br>${escapeHTML(value)}` : ''}</p>`;
    default: return `<p ${keyAttr(property.id)} class="muted">${escapeHTML(t('{name}: unsupported property type.', { name }))}</p>`;
  }
  return `<div ${keyAttr(property.id)} class="field${property.dirty || drafts.has(draftKey(id, property.id)) ? ' modified' : ''}"><div class="field-title"><label for="${escapeHTML(fieldID)}">${escapeHTML(name)}</label>${property.defaultValue !== undefined && property.defaultValue !== null ? button(t('Reset'), 'restoreProperty', { id, propertyID: property.id }, { className: 'link', title: t('Restore default: {name}', { name }), disabled: unavailable }) : ''}</div>${control}</div>`;
}

const clamp = (value) => Math.max(0, Math.min(1, Number(value)));
const requestByID = (id) => (state?.downloadRequests || []).find(request => request.id === id);
const jobByID = (id) => (state?.downloads || []).find(item => item.id === id);
const stageHint = (stage) => t({ setup: 'Waiting for SteamCMD setup.', account: 'Waiting for your Steam sign-in.', resources: 'Waiting for your go-ahead on shared resources.', ready: 'Starting…' }[stage] || 'Waiting to continue.');
const stageTitle = (stage) => t({ setup: 'Install SteamCMD', account: 'Sign in to Steam', resources: 'Shared resources needed', ready: 'Starting download' }[stage] || 'Continue this download');
const strong = (text) => `<b>${escapeHTML(text)}</b>`;
// Steam Guard stages are explained as an icon, a one-line title and numbered steps, so the person
// knows which device to pick up and what to press. A plain password prompt needs no guide: the
// labelled field and the footer note say everything.
function signInGuide(job, account) {
  const who = strong(account || t('your account'));
  // Steps are inserted as markup so the bold cues survive; the bold text itself is escaped by strong().
  const guides = {
    mobileApproval: { icon: 'smartphone', title: t('Approve the sign-in on your phone'), steps: [
      t('Open the Steam app on your phone and tap {guard}, the shield tab at the bottom.', { guard: strong(t('Steam Guard')) }),
      t('A request to sign in as {account} is waiting there. Approve it.', { account: who }),
      t('If Steam asks {question}, choose {client}. This app signs in through Valve’s SteamCMD, which counts as the Steam client.', { question: strong(t('Where are you trying to sign in?')), client: strong(t('Steam Client')) }),
      t('Come back here. This dialog continues by itself once Steam confirms.'),
    ], note: t('Only approve a request you just started. Deny anything you do not recognise.'), phone: true },
    authenticatorCode: { icon: 'smartphone', title: t('Enter the code from the Steam app'), steps: [
      t('Open the Steam app on your phone and tap {guard}, the shield tab at the bottom.', { guard: strong(t('Steam Guard')) }),
      t('Read the five-character code shown at the top. It changes every 30 seconds.'),
      t('Type it below and submit before it changes. If it has already changed, use the new one.'),
    ], note: t('Codes never need to be shared with anyone; enter them only in this dialog.'), phone: true },
    emailCode: { icon: 'mail', title: t('Enter the code Steam emailed you'), steps: [
      t('Check the inbox of the email address registered to this Steam account. Look in spam or junk too.'),
      t('Open the newest Steam Guard message. Every sign-in attempt sends a fresh code, so older ones no longer work.'),
      t('Type the five-character code below and submit it.'),
    ], note: t('Steam never asks for your password by email. Enter the code only here.'), mail: true },
    unknown: { icon: 'shield', title: t('Verify with the method Steam requested'), steps: [
      t('Follow the verification Steam asked for in its app or email, then continue here.'),
      t('Never disable Steam Guard or share passwords or recovery codes.'),
    ], phone: true },
  };
  if (job.challenge) return guides[job.challenge] || guides.unknown;
  return job.prompt && !job.securePrompt ? guides.unknown : null;
}
const guideMarkup = (guide, extra = '') => `<section class="dialog-guide" aria-label="${escapeHTML(guide.title)}"><span class="dialog-guide-icon">${icon(guide.icon, 20)}</span><div class="dialog-guide-body"><p class="dialog-guide-title" role="status">${escapeHTML(guide.title)}</p>${guide.steps?.length ? `<ol class="dialog-steps">${guide.steps.map(step => `<li><span>${step}</span></li>`).join('')}</ol>` : ''}${guide.note ? `<p class="dialog-guide-note">${escapeHTML(guide.note)}</p>` : ''}${extra}</div></section>`;
function queueState() {
  // A finished sign-in-only session is not a download; it only shows while it is running.
  const downloads = (state.downloads || []).filter(item => item.id !== SIGN_IN_ID || item.pending);
  const requests = state.downloadRequests || [];
  const active = downloads.filter(item => item.pending && !item.queued);
  const queued = downloads.filter(item => item.pending && item.queued);
  const attention = downloads.filter(item => item.prompt || item.challenge || item.error);
  // Several downloads can run at once: the activity bar carries one job's own figures, or the
  // batch's mean progress and summed speed once more than one is running.
  const running = active[0];
  const measured = active.filter(item => Number.isFinite(item.progress));
  const progress = measured.length ? clamp(measured.reduce((sum, item) => sum + clamp(item.progress), 0) / measured.length) : null;
  const percent = progress === null ? null : Math.round(progress * 100);
  const speed = active.reduce((sum, item) => sum + (Number.isFinite(item.bytesPerSecond) ? item.bytesPerSecond : 0), 0);
  const count = requests.length + active.length + queued.length;
  const summary = active.length > 1 ? [t('{count} downloading', { count: active.length }), percent !== null ? `${percent}%` : '', speed > 0 ? rate(speed) : ''].filter(Boolean).join(' · ') : running ? [running.status || t('Downloading'), percent !== null ? `${percent}%` : '', rate(running.bytesPerSecond)].filter(Boolean).join(' · ') : requests.length ? t(requests.length === 1 ? '{count} download needs setup' : '{count} downloads need setup', { count: requests.length }) : queued.length ? t('{count} waiting to download', { count: queued.length }) : downloads.length ? t(downloads.length === 1 ? '{count} download' : '{count} downloads', { count: downloads.length }) : t('No downloads');
  return { downloads, requests, active, queued, attention, progress, percent, count, summary };
}
function queueButton() {
  const { downloads, requests, attention, count, summary } = queueState();
  // Tiles and the activity bar carry download state; the top-bar button only appears once there is a list to open.
  if (!downloads.length && !requests.length) return '';
  const label = t('Downloads: {summary}', { summary: attention.length ? t('{summary} · needs attention', { summary }) : summary });
  return `<button type="button" data-action="openDownloads" class="quiet icon-button queue-button" aria-haspopup="dialog" aria-expanded="${popover === 'downloads'}" title="${escapeHTML(label)}" aria-label="${escapeHTML(label)}">${icon('download')}${count ? `<span class="queue-badge${attention.length ? ' attention' : ''}" aria-hidden="true">${count}</span>` : ''}</button>`;
}
function renderActivity() {
  const { summary, attention, active, progress } = queueState();
  const transferring = active.filter(item => !item.authenticating);
  const label = transferring.length === 1 ? t('{title} download progress', { title: transferring[0].title }) : t('{count} downloads progress', { count: transferring.length });
  morph($('activity-bar'), `<div class="activity-left">${button('', 'playback', {}, { icon: state.paused ? 'play' : 'pause', title: state.paused ? t('Resume wallpaper playback') : t('Pause wallpaper playback'), className: 'quiet icon-button', disabled: state.busy || !(state.wallpapers || []).some(item => item.active) })}<span class="activity-copy">${escapeHTML(state.paused ? t('Playback paused') : t('Playback running'))}</span></div><div class="activity-right">${state.import?.busy ? button(state.import.status || t('Importing…'), 'openImport', {}, { icon: 'folder', className: 'quiet' }) : ''}${state.setup?.busy ? `<span class="activity-copy">${escapeHTML(t('Setting up SteamCMD…'))}</span>` : ''}${transferring.length ? `<progress class="activity-progress" max="1"${progress !== null ? ` value="${progress}"` : ''} aria-label="${escapeHTML(label)}"></progress>` : ''}${button(attention.length ? t('{summary} · needs attention', { summary }) : summary, 'openDownloads', {}, { icon: 'download', className: 'quiet' })}</div>`);
}
function previewThumb(url) {
  const source = safeImage(url);
  return `<span class="thumb-placeholder">${icon('image', 15)}</span>${source ? `<img ${keyAttr(source)} src="${escapeHTML(source)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer">` : ''}`;
}
function renderPopover() {
  const queue = $('queue-popover');
  const importer = $('import-popover');
  queue.hidden = popover !== 'downloads';
  importer.hidden = popover !== 'import';
  if (popover === 'downloads') morph(queue, queueMarkup());
  if (popover === 'import') morph(importer, importMarkup());
  if (popover) placePopover(popover === 'downloads' ? queue : importer);
}
function queueMarkup() {
  const { downloads, requests } = queueState();
  const active = downloads.filter(item => item.pending);
  // A failed or cancelled download is unfinished business: it stays visible with its recovery action.
  const unresolved = downloads.filter(item => !item.pending && needsReview(item));
  const succeeded = downloads.filter(item => !item.pending && !needsReview(item));
  const rows = [...requests.map(queueRequestRow), ...active.map(queueJobRow), ...unresolved.map(queueJobRow), ...(queueExpanded ? succeeded.map(queueJobRow) : [])].join('');
  const empty = succeeded.length ? t('Every download finished. Nothing needs you.') : t('No downloads yet. Pick a Workshop wallpaper and choose Download.');
  return `<div class="popover-heading"><h2 id="queue-popover-title">${escapeHTML(t('Downloads'))}</h2>${button('', 'closePopover', {}, { icon: 'close', title: t('Close downloads'), className: 'quiet icon-button' })}</div>${rows ? `<ul class="queue-list">${rows}</ul>` : `<p class="queue-empty">${escapeHTML(empty)}</p>`}<div class="popover-footer"><p class="queue-note">${escapeHTML(queueNote())}</p><div class="actions">${succeeded.length ? button(queueExpanded ? t('Hide completed') : t('Show completed ({count})', { count: succeeded.length }), 'toggleQueueHistory', {}, { className: 'link' }) : ''}${downloads.length > active.length ? button(t('Clear finished'), 'clearDownloads', {}, { className: 'quiet' }) : ''}${button(t('Show download logs'), 'showLogs', {}, { icon: 'folder', className: 'link' })}</div></div>`;
}
const queueNote = () => {
  const slots = Number(state?.downloadSlots) || 1;
  return slots > 1 ? t('Up to {slots} downloads run at once and share your saved sign-in; the rest wait in order. Steam may still ask you to approve a sign-in.', { slots }) : t('Downloads run one at a time; the rest wait in order. Steam may still ask you to approve a sign-in.');
};
const needsReview = (item) => Boolean(item.error) || Boolean(item.cancelled);
function queueRequestRow(request) {
  return `<li class="queue-row attention" ${keyAttr(`request-${request.id}`)}><span class="queue-thumb">${previewThumb(request.thumbnail || request.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(request.title)}</p><p class="queue-status">${escapeHTML(stageHint(request.stage))}</p><div class="actions">${button(t('Continue setup'), 'continueSetup', { id: request.id }, { className: 'primary' })}${button('', 'removeDownloadRequest', { id: request.id }, { icon: 'close', title: t('Remove {title} from downloads', { title: request.title }), className: 'quiet icon-button' })}</div></div></li>`;
}
function queueJobRow(item) {
  const installedItem = (state.wallpapers || []).find(wallpaper => wallpaper.id === item.id);
  const percent = Number.isFinite(item.progress) ? Math.round(clamp(item.progress) * 100) : null;
  const running = item.pending && !item.queued;
  const needsAuth = running && Boolean(item.prompt || item.challenge);
  const review = !item.pending && needsReview(item);
  return `<li class="queue-row${needsAuth || review ? ' attention' : ''}" ${keyAttr(`job-${item.id}`)}><span class="queue-thumb">${previewThumb(item.thumbnail || item.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(item.title)}</p><p class="queue-status">${escapeHTML(item.status)}${running && transfer(item) ? ` · ${transfer(item)}` : ''}</p>${running ? `<progress max="1"${percent === null ? '' : ` value="${clamp(item.progress)}"`} aria-label="${escapeHTML(t('{title} download progress', { title: item.title }))}"></progress>` : ''}${item.error ? `<p class="notice error">${escapeHTML(item.error)}</p>` : ''}${item.warning ? `<p class="notice warning">${escapeHTML(item.warning)}</p>` : ''}<div class="actions">${needsAuth ? button(t('Finish sign-in'), 'continueSetup', { id: item.id }, { icon: 'shield', className: 'primary' }) : ''}${item.pending ? button(item.queued ? t('Remove from queue') : t('Cancel'), 'downloadCancel', { id: item.id }, { className: 'quiet' }) : ''}${review ? button(t('Try again'), 'downloadRetry', { id: item.id }, { icon: 'refresh', disabled: !state.setup?.ready }) : ''}${installedItem ? `${button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' })}${button(t('Show in Finder'), 'reveal', { id: item.id }, { icon: 'folder', className: 'link' })}` : ''}</div></div></li>`;
}
function importMarkup() {
  const status = state.import || {};
  const report = status.report;
  return `<div class="popover-heading"><h2 id="import-popover-title">${escapeHTML(t('Import wallpapers'))}</h2>${button('', 'closePopover', {}, { icon: 'close', title: t('Close import'), className: 'quiet icon-button' })}</div><div class="popover-body"><p class="muted">${escapeHTML(t('Choose wallpaper folders or files. Imports copy the source files into your library and leave the originals untouched.'))}</p><label class="field">${escapeHTML(t('If a wallpaper already exists'))}<select id="import-duplicates"${disabled(status.busy)}>${selectOptions([['skip', t('Skip duplicates')], ['keepBoth', t('Keep both copies')]], importDuplicates)}</select></label><div class="actions">${button(t('Choose wallpapers'), 'import', { duplicates: importDuplicates }, { icon: 'folder', className: 'primary', disabled: status.busy })}${status.busy ? button(t('Cancel import'), 'importCancel') : ''}</div>${status.status ? `<p class="muted" role="status">${escapeHTML(status.status)}</p>` : ''}${report ? `<div class="import-controls"><p>${escapeHTML(t('{imported} imported · {skipped} skipped', { imported: Number(report.imported), skipped: Number(report.skipped) }))}${report.cancelled ? escapeHTML(t(' · Cancelled')) : ''}</p>${(report.failures || []).map(failure => `<p class="notice error">${escapeHTML(failure)}</p>`).join('')}</div>` : ''}</div>`;
}
function placePopover(node) {
  const trigger = popoverTrigger ? document.querySelector(popoverTrigger) : null;
  const rect = trigger?.getBoundingClientRect();
  if (!rect) return;
  const width = node.offsetWidth;
  const height = node.offsetHeight;
  node.style.left = `${Math.round(Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8)))}px`;
  const below = rect.bottom + 6;
  if (below + height <= window.innerHeight - 8) { node.style.top = `${Math.round(below)}px`; node.style.bottom = 'auto'; }
  else { node.style.top = 'auto'; node.style.bottom = `${Math.round(Math.max(8, window.innerHeight - rect.top + 6))}px`; }
}
function triggerSelector(trigger) {
  const action = trigger?.dataset?.action;
  if (!action) return '';
  const host = ['#top-actions', '#activity-bar', '#browser-toolbar', '#inspector', '#queue-popover'].find(id => trigger.closest(id));
  return `${host ? `${host} ` : ''}[data-action="${action}"]`;
}
function openPopover(kind, trigger) {
  if (popover === kind) { closePopover(true); return; }
  popover = kind;
  queueExpanded = false;
  popoverTrigger = triggerSelector(trigger) || popoverTrigger;
  renderPopover();
  $(kind === 'downloads' ? 'queue-popover' : 'import-popover').focus();
}
function closePopover(restore) {
  if (!popover) return;
  const selector = popoverTrigger;
  popover = null;
  queueExpanded = false;
  renderPopover();
  if (restore && selector) document.querySelector(selector)?.focus();
}
function openDialog(id, trigger) {
  dialogTarget = id;
  dialogTrigger = triggerSelector(trigger) || dialogTrigger;
  seedAccount(id);
  closePopover(false);
  renderDialog();
}
// Each retained request owns its account, so switching requests can never submit another one's sign-in.
function seedAccount(id) {
  const request = requestByID(id);
  const job = jobByID(id);
  dialogAccount = { id, account: request?.account ?? job?.account ?? state?.account ?? state?.savedAccount ?? '', rememberSession: request?.rememberSession ?? Boolean(state?.rememberSession) };
}
function closeDialog() {
  const node = $('download-dialog');
  const selector = dialogTrigger;
  for (const job of (state?.downloads || [])) if (job.pending && (job.prompt || job.challenge)) dismissedAuth.add(authKey(job));
  dialogTarget = null;
  dialogTrigger = null;
  dialogAccount = null;
  dialogHandoff = null;
  clearTimeout(handoffTimer);
  if (node.open) node.close();
  morph(node, '');
  node.removeAttribute('data-stage');
  // Closing must not leave focus stranded on the body, and must not pull it away from wherever the user went.
  if (selector && (!document.activeElement || document.activeElement === document.body)) (document.querySelector(selector) || document.querySelector('#top-actions [data-action="openDownloads"]'))?.focus();
}
// The dialog only ever opens from an explicit request, so a later snapshot never reopens it.
function renderDialog() {
  const node = $('download-dialog');
  if (dialogTarget === null) return;
  const request = requestByID(dialogTarget);
  const own = jobByID(dialogTarget);
  // An explicitly opened dialog stays put while a job logs in — including the shared-resources job this intent waits behind.
  const pendingAuth = (job) => job?.pending && !job.queued && (job.authenticating || job.prompt || job.challenge) ? job : null;
  const auth = pendingAuth(own) || (request || own?.queued ? pendingAuth(jobByID('scene-assets')) : null);
  const waiting = request && request.stage !== 'ready' ? request : null;
  // The moment a sign-in completes the transfer is already running; say so instead of closing mid-thought.
  const running = (job) => job?.pending && !job.error && !pendingAuth(job) ? job : null;
  const started = !waiting && !auth && (node.dataset.stage === 'auth' || dialogHandoff === dialogTarget) ? (own?.queued && running(jobByID('scene-assets'))) || running(own) : null;
  if (!waiting && !auth && !started) { closeDialog(); return; }
  if (started && dialogHandoff !== dialogTarget) { dialogHandoff = dialogTarget; clearTimeout(handoffTimer); handoffTimer = setTimeout(() => { if (dialogHandoff === dialogTarget && dialogTarget !== null) closeDialog(); }, 6000); }
  if (dialogAccount?.id !== dialogTarget) seedAccount(dialogTarget);
  const stage = waiting ? waiting.stage : started ? 'started' : 'auth';
  const open = node.open;
  node.dataset.stage = stage;
  morph(node, dialogMarkup(stage, waiting || own || auth || started, auth || started));
  if (!open) {
    node.showModal();
    (node.querySelector('.dialog-body input:not([disabled]), .dialog-body button.primary:not([disabled]), .dialog-body button:not([disabled])') || node).focus();
  }
}
function dialogMarkup(stage, subject, auth) {
  const body = stage === 'setup' ? setupStep() : stage === 'account' ? accountStep() : stage === 'resources' ? resourcesStep() : stage === 'started' ? startedStep(auth, subject) : authStep(auth);
  const title = stage === 'auth' ? auth.challenge ? t('Verify this Steam sign-in') : auth.prompt ? t('Sign in to Steam') : t('Connecting to Steam') : stage === 'started' ? t('Signed in to Steam') : stageTitle(stage);
  const subtitle = (stage === 'auth' || stage === 'started') && auth.id !== subject.id ? t('{auth} · needed for {subject}', { auth: auth.title, subject: subject.title }) : subject.title;
  return `<div class="dialog-head"><span class="dialog-thumb">${previewThumb(stage === 'auth' ? auth.thumbnail || auth.preview || subject.thumbnail || subject.preview : subject.thumbnail || subject.preview)}</span><div class="dialog-heading"><h2 id="download-dialog-title">${escapeHTML(title)}</h2><p class="muted">${escapeHTML(subtitle)}</p></div>${button('', 'dismissDialog', {}, { icon: 'close', title: t('Close without removing this download'), className: 'quiet icon-button' })}</div><div class="dialog-body" data-stage="${stage}">${body}</div>`;
}
function setupStep() {
  const setup = state.setup || {};
  const retained = setup.candidatePath ? setup.canApprove ? `<p class="notice">${escapeHTML(t('This downloaded copy needs your approval before it can run:'))}<br>${escapeHTML(setup.candidatePath)}</p>` : `<p class="notice warning">${escapeHTML(t('A downloaded copy is retained but not usable yet:'))}<br>${escapeHTML(setup.candidatePath)}</p>` : '';
  return `<p>${escapeHTML(t('SteamCMD is Valve’s download tool. Install it here, or point to a copy you already have. Installing it does not sign you in.'))}</p><p class="dialog-status" role="status">${escapeHTML(setup.status || (setup.ready ? t('SteamCMD is ready.') : t('SteamCMD is not installed yet.')))}</p>${setup.busy && Number.isFinite(setup.progress) ? `<progress max="1" value="${clamp(setup.progress)}" aria-label="${escapeHTML(t('SteamCMD installation progress'))}"></progress>` : ''}${setup.error ? `<p class="notice error">${escapeHTML(setup.error)}</p>` : ''}${retained}<div class="dialog-actions">${setup.canApprove ? button(t('Allow this SteamCMD'), 'setupApprove', {}, { icon: 'shield', className: 'primary', disabled: setup.busy }) : button(t('Install SteamCMD'), 'setupInstall', {}, { icon: 'download', className: 'primary', disabled: setup.busy })}${button(t('Locate a copy'), 'setupLocate', {}, { icon: 'folder', disabled: setup.busy })}${setup.busy && setup.canCancel !== false ? button(t('Cancel setup'), 'setupCancel') : ''}${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div>${setup.candidatePath ? `<div class="dialog-actions">${button(t('Show it in Finder'), 'setupRevealCandidate', {}, { icon: 'folder', className: 'link' })}${button(t('Discard it'), 'setupDiscardCandidate', {}, { className: 'link', disabled: setup.busy })}</div>` : ''}<p class="dialog-note">${escapeHTML(t('Approval applies only to the exact copy you allow. Gatekeeper and signature checks stay in force.'))}</p>`;
}
function accountStep() {
  const working = busy('continueDownload', { id: dialogTarget });
  return `<form class="dialog-form" data-form="dialogContinue" ${keyAttr('dialog-account')}><label class="field">${escapeHTML(t('Steam account name'))}<input data-input="account" type="text" autocomplete="username" autocapitalize="off" spellcheck="false" value="${escapeHTML(dialogAccount.account)}"${disabled(working)}></label><label class="check-label"><input type="checkbox" data-change="rememberSession"${checked(dialogAccount.rememberSession)}${disabled(working)}>${escapeHTML(t('Keep me signed in on this Mac'))}</label>${state.savedAccount ? `<p class="dialog-note">${escapeHTML(t('Saved sign-in on this Mac: {account}', { account: state.savedAccount }))}${dialogAccount.account.trim().toLowerCase() === String(state.savedAccount).trim().toLowerCase() ? escapeHTML(t(' · will be reused')) : ''}</p>` : ''}<div class="dialog-actions"><button type="submit" class="primary"${disabled(working || !dialogAccount.account.trim())}>${icon('chevronRight')}<span class="button-label">${escapeHTML(t('Continue'))}</span></button>${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div><p class="dialog-note">${escapeHTML(t('Your password and any Steam Guard code come next. This app never saves them.'))}</p></form>`;
}
// The resources stage is a choice, so each path is one button carrying its own title and the one
// fact that decides it, instead of a paragraph of caveats above a row of buttons.
const choiceButton = (action, args, glyph, title, note, off) => `<button type="button" class="dialog-choice" data-action="${action}" ${Object.entries(args).map(([key, value]) => `data-${key}="${escapeHTML(value)}"`).join(' ')}${disabled(off)}><span class="dialog-guide-icon">${icon(glyph, 18)}</span><span class="dialog-choice-body"><span class="dialog-choice-title">${escapeHTML(title)}</span><span class="dialog-choice-note">${escapeHTML(note)}</span></span>${icon('chevronRight', 16)}</button>`;
function resourcesStep() {
  const settings = state.settings || {};
  const lead = settings.sceneAssetsReady ? t('Shared resources are already installed. Downloading again replaces them.') : t('Scene wallpapers need shaders and materials from Wallpaper Engine. This is a one-time setup.');
  return `<p${settings.sceneAssetsReady ? ' class="dialog-status" role="status"' : ''}>${escapeHTML(lead)}</p>${settings.sceneAssetsWarning ? `<p class="notice warning">${escapeHTML(settings.sceneAssetsWarning)}</p>` : ''}<div class="dialog-choices">${choiceButton('consentResources', { id: dialogTarget }, 'download', t('Download from Steam'), t('Needs a Steam account that owns Wallpaper Engine and several gigabytes free while downloading.'), busy('continueDownload', { id: dialogTarget }))}${choiceButton('locateAssets', {}, 'folder', t('Use an existing installation'), t('Already have Wallpaper Engine on a drive? Choose its folder and nothing downloads.'), state.setup?.busy)}</div><div class="dialog-actions end">${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div>`;
}
function authStep(job) {
  const working = busy('downloadInput', { id: job.id });
  const waiting = !job.prompt && !job.challenge;
  const account = job.account || dialogAccount?.account || '';
  const guide = signInGuide(job, account);
  const identity = `<div class="dialog-identity"><p>${icon('userRound', 14)}<span>${t('Signing in as {account}', { account: `<span class="dialog-account">${escapeHTML(account || t('an unnamed account'))}</span>` })}</span></p>${button(t('Change account'), 'changeAccount', { id: job.id }, { className: 'link' })}</div>`;
  const connecting = guideMarkup({ icon: 'logIn', title: job.status, note: t('Steam is being contacted. Any password or Steam Guard request appears here.') }, `<progress aria-label="${escapeHTML(t('Connecting to Steam'))}"></progress>`);
  const help = guide?.phone ? button(t('Get the Steam mobile app'), 'openExternal', { url: 'https://store.steampowered.com/mobile' }, { icon: 'external', className: 'link' }) : guide?.mail ? button(t('Help with emailed codes'), 'openExternal', { url: 'https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode' }, { icon: 'external', className: 'link' }) : '';
  return `${identity}${waiting ? connecting : guide ? guideMarkup(guide) : ''}${job.error ? `<p class="notice error">${escapeHTML(job.error)}</p>` : ''}${job.warning ? `<p class="notice warning">${escapeHTML(job.warning)}</p>` : ''}${job.prompt ? `<form class="dialog-form" data-form="dialogAuth" data-id="${escapeHTML(job.id)}" ${keyAttr(`auth-${job.id}-${job.prompt}`)}><label class="field" for="dialog-response">${escapeHTML(job.prompt)}<input id="dialog-response" name="response" type="${job.securePrompt ? 'password' : 'text'}" autocomplete="off" spellcheck="false" autocapitalize="off" required${disabled(working)}></label><div class="dialog-actions"><button type="submit" class="primary"${disabled(working)}>${icon(job.securePrompt ? 'lock' : 'keyRound')}<span class="button-label">${escapeHTML(t('Submit'))}</span></button>${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div></form>` : `<div class="dialog-actions">${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div>`}<div class="dialog-actions">${button(t('Cancel this download'), 'downloadCancel', { id: job.id }, { className: 'quiet' })}${help}</div><p class="dialog-note">${escapeHTML(t('Only approve sign-ins you started yourself. Never share your password or recovery codes.'))}</p>`;
}
// Sign-in complete: the download is already running, so the dialog says so with live progress
// instead of vanishing, then steps aside on its own.
function startedStep(job, subject) {
  const shared = job.id !== subject.id;
  const guide = job.id === SIGN_IN_ID
    ? { icon: 'check', title: t('Signed in to Steam'), note: t('Downloads will use this sign-in.') }
    : { icon: 'check', title: shared ? t('Signed in. Shared resources are downloading first') : t('Signed in. {title} is downloading', { title: subject.title }), note: shared ? t('{title} starts automatically once they are installed. You can keep using the app meanwhile.', { title: subject.title }) : t('You can keep using the app. Progress shows on the wallpaper and in the downloads list.') };
  const progress = Number.isFinite(job.progress) ? `<progress max="1" value="${clamp(job.progress)}" aria-label="${escapeHTML(t('Download progress'))}"></progress>` : `<progress aria-label="${escapeHTML(t('Download in progress'))}"></progress>`;
  return `${guideMarkup(guide, `<p class="dialog-status" role="status">${escapeHTML(job.status)}</p>${progress}`)}<div class="dialog-actions">${button(t('Done'), 'dismissDialog', {}, { icon: 'check', className: 'primary' })}${button(t('Show downloads'), 'showDownloadsFromDialog', {}, { icon: 'download', className: 'quiet' })}</div>`;
}
let importDuplicates = 'skip';
async function searchWorkshop() { clearTimeout(searchTimer); await send('workshopSearch', { ...workshopDraft, tags: [...workshopDraft.tags], excludedTags: [...workshopDraft.excludedTags] }); }
async function commitProperty(element) {
  const { id, propertyId } = element.dataset;
  let value = element.type === 'checkbox' ? element.checked : element.type === 'range' || element.type === 'number' ? Number(element.value) : element.tagName === 'SELECT' ? JSON.parse(element.value) : element.value;
  if (typeof value === 'number' && !Number.isFinite(value)) return;
  const key = draftKey(id, propertyId);
  drafts.set(key, value);
  await send('property', { id, propertyID: propertyId, value });
  if (drafts.get(key) === value) drafts.delete(key);
  render();
}
// One click keeps the intent: the native side retains the request and the dialog only collects what is still missing.
async function requestDownload(id, element) {
  await send('requestDownload', { id });
  const target = id === null ? 'scene-assets' : id;
  const request = requestByID(target);
  const job = jobByID(target);
  if (request && request.stage !== 'ready') openDialog(request.id, element);
  else if (job?.pending && !job.queued && (job.prompt || job.challenge)) openDialog(target, element);
}
const authKey = (job) => `${job.id}\u0000${job.prompt || job.challenge || ''}`;
// A password or Steam Guard request is the one thing a download cannot finish by itself, so it
// opens the dialog on its own. A saved sign-in never asks, so routine downloads stay on the tile.
function surfaceAuthRequests() {
  if (dialogTarget !== null || !state) return;
  // The welcome guide answers its own sign-in's prompts while it is open.
  const job = (state.downloads || []).find(item => item.pending && !item.queued && (item.prompt || item.challenge) && !(item.id === SIGN_IN_ID && welcome.isOpen()));
  if (job && !dismissedAuth.has(authKey(job))) openDialog(job.id, null);
}
async function continueDownload(includeResources) {
  const id = dialogTarget;
  if (!id) return;
  await send('continueDownload', { id, account: dialogAccount.account.trim(), rememberSession: dialogAccount.rememberSession, includeResources });
}
async function handleAction(action, data, element) {
  const id = data.id;
  switch (action) {
    case 'dismissError':
      localError = '';
      if (state) { state.error = null; state.downloadError = null; }
      renderError();
      // The native side owns bridge errors, so a dismissal must reach it or the next snapshot restores it.
      await send('dismissError');
      return;
    case 'openDownloads': openPopover('downloads', element); return;
    case 'showDownloadsFromDialog': { const trigger = dialogTrigger; closeDialog(); openPopover('downloads', document.querySelector('#top-actions [data-action="openDownloads"]') || (trigger ? document.querySelector(trigger) : null)); return; }
    case 'openImport': openPopover('import', element); return;
    case 'closePopover': closePopover(true); return;
    case 'toggleQueueHistory': queueExpanded = !queueExpanded; renderPopover(); return;
    case 'requestDownload': await requestDownload(id, element); return;
    case 'requestAssets': await requestDownload(null, element); return;
    case 'continueSetup': openDialog(id, element); return;
    case 'dismissDialog': closeDialog(); return;
    case 'consentResources': await continueDownload(true); return;
    // Native cancels this exact job and hands the same intent back at the account stage, so the dialog simply follows it.
    case 'changeAccount': await send('changeDownloadAccount', { id }); openDialog(id, element); return;
    case 'removeDownloadRequest': if (dialogTarget === id) closeDialog(); await send(action, { id }); return;
    case 'clearInstalledSearch': installed.text = ''; // falls through to reset filters
    case 'clearInstalled': installed.tags = []; installed.excludedTags = []; render(); return;
    case 'toggleSelect': toggleSelection(id); return;
    case 'toggleSelecting': selecting = !selecting; if (!selecting) { selection.clear(); selectionAnchor = null; } render(); return;
    case 'selectAllVisible': for (const item of visibleWallpapers()) selection.add(item.id); selectionAnchor ??= [...selection][0] ?? null; renderGrid(false); return;
    case 'clearSelection': selection.clear(); selectionAnchor = null; renderGrid(false); return;
    case 'deleteSelected': if (selection.size) await send('deleteMany', { ids: [...selection] }); return;
    case 'clearWorkshopSearch': workshopDraft.text = ''; // falls through to reset filters
    case 'clearWorkshop': workshopDraft.tags = []; workshopDraft.excludedTags = [...defaultExcludedTags]; render(); await searchWorkshop(); return;
    case 'includeSection': case 'excludeSection': setExcluded(filterDraft(state.page === 'discover'), excludeSections.find(section => section.key === data.section)?.tags.map(entry => tagEntry(entry).tag) || [], action === 'excludeSection'); await applyFilterChange(); return;
    case 'showInstalled': await send('navigate', { page: 'installed' }); await send('select', { id }); return;
    case 'clearProperty': await send('property', { id, propertyID: data.propertyId, value: '' }); return;
    case 'restoreProperty': drafts.delete(draftKey(id, data.propertyId)); await send(action, { id, propertyID: data.propertyId }); return;
    case 'revert': for (const key of drafts.keys()) if (key.startsWith(`${id}\u0000`)) drafts.delete(key); await send(action, { id }); return;
    case 'apply':
      for (const [key, value] of [...drafts]) if (key.startsWith(`${id}\u0000`)) { await send('property', { id, propertyID: key.split('\u0000')[1], value }); if (drafts.get(key) === value) drafts.delete(key); }
      await send(action, { id }); return;
    case 'navigate': await send(action, { page: data.page }); return;
    case 'refreshWorkshop': await searchWorkshop(); return;
    case 'toggleFilters': await send('filters', { page: state.page, collapsed: !filtersCollapsed() }); return;
    case 'toggleSortDirection': installed.descending = !installed.descending; render(); return;
    case 'workshopPage': await send(action, { page: Math.min(workshopMaxPages(), Math.max(1, Number(data.workshopPage) || 1)) }); $('wallpaper-grid').scrollTop = 0; return;
    case 'openExternal': await send(action, { url: data.url }); return;
    case 'import': await send(action, { duplicates: importDuplicates }); return;
    default: {
      const args = {};
      if (id !== undefined) args.id = id;
      if (data.propertyId !== undefined) args.propertyID = data.propertyId;
      if (data.displayId !== undefined) args.displayID = data.displayId;
      await send(action, args);
    }
  }
}
function toggleSelection(id, { range = false } = {}) {
  if (range && selectionAnchor) {
    const ids = visibleWallpapers().map(item => item.id);
    const [from, to] = [ids.indexOf(selectionAnchor), ids.indexOf(id)];
    if (from >= 0 && to >= 0) { for (const each of ids.slice(Math.min(from, to), Math.max(from, to) + 1)) selection.add(each); renderGrid(false); return; }
  }
  if (!selection.delete(id)) selection.add(id);
  selectionAnchor = selection.has(id) ? id : selectionAnchor;
  renderGrid(false);
}
// The top bar doubles as the window's title bar: plain presses on its background move the
// window and double-clicks follow the system title-bar action. Controls keep their own clicks.
function titleBarGesture(event) { return event.button === 0 && !event.target.closest('button, select, input, textarea, a, label, [role="dialog"]'); }
function postTitleBarGesture(action) { const bridge = window.webkit?.messageHandlers?.native; if (bridge) Promise.resolve(bridge.postMessage({ action })).catch(() => {}); }
document.querySelector('.topbar').addEventListener('mousedown', event => { if (!titleBarGesture(event)) return; event.preventDefault(); postTitleBarGesture('dragWindow'); });
document.querySelector('.topbar').addEventListener('dblclick', event => { if (titleBarGesture(event)) postTitleBarGesture('titleDoubleClick'); });
function run(promise) { Promise.resolve(promise).catch(error => { localError = error?.message || String(error); renderError(); }); }
document.addEventListener('click', event => {
  if (event.target.closest('#settings-content, #welcome')) return;
  const control = event.target.closest('[data-action]');
  if (!control) {
    const tab = event.target.closest('.tabs [data-page]');
    if (tab) { run(send('navigate', { page: tab.dataset.page })); return; }
  }
  if (control && !control.disabled) {
    // Modifier clicks on installed tiles build a selection instead of changing the inspector.
    if (control.matches('.tile-select') && state?.page === 'installed' && (selecting || event.metaKey || event.ctrlKey || event.shiftKey)) { toggleSelection(control.dataset.id, { range: event.shiftKey }); return; }
    // Apply on the second click instead of starting another selection request first.
    const action = control.matches('.tile-select') && event.detail === 2
      ? (state?.page === 'installed' ? 'activate' : tileDoubleClickAction(control.dataset.id)) : control.dataset.action;
    run(handleAction(action, control.dataset, control));
  }
  if (popover && !event.target.closest('#queue-popover, #import-popover') && !['openDownloads', 'openImport'].includes(control?.dataset.action)) closePopover(false);
});
document.addEventListener('input', event => {
  const element = event.target;
  if (element.closest('#settings-content, #welcome')) return;
  if (element.type === 'range') { const output = element.parentElement.querySelector('output'); if (output) output.textContent = element.dataset.setting === 'volume' ? `${element.value}%` : element.value; }
  if (element.dataset.input === 'property') { drafts.set(draftKey(element.dataset.id, element.dataset.propertyId), element.value); renderInspector(false); }
  if (element.dataset.input === 'account' && dialogAccount) { dialogAccount.account = element.value; renderDialog(); }
  if (element.dataset.input === 'search') {
    if (state.page === 'discover') { workshopDraft.text = element.value; clearTimeout(searchTimer); searchTimer = setTimeout(() => run(searchWorkshop()), 450); }
    else { installed.text = element.value; renderGrid(false); }
  }
});
document.addEventListener('change', event => {
  const element = event.target;
  if (element.closest('#settings-content, #welcome')) return;
  const change = element.dataset.change;
  const value = element.type === 'checkbox' ? element.checked : element.type === 'number' || element.type === 'range' ? Number(element.value) : element.value;
  if (element.id === 'import-duplicates') { importDuplicates = value; renderPopover(); return; }
  if (change === 'target') run(send('target', { id: value }));
  else if (change === 'property') run(commitProperty(element));
  else if (change === 'wallpaperSetting' || change === 'displayConfig') {
    if (element.validity && !element.validity.valid) { element.reportValidity(); return; }
    const args = { id: element.dataset.id, key: element.dataset.setting, value };
    if (change === 'wallpaperSetting' && args.key === 'volume') args.value = value / 100;
    if (change === 'displayConfig') args.displayID = element.dataset.displayId;
    run(send(change, args));
  } else if (change === 'sort') { if (state.page === 'discover') { workshopDraft.sort = value; run(searchWorkshop()); } else { installed.sort = value; installed.descending = installedSorts.find(([key]) => key === value)?.[2] ?? false; render(); } }
  else if (change === 'filterTag') { const draft = filterDraft(state.page === 'discover'); draft.tags = element.checked ? uniqueTags([...draft.tags, element.value]) : draft.tags.filter(tag => tag !== element.value); run(applyFilterChange()); }
  else if (change === 'filterExclude') { setExcluded(filterDraft(state.page === 'discover'), [element.value], !element.checked); run(applyFilterChange()); }
  else if (change === 'rememberSession' && dialogAccount) { dialogAccount.rememberSession = value; renderDialog(); }
});
document.addEventListener('submit', event => {
  const form = event.target;
  if (form.closest('#settings-content, #welcome')) return;
  event.preventDefault();
  if (form.dataset.form === 'search' && state.page === 'discover') run(searchWorkshop());
  if (form.dataset.form === 'workshopPage' && state.page === 'discover') {
    const input = form.elements.page;
    const pages = Math.min(workshopMaxPages(), Math.max(1, Number(state.workshop.totalPages) || 1));
    const page = Math.min(pages, Math.max(1, Math.round(Number(input.value)) || 1));
    input.value = String(page);
    if (page !== state.workshop.page && !state.workshop.loading) run(handleAction('workshopPage', { workshopPage: page }, input));
  }
  if (form.dataset.form === 'dialogContinue') run(continueDownload(false));
  if (form.dataset.form === 'dialogAuth') {
    const input = form.elements.response; const value = input.value;
    if (!value) return;
    // The secret belongs to this job alone and never survives the submit.
    input.value = '';
    run(send('downloadInput', { id: form.dataset.id, value }));
  }
});
document.addEventListener('keydown', event => {
  if (event.target.closest('#settings-content, #welcome')) return;
  if (event.key === 'Escape') {
    if (popover) closePopover(true);
    else if ((selection.size || selecting) && !dialogTarget) { selection.clear(); selectionAnchor = null; selecting = false; render(); }
  }
  if (['Delete', 'Backspace'].includes(event.key) && state?.page === 'installed' && !state.busy && event.target.closest('.wallpaper-tile')) {
    const id = event.target.closest('.wallpaper-tile')?.dataset.key;
    const ids = selection.size ? [...selection] : id ? [id] : [];
    if (ids.length) { event.preventDefault(); run(send('deleteMany', { ids })); }
  }
  if (event.key === 'Enter' && event.target.dataset.input === 'property') { event.preventDefault(); run(commitProperty(event.target)); }
  const tab = event.target.closest('.tabs [data-page]');
  if (tab && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) { event.preventDefault(); const tabs = [...document.querySelectorAll('.tabs [data-page]')]; const index = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (tabs.indexOf(tab) + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length; tabs[index].focus(); }
  const tile = event.target.closest('.tile-select');
  if (tile && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    const tiles = [...$('wallpaper-grid').querySelectorAll('.tile-select')];
    const columns = getComputedStyle($('wallpaper-grid')).gridTemplateColumns.split(' ').length;
    const index = tiles.indexOf(tile);
    const offset = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -columns, ArrowDown: columns }[event.key];
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tiles.length - 1 : Math.max(0, Math.min(tiles.length - 1, index + offset));
    tiles[next]?.focus();
  }
});
$('download-dialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog(); });
$('download-dialog').addEventListener('close', () => { if (dialogTarget !== null) closeDialog(); });
window.addEventListener('resize', () => { if (popover) renderPopover(); queueLivePreviews(); });
// A Discover page is one Steam page of 30 tiles, at most 1,000 pages deep. Nothing here measures
// the grid: CSS alone decides how many columns the tiles fill, and a page scrolls for the rest,
// so a window resize only reflows the tiles and never asks the native side for anything.
function workshopMaxPages() { return Math.max(1, Number(state?.workshop?.maxPages) || 1000); }
document.addEventListener('error', event => { if (event.target.tagName === 'IMG') { event.target.classList.add('failed'); event.target.style.visibility = 'hidden'; if (event.target.classList.contains('tile-live')) settleLivePreview(event.target, false); else if (event.target.classList.contains('tile-still')) queueLivePreviews(); } }, true);
// Tiles pulse their placeholder until the image arrives, so a slow connection reads as loading, not broken.
document.addEventListener('load', event => { if (event.target.tagName !== 'IMG') return; event.target.classList.add('loaded'); if (event.target.classList.contains('tile-live')) settleLivePreview(event.target, true); else if (event.target.classList.contains('tile-still')) queueLivePreviews(); }, true);
// Discover tiles show their cached still at once. The animated preview then loads through
// mwe-ui://animated/<id> for tiles on screen whose still has arrived, six at a time in grid order
// (the still pass already left its bytes on disk, so this is a local read, not a download),
// and plays beneath the still. Steam GIFs often open on, and loop back through, black frames, so
// the still only steps aside while the sampled animation is about as bright as the still itself.
const live = new Map(); // id -> { status: 'queued' | 'loading' | 'ready' | 'failed', playing, still: luminance }
const LIVE_CONCURRENCY = 6;
let liveSampler = null;
let liveScrollTimer = null;
const liveCanvas = document.createElement('canvas'); liveCanvas.width = liveCanvas.height = 16;
function imageLuminance(image) {
  try {
    const context = liveCanvas.getContext('2d', { willReadFrequently: true });
    context.fillStyle = '#000'; context.fillRect(0, 0, 16, 16);
    context.drawImage(image, 0, 0, 16, 16);
    const pixels = context.getImageData(0, 0, 16, 16).data;
    let total = 0;
    for (let index = 0; index < pixels.length; index += 4) total += 0.2126 * pixels[index] + 0.7152 * pixels[index + 1] + 0.0722 * pixels[index + 2];
    return total / (256 * 255);
  } catch { return null; }
}
function tileOnScreen(tile) {
  const rect = tile.getBoundingClientRect(); const grid = $('wallpaper-grid').getBoundingClientRect();
  return rect.width > 0 && rect.bottom > grid.top && rect.top < grid.bottom;
}
function retireLivePreviews(ids) {
  for (const id of live.keys()) if (!ids.has(id)) { $('wallpaper-grid').querySelector(`[data-key="live-${CSS.escape(id)}"]`)?.removeAttribute('src'); live.delete(id); }
}
// Animations wait for the whole page of stills: every tile shows its picture before any tile
// spends bandwidth on motion, so a slow link reveals the page all at once rather than one
// animated tile at a time. A still counts as settled once it has loaded or failed.
function stillsSettled() {
  return [...$('wallpaper-grid').querySelectorAll('img.tile-still')].every(still => still.complete);
}
function queueLivePreviews() {
  if (state?.page !== 'discover' || !stillsSettled()) return;
  let added = false;
  for (const tile of $('wallpaper-grid').querySelectorAll('.tile-select')) {
    const id = tile.dataset.id;
    if (live.has(id) || !tileOnScreen(tile)) continue;
    const item = (state.workshop?.items || []).find(each => each.id === id);
    const still = tile.querySelector('img.tile-still');
    if (!item || !safeImage(item.animated) || !item.thumbnail || !still?.complete || !still.naturalWidth) continue;
    live.set(id, { status: 'queued', playing: false, still: imageLuminance(still) ?? 0 });
    added = true;
  }
  if (added || live.size) pumpLivePreviews();
}
function pumpLivePreviews() {
  let active = [...live.values()].filter(entry => entry.status === 'loading').length;
  let admitted = false;
  for (const tile of $('wallpaper-grid').querySelectorAll('.tile-select')) {
    if (active >= LIVE_CONCURRENCY) break;
    const entry = live.get(tile.dataset.id);
    if (entry?.status !== 'queued' || !tileOnScreen(tile)) continue;
    entry.status = 'loading'; active += 1; admitted = true;
  }
  if (admitted && state?.page === 'discover') renderGrid(true);
}
function settleLivePreview(image, loaded) {
  const id = image.closest('.tile-select')?.dataset.id;
  const entry = id ? live.get(id) : undefined;
  if (entry?.status === 'loading') entry.status = loaded ? 'ready' : 'failed';
  if (entry && !loaded) renderGrid(true);
  pumpLivePreviews();
  if (loaded) liveSampler ??= setInterval(sampleLivePreviews, 250);
}
function sampleLivePreviews() {
  if (state?.page !== 'discover') return;
  for (const image of $('wallpaper-grid').querySelectorAll('img.tile-live')) {
    const tile = image.closest('.wallpaper-tile'); const entry = live.get(tile?.dataset.key);
    if (!entry || entry.status !== 'ready' || !image.complete || !image.naturalWidth) continue;
    const luminance = imageLuminance(image);
    if (luminance === null) continue;
    const playing = luminance >= entry.still * (entry.playing ? 0.4 : 0.6);
    if (playing !== entry.playing) { entry.playing = playing; tile.classList.toggle('playing', playing); }
  }
}
$('wallpaper-grid').addEventListener('scroll', () => { clearTimeout(liveScrollTimer); liveScrollTimer = setTimeout(queueLivePreviews, 120); }, { passive: true });
// The first-run guide draws over the whole window, so it owns its own events and the panel's
// document-level handlers stay out of it.
const welcome = createWelcome({
  container: $('welcome'), send, run, escapeHTML, icon, button, morph, busy, safeLink, signInGuide, guideMarkup,
  closePopover, dragWindow: () => postTitleBarGesture('dragWindow'),
  clearError: () => { localError = ''; if (state) { state.error = null; state.downloadError = null; } renderError(); run(send('dismissError')); },
  navigate: (page) => send('navigate', { page }),
  openImport: async () => { await send('navigate', { page: 'installed' }); openPopover('import', document.querySelector('#browser-toolbar [data-action="openImport"]')); },
});
applyStaticText();
run(send('ready'));
