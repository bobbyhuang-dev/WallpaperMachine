import { renderSettings } from './settings.js';
import { glyphs } from './icons.js';

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
let workshopDraft = null;
let dialogAccount = null;
let searchTimer;
const installed = { text: '', kind: 'All types', favorites: false, active: false, sort: 'title' };
// Multi-select lives only in the page: ids of installed wallpapers checked for a batch action.
const selection = new Set();
let selectionAnchor = null;
let selecting = false; // Toolbar "Select" mode keeps every tile's check visible.
let animatedID = null; // Discover tile whose full (animated) preview is playing over its still thumbnail.
let animateTimer = null;
const tagGroups = [
  ['Resolution', ['1280 x 720', '1366 x 768', '1920 x 1080', '2560 x 1440', '3840 x 2160', 'Dynamic resolution', 'Other resolution']],
  ['Ultrawide & portrait', ['Ultrawide 2560 x 1080', 'Ultrawide 3440 x 1440', 'Portrait 1080 x 1920', 'Portrait 1440 x 2560', 'Portrait 2160 x 3840']],
  ['Genre', ['Abstract', 'Anime', 'Fantasy', 'Landscape', 'Nature', 'Pixel art', 'Sci-Fi']],
  ['Age rating', ['Everyone', 'Questionable', 'Mature']],
  ['Category', ['Wallpaper', 'Preset', 'Asset']]
];
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
function rate(value) {
  if (!Number.isFinite(value) || value < 0) return '';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  const exponent = value > 0 ? Math.min(Math.max(Math.floor(Math.log10(value) / 3), 0), 3) : 0;
  return `Network speed: ${(value / 1000 ** exponent).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[exponent]}`;
}
function transfer(item, { includePercent = true } = {}) { const percent = Number.isFinite(item?.progress) ? `${Math.round(clamp(item.progress) * 100)}%` : ''; const received = bytes(item?.bytesReceived); const expected = bytes(item?.bytesExpected); const amount = received && expected ? `${received} of ${expected}` : received; return [includePercent ? percent : '', amount, rate(item?.bytesPerSecond)].filter(Boolean).join(' · '); }

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
  if (node.tagName === 'INPUT') { if (!focused) { if (node.name !== 'response' && node.value !== fresh.value) node.value = fresh.value; node.checked = fresh.checked; } return; }
  if (node.tagName === 'TEXTAREA') { if (!focused && node.value !== fresh.value) node.value = fresh.value; return; }
  if (node.tagName === 'SELECT' && focused) return;
  reconcile(node, fresh);
  if (node.tagName === 'SELECT') node.value = fresh.value;
}

async function send(action, args = {}) {
  const bridge = window.webkit?.messageHandlers?.native;
  if (!bridge) { localError = 'The native connection is unavailable. Open this panel in MacWallpaperEngine, then reconnect.'; renderError(); throw new Error(localError); }
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
  if (!workshopDraft) workshopDraft = { text: snapshot.workshop?.text || '', kind: snapshot.workshop?.kind || 'Scene', sort: snapshot.workshop?.sort || 'trend', tags: [...(snapshot.workshop?.tags || [])] };
  render();
}
window.wallpaperUI = { receive };
function renderError() {
  const error = localError || state?.error || state?.downloadError;
  if (!state && error) morph($('browser-empty'), '<h1>Native connection unavailable</h1><p>Open this panel in MacWallpaperEngine. Use Reconnect above to try again.</p>');
  $('error-banner').hidden = !error;
  if (error) morph($('error-banner'), `<p>${escapeHTML(error)}</p>${button('Reconnect', 'ready', {}, { icon: 'refresh' })}${button('', 'dismissError', {}, { icon: 'close', title: 'Dismiss error', className: 'quiet icon-button' })}`);
}
function render() {
  renderError();
  if (!state) return;
  const discover = state.page === 'discover';
  const settings = state.page === 'settings';
  document.querySelectorAll('.tabs [data-page]').forEach(tab => { if (tab.dataset.page === state.page) tab.setAttribute('aria-current', 'page'); else tab.removeAttribute('aria-current'); tab.disabled = busy('navigate', { page: tab.dataset.page }); });
  document.documentElement.style.setProperty('--window-controls-inset', `${Math.max(0, Number(state.windowControlsInset) || 0)}px`);
  morph($('app-identity'), `<span class="app-title"><span class="app-name">MacWallpaperEngine</span>${state.version ? `<span class="app-version">${escapeHTML(state.version)}</span>` : ''}</span>${safeLink(state.repositoryURL) ? button('', 'openExternal', { url: state.repositoryURL }, { icon: 'github', title: 'MacWallpaperEngine on GitHub', className: 'quiet icon-button github-link' }) : ''}`);
  morph($('top-actions'), `<label class="sr-only" for="target-display">Target display</label><select id="target-display" data-change="target" aria-label="Target display"${disabled(state.busy)}>${(state.displays || []).map(display => `<option value="${escapeHTML(display.id)}"${display.id === state.targetDisplayID ? ' selected' : ''}${disabled(!display.enabled || display.mode === 'mirror')}>${escapeHTML(display.title)}${display.mode === 'mirror' ? ' (mirrored)' : !display.enabled ? ' (disabled)' : ''}</option>`).join('')}</select>${queueButton()}${button('Renderer source', 'openExternal', { url: 'https://github.com/bigsaltyfishes/wallpaper-engine-for-macos.git' }, { icon: 'external', title: 'Renderer source on GitHub', className: 'quiet renderer-link' })}`);
  $('library-page').hidden = settings;
  $('settings-content').hidden = !settings;
  if (settings) renderSettings($('settings-content'), state, { send, escapeHTML, icon, challengeHint, requestAssets: (element) => run(requestDownload(null, element)), openDownloadDialog: (id, element) => openDialog(id, element) });
  else {
    const filtersCollapsed = discover && Boolean(state.workshopFiltersCollapsed);
    $('library-page').classList.toggle('discover', discover);
    $('library-page').classList.toggle('filters-collapsed', filtersCollapsed);
    $('workshop-filters').hidden = !discover;
    $('workshop-filters').classList.toggle('collapsed', filtersCollapsed);
    applyInspectorWidth(state.inspectorWidth);
    renderToolbar(discover);
    if (discover) renderFilters();
    renderGrid(discover);
    renderInspector(discover);
  }
  renderActivity(); renderPopover(); renderDialog();
}
function renderToolbar(discover) {
  const filterCount = Number(installed.kind !== 'All types') + Number(installed.favorites) + Number(installed.active);
  const search = discover ? workshopDraft.text : installed.text;
  morph($('browser-toolbar'), `<form class="search-form" data-form="search" ${keyAttr(discover ? 'workshop-search' : 'installed-search')}>${icon('search')}<label class="sr-only" for="wallpaper-search">${discover ? 'Search Steam Workshop' : 'Search installed wallpapers'}</label><input id="wallpaper-search" type="search" autocomplete="off" placeholder="${discover ? 'Search Workshop' : 'Search wallpapers'}" value="${escapeHTML(search)}" data-input="search">${discover ? '<button type="submit" title="Search Workshop">Search</button>' : ''}</form><label class="sr-only" for="browser-sort">Sort wallpapers</label><select id="browser-sort" data-change="sort">${selectOptions(discover ? [['trend', 'Trending this week'], ['totaluniquesubscribers', 'Most subscribed'], ['mostrecent', 'Newest'], ['textsearch', 'Relevance']] : [['title', 'Title'], ['type', 'Type']], discover ? workshopDraft.sort : installed.sort)}</select>${discover ? button('', 'refreshWorkshop', {}, { icon: 'refresh', title: 'Refresh Workshop', disabled: state.workshop.loading }) : `<details class="installed-filter" ${keyAttr('installed-filter')}><summary>${icon('filter')}Filters${filterCount ? ` (${filterCount})` : ''}</summary><div class="filter-popover"><label>Wallpaper type<select data-change="installedKind">${selectOptions(['All types', 'Scene', 'Video', 'Web', 'Unknown'], installed.kind)}</select></label><label class="check-label"><input type="checkbox" data-change="installedFavorites"${checked(installed.favorites)}>Favorites only</label><label class="check-label"><input type="checkbox" data-change="installedActive"${checked(installed.active)}>Active on target display</label>${button('Clear filters', 'clearInstalled')}</div></details>${button(selecting ? 'Done' : 'Select', 'toggleSelecting', {}, { icon: selecting ? 'close' : 'check', title: selecting ? 'Leave selection mode' : 'Select wallpapers to move to Trash', className: selecting ? 'selecting' : '' })}${button('', 'refresh', {}, { icon: 'refresh', title: 'Refresh library', disabled: state.libraryLoading })}${button('Import', 'openImport', {}, { icon: 'plus', disabled: state.import?.busy })}`}`);
}
function renderFilters() {
  const count = workshopDraft.tags.length + Number(workshopDraft.kind !== 'All types');
  const known = new Set(tagGroups.flatMap(([, values]) => values));
  const groups = [...tagGroups];
  const other = workshopDraft.tags.filter(tag => !known.has(tag));
  if (other.length) groups.push(['Other selected tags', other]);
  if (state.workshopFiltersCollapsed) {
    morph($('workshop-filters'), `${button('', 'toggleWorkshopFilters', {}, { icon: 'chevronRight', title: count ? `Show filters (${count} active)` : 'Show filters', className: 'filter-toggle', expanded: false, controls: 'workshop-filters' })}${count ? `<span class="filter-rail-count" aria-hidden="true">${count}</span>` : ''}`);
    return;
  }
  morph($('workshop-filters'), `<div class="filter-heading"><h3>Filters${count ? ` (${count})` : ''}</h3>${button('Clear', 'clearWorkshop', {}, { className: 'link', disabled: !count })}${button('', 'toggleWorkshopFilters', {}, { icon: 'chevronLeft', title: 'Hide filters', className: 'filter-toggle', expanded: true, controls: 'workshop-filters' })}</div><details class="filter-group" open ${keyAttr('kind')}><summary>Type${icon('chevronRight', 13)}</summary><div class="filter-options"><label class="sr-only" for="workshop-kind">Workshop type</label><select id="workshop-kind" data-change="workshopKind">${selectOptions(['All types', 'Scene', 'Video', 'Web', 'Application'], workshopDraft.kind)}</select></div></details>${groups.map(([title, values], index) => `<details class="filter-group" ${index === 0 ? 'open' : ''} ${keyAttr(title)}><summary>${escapeHTML(title)}${icon('chevronRight', 13)}</summary><div class="filter-options">${values.map(tag => `<label class="check-label" ${keyAttr(tag)}><input type="checkbox" data-change="workshopTag" value="${escapeHTML(tag)}"${checked(workshopDraft.tags.includes(tag))}><span>${escapeHTML(tag)}</span></label>`).join('')}</div></details>`).join('')}<p class="muted"><small>Match all selected tags. Filters search the entire Workshop.</small></p>`);
}
function visibleWallpapers() {
  const target = (state.displays || []).find(display => display.id === state.targetDisplayID);
  return (state.wallpapers || []).filter(item => (!installed.text || `${item.title} ${item.tags.join(' ')}`.toLocaleLowerCase().includes(installed.text.toLocaleLowerCase())) && (installed.kind === 'All types' || item.kind === installed.kind) && (!installed.favorites || state.favorites.includes(item.id)) && (!installed.active || target?.wallpaperID === item.id)).sort((a, b) => (installed.sort === 'type' ? a.kind.localeCompare(b.kind) : 0) || a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }));
}
function renderGrid(discover) {
  const workshop = state.workshop;
  const items = discover ? workshop.items || [] : visibleWallpapers();
  const loading = discover ? workshop.loading : state.libraryLoading;
  const selectedID = discover ? workshop.selectedID : state.selectedID;
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  $('wallpaper-grid').setAttribute('aria-busy', String(Boolean(loading)));
  const count = `${items.length.toLocaleString()} ${items.length === 1 ? 'wallpaper' : 'wallpapers'}`;
  morph($('browser-summary'), loading ? escapeHTML(discover ? 'Searching Steam Workshop…' : 'Loading your library…') : discover ? escapeHTML(workshop.loaded ? `${Number(workshop.totalCount).toLocaleString()} results` : 'Steam Workshop') : selection.size ? `<div class="selection-bar"><span class="selection-count">${selection.size.toLocaleString()} selected</span>${button('Select all', 'selectAllVisible', {}, { className: 'link', disabled: items.every(item => selection.has(item.id)) })}${button('Clear', 'clearSelection', {}, { className: 'link' })}${button(selection.size === 1 ? 'Move to Trash' : `Move ${selection.size.toLocaleString()} to Trash`, 'deleteSelected', {}, { icon: 'trash', className: 'danger', disabled: state.busy || busy('deleteMany') })}</div>` : `<div class="selection-bar"><span>${escapeHTML(count)}</span>${items.length && selecting ? `<span class="muted">Click tiles to select them.</span>${button('Select all', 'selectAllVisible', {}, { className: 'link' })}` : ''}</div>`);
  $('wallpaper-grid').classList.toggle('selecting', !discover && (selecting || selection.size > 0));
  morph($('wallpaper-grid'), items.map(item => `<article class="wallpaper-tile${selection.has(item.id) ? ' checked' : ''}" ${keyAttr(item.id)}><button type="button" class="tile-select" data-action="${discover ? 'workshopSelect' : 'select'}" data-id="${escapeHTML(item.id)}" aria-pressed="${item.id === selectedID}" aria-label="${escapeHTML(item.title)}, ${escapeHTML(item.kind)}${item.id === selectedID ? ', selected' : ''}"><span class="tile-placeholder">${icon('image', 28)}</span>${safeImage(item.thumbnail || item.preview) ? `<img ${keyAttr(item.thumbnail || item.preview)} src="${escapeHTML(safeImage(item.thumbnail || item.preview))}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer">` : ''}${discover && item.id === animatedID && item.thumbnail && safeImage(item.preview) ? `<img ${keyAttr(`live-${item.preview}`)} class="tile-live" src="${escapeHTML(safeImage(item.preview))}" alt="" decoding="async" referrerpolicy="no-referrer">` : ''}<span class="tile-caption"><span class="tile-title">${escapeHTML(item.title)}</span><span class="tile-kind">${escapeHTML(item.kind)}</span></span></button>${!discover ? `<button type="button" class="tile-check" data-action="toggleSelect" data-id="${escapeHTML(item.id)}" aria-pressed="${selection.has(item.id)}" aria-label="${selection.has(item.id) ? 'Deselect' : 'Select'}: ${escapeHTML(item.title)}">${icon('check', 14)}</button><button type="button" class="tile-favorite" data-action="favorite" data-id="${escapeHTML(item.id)}" aria-pressed="${state.favorites.includes(item.id)}" aria-label="${state.favorites.includes(item.id) ? 'Remove favorite' : 'Add favorite'}: ${escapeHTML(item.title)}"${disabled(busy('favorite', { id: item.id }))}>${icon('star', 14)}</button>${target?.wallpaperID === item.id ? '<span class="active-badge">Active</span>' : item.active ? '<span class="active-badge">Other display</span>' : ''}` : ''}</article>`).join(''));
  const empty = $('browser-empty'); empty.hidden = items.length > 0;
  $('wallpaper-grid').hidden = !items.length;
  if (!items.length) morph(empty, loading ? `<h1>${discover ? 'Loading Workshop' : 'Loading wallpapers'}</h1><p>${discover ? 'Fetching wallpapers from Steam.' : 'Reading your wallpaper library.'}</p>` : workshop.error && discover ? `<h1>Workshop unavailable</h1><p>${escapeHTML(workshop.error)}</p>${button('Try again', 'workshopRetry', {}, { icon: 'refresh' })}` : `<h1>${discover ? 'No wallpapers found' : state.wallpapers.length ? 'No matching wallpapers' : 'Your wallpaper library is empty'}</h1><p>${discover ? 'Try a different search or remove some filters. Every selected tag must match.' : state.wallpapers.length ? 'Change your search or clear filters to see more wallpapers.' : 'Import a wallpaper folder or find something on the Workshop.'}</p><div class="actions">${discover ? button('Clear search and filters', 'clearWorkshopSearch') : state.wallpapers.length ? button('Clear search and filters', 'clearInstalledSearch') : `${button('Import wallpapers', 'openImport', {}, { icon: 'plus' })}${button('Browse Workshop', 'navigate', { page: 'discover' }, { className: 'primary' })}`}</div>`);
  const pages = Math.max(1, Number(workshop.totalPages) || 1);
  // Steam's public browse page stops at 1,000 pages of 30, whatever the result count says.
  const reachable = pages * (Number(workshop.pageSize) || 30);
  const capped = Boolean(workshop.loaded) && Number(workshop.totalCount) > reachable;
  morph($('pagination'), discover ? `${workshop.error && items.length ? `<p class="error">${escapeHTML(workshop.error)}</p>${button('Retry', 'workshopRetry')}` : ''}${button('', 'workshopPage', { workshopPage: Math.max(1, workshop.page - 1) }, { icon: 'chevronLeft', title: 'Previous page', disabled: loading || workshop.page <= 1 })}<form class="page-jump" data-form="workshopPage" aria-label="Go to page" novalidate><label>Page <input type="number" name="page" ${keyAttr('workshop-page')} inputmode="numeric" min="1" max="${pages}" step="1" value="${workshop.page || 1}" title="Type a page number and press Return" aria-label="Page number"${disabled(loading || pages <= 1)}></label><span>of ${pages.toLocaleString()}</span><button type="submit" class="link"${disabled(loading || pages <= 1)}>Go</button></form>${button('', 'workshopPage', { workshopPage: workshop.page + 1 }, { icon: 'chevronRight', title: 'Next page', disabled: loading || workshop.page >= pages })}${capped ? `<p class="pagination-note">Steam only lists the first ${reachable.toLocaleString()} of ${Number(workshop.totalCount).toLocaleString()} results. Narrow the search or add filters to reach the rest.</p>` : ''}` : '');
}

function renderInspector(discover) {
  const item = discover ? state.workshop.items.find(item => item.id === state.workshop.selectedID) : state.wallpapers.find(item => item.id === state.selectedID);
  if (!item) { morph($('inspector'), '<div class="inspector-empty"><h2>Select a wallpaper</h2><p>Preview, details and options appear here.</p></div>'); return; }
  const isInstalled = state.wallpapers.some(wallpaper => wallpaper.id === item.id);
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  const canActivate = isInstalled && !['Application', 'Unknown'].includes(item.kind) && target?.enabled && target.mode !== 'mirror';
  const download = state.downloads.find(download => download.id === item.id);
  const request = requestByID(item.id);
  const percent = Number.isFinite(download?.progress) ? Math.round(clamp(download.progress) * 100) : null;
  const downloadAction = request
    ? button('Continue setup', 'continueSetup', { id: request.id }, { icon: 'shield', className: 'primary' })
    : download?.pending
      ? button(download.queued ? 'Waiting to download' : percent === null ? 'Downloading' : `Downloading ${percent}%`, 'openDownloads', {}, { icon: 'download', className: 'primary' })
      : button(download?.error ? 'Download again' : 'Download', 'requestDownload', { id: item.id }, { icon: 'download', className: 'primary' });
  const options = !discover && state.options?.id === item.id ? state.options : null;
  const compatibility = { Scene: 'Scene renderer is experimental.', Video: 'Playback depends on the video codec.', Web: 'Runs in a built-in web view. Mouse input reaches the page; audio response and keyboard input are not available yet.', Application: 'Application wallpapers cannot run on macOS.', Unknown: 'This wallpaper type is not supported.' }[item.kind] || '';
  morph($('inspector'), `<div ${keyAttr(`inspector-${item.id}-${discover}`)}><div class="inspector-preview">${preview(item.preview)}</div><div class="inspector-heading"><h2>${escapeHTML(item.title)}</h2><p class="muted">${escapeHTML(item.kind)}${discover && item.creator ? ` by ${escapeHTML(item.creator)}` : ''}</p>${tags(item.tags)}<div class="actions">${isInstalled ? button(target?.wallpaperID === item.id ? 'Reapply wallpaper' : 'Apply wallpaper', 'activate', { id: item.id }, { icon: 'play', className: 'primary', disabled: !canActivate || state.busy }) : downloadAction}${isInstalled ? button('', 'favorite', { id: item.id }, { icon: 'star', title: state.favorites.includes(item.id) ? 'Remove from favorites' : 'Add to favorites', className: state.favorites.includes(item.id) ? 'favorite-selected' : '' }) : ''}${isInstalled ? button('', 'reveal', { id: item.id }, { icon: 'folder', title: 'Show in Finder' }) : ''}${isInstalled ? button('', 'delete', { id: item.id }, { icon: 'trash', className: 'danger', title: 'Move wallpaper to Trash', disabled: state.busy }) : ''}</div>${!isInstalled && download?.pending && !download.queued ? `<progress class="inspector-progress" max="1"${Number.isFinite(download.progress) ? ` value="${clamp(download.progress)}"` : ''} aria-label="${escapeHTML(item.title)} download progress"></progress><p class="muted"><small>${escapeHTML(download.status)}${transfer(download, { includePercent: false }) ? ` · ${transfer(download, { includePercent: false })}` : ''}</small></p>` : ''}${request ? `<p class="muted"><small>${escapeHTML(stageHint(request.stage))}</small></p>` : ''}${!isInstalled && download?.error && !download.pending ? `<p class="notice error">${escapeHTML(download.error)}</p>` : ''}${isInstalled && download && !download.pending && !download.error ? button('Show in library', 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' }) : ''}${download || request ? button('Show in downloads', 'openDownloads', {}, { className: 'link' }) : ''}${compatibility ? `<p class="muted"><small>${escapeHTML(compatibility)}</small></p>` : ''}${item.kind === 'Scene' && !state.settings.sceneAssetsReady ? `<div class="notice warning">Shared scene resources are required before playback.${button('Get shared resources', 'requestAssets', {}, { className: 'link' })}</div>` : ''}</div>${discover ? `<section class="inspector-section">${item.summary ? `<p>${escapeHTML(item.summary)}</p>` : ''}${bytes(item.size) ? `<p class="muted">Download size: ${bytes(item.size)}</p>` : ''}${Number.isFinite(item.subscriptions) ? `<p class="muted">${item.subscriptions.toLocaleString()} subscribers</p>` : ''}${button('View on Steam Workshop', 'openExternal', { url: `https://steamcommunity.com/sharedfiles/filedetails/?id=${encodeURIComponent(item.id)}` }, { icon: 'external', className: 'link' })}${isInstalled ? button('Show in library', 'showInstalled', { id: item.id }, { icon: 'folder' }) : ''}</section>` : `${options ? renderOptions(options) : '<section class="inspector-section"><p class="muted">Loading wallpaper options…</p></section>'}`}</div>`);
}
const draftKey = (id, propertyID) => `${id}\u0000${propertyID}`;
function renderOptions(options) {
  const id = options.id;
  const lock = state.busy || busy('apply', { id }) || busy('revert', { id });
  const changed = options.dirty || [...drafts.keys()].some(key => key.startsWith(`${id}\u0000`));
  return `${!options.supported ? '<section class="inspector-section"><p class="notice warning">This wallpaper cannot be rendered on this Mac.</p></section>' : ''}<section class="inspector-section"><details open ${keyAttr(`general-${id}`)}><summary>General configuration${icon('chevronRight', 14)}</summary><div class="section-content"><label class="check-label"><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="muted"${checked(options.muted)}${disabled(lock)}>Mute wallpaper audio</label><div class="field"><label for="wallpaper-volume">Volume</label><div class="range-field"><input id="wallpaper-volume" type="range" min="0" max="100" step="1" value="${Number(options.volume) * 100}" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="volume"${disabled(lock || options.muted)}><output>${Math.round(options.volume * 100)}%</output></div></div><label class="check-label"><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="audioResponseEnabled"${checked(options.audioResponseEnabled)}${disabled(lock)}>Audio response</label><p class="muted"><small>Reactive scenes use sound playing in other apps. macOS may request system audio recording permission.</small></p></div></details></section><section class="inspector-section"><details open ${keyAttr(`displays-${id}`)}><summary>Displays${icon('chevronRight', 14)}</summary><div class="section-content">${(options.displays || []).map(display => `<details class="display-options" open ${keyAttr(display.id)}><summary>${escapeHTML(display.title)}${icon('chevronRight', 13)}</summary><div class="section-content"><label class="check-label"><input type="checkbox" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="enabled"${checked(display.enabled)}${disabled(lock)}>Enabled</label><label class="field">Scaling mode<select data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingMode"${disabled(lock)}>${selectOptions([['none', 'Original size'], ['stretch', 'Stretch'], ['match', 'Fit'], ['fill', 'Fill']], display.scalingMode)}</select></label><label class="field">Scale factor<input type="number" min="${Number.MIN_VALUE}" step="any" value="${Number(display.scalingFactor)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingFactor"${disabled(lock)}></label><label class="field">Frame rate<input type="number" min="1" max="${Number(display.maxFps) || 240}" step="1" value="${Number(display.fps)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="fps"${disabled(lock)}></label>${button('Remove from display', 'eject', { id, displayID: display.id }, { className: 'link', disabled: lock })}</div></details>`).join('') || '<p class="muted">Apply this wallpaper to a display to configure playback.</p>'}</div></details></section>${options.properties?.length ? `<section class="inspector-section"><details open ${keyAttr(`properties-${id}`)}><summary>Wallpaper properties${icon('chevronRight', 14)}</summary><div class="section-content">${options.properties.map(property => renderProperty(id, property, lock)).join('')}</div></details></section>` : ''}<div class="inspector-save"><p>${changed ? 'You have unapplied changes.' : 'Audio, scaling mode and frame rate update immediately.'}</p>${button('Revert', 'revert', { id }, { disabled: lock || !changed })}${button('Apply changes', 'apply', { id }, { className: 'primary', disabled: lock || !changed || !options.supported })}</div>`;
}
function renderProperty(id, property, lock) {
  const name = property.label || property.id;
  const fieldID = `property-${encodeURIComponent(id)}-${encodeURIComponent(property.id)}`;
  const value = drafts.has(draftKey(id, property.id)) ? drafts.get(draftKey(id, property.id)) : property.value;
  const unavailable = lock || property.enabled === false || busy('property', { id, propertyID: property.id });
  const attributes = `id="${escapeHTML(fieldID)}" data-change="property" data-id="${escapeHTML(id)}" data-property-id="${escapeHTML(property.id)}"${disabled(unavailable)}`;
  let control;
  switch (property.kind) {
    case 'boolean': control = `<label class="check-label"><input type="checkbox" ${attributes}${checked(value)}>Enabled</label>`; break;
    case 'slider': control = `<div class="range-field"><input type="range" ${attributes} min="${Number(property.min ?? 0)}" max="${Number(property.max ?? 100)}" step="${Number(property.step) > 0 ? Number(property.step) : 'any'}" value="${Number(value)}"><output>${escapeHTML(value)}</output></div>`; break;
    case 'combo': control = `<select ${attributes}>${(property.options || []).map(option => `<option value="${escapeHTML(JSON.stringify(option.value))}"${JSON.stringify(value) === JSON.stringify(option.value) ? ' selected' : ''}>${escapeHTML(option.label)}</option>`).join('')}</select>`; break;
    case 'color': control = `<input type="color" ${attributes} value="${/^#[0-9a-f]{6}$/i.test(value) ? value : '#ffffff'}">`; break;
    case 'textInput': control = `<input type="text" ${attributes} data-input="property" value="${escapeHTML(value)}" autocomplete="off">`; break;
    case 'file': control = `<p class="file-value">${escapeHTML(value || 'No image selected')}</p><div class="actions">${button('Choose image', 'choosePropertyFile', { id, propertyID: property.id }, { icon: 'folder', disabled: unavailable })}${value ? button('Clear', 'clearProperty', { id, propertyID: property.id }, { disabled: unavailable }) : ''}</div>`; break;
    case 'text': return `<p ${keyAttr(property.id)} class="muted">${escapeHTML(name)}${value && value !== name ? `<br>${escapeHTML(value)}` : ''}</p>`;
    default: return `<p ${keyAttr(property.id)} class="muted">${escapeHTML(name)}: unsupported property type.</p>`;
  }
  return `<div ${keyAttr(property.id)} class="field${property.dirty || drafts.has(draftKey(id, property.id)) ? ' modified' : ''}"><div class="field-title"><label for="${escapeHTML(fieldID)}">${escapeHTML(name)}</label>${property.defaultValue !== undefined && property.defaultValue !== null ? button('Reset', 'restoreProperty', { id, propertyID: property.id }, { className: 'link', title: `Restore default: ${name}`, disabled: unavailable }) : ''}</div>${control}</div>`;
}

const clamp = (value) => Math.max(0, Math.min(1, Number(value)));
const requestByID = (id) => (state?.downloadRequests || []).find(request => request.id === id);
const jobByID = (id) => (state?.downloads || []).find(item => item.id === id);
const stageHint = (stage) => ({ setup: 'Waiting for SteamCMD setup.', account: 'Waiting for your Steam sign-in.', resources: 'Waiting for your go-ahead on shared resources.', ready: 'Starting…' })[stage] || 'Waiting to continue.';
const stageTitle = (stage) => ({ setup: 'Install SteamCMD', account: 'Sign in to Steam', resources: 'Shared Wallpaper Engine resources', ready: 'Starting download' })[stage] || 'Continue this download';
const challengeHint = (challenge) => ({
  mobileApproval: 'Open Steam on your phone, go to Steam Guard, and approve the sign-in you just started. Only approve requests you recognise.',
  authenticatorCode: 'Open Steam Guard in the Steam mobile app and enter its current authenticator code before it changes.',
  emailCode: 'Check the email address registered to this Steam account, including spam, then enter the latest Steam Guard code.',
})[challenge] || (challenge ? 'Use the verification method Steam requested. Do not disable Steam Guard or share passwords or recovery codes.' : '');
function queueState() {
  const downloads = state.downloads || [];
  const requests = state.downloadRequests || [];
  const running = downloads.find(item => item.pending && !item.queued);
  const queued = downloads.filter(item => item.pending && item.queued);
  const attention = downloads.filter(item => item.prompt || item.challenge || item.error);
  const percent = Number.isFinite(running?.progress) ? Math.round(clamp(running.progress) * 100) : null;
  const count = requests.length + (running ? 1 : 0) + queued.length;
  const summary = running ? (running.status || 'Downloading') + (percent !== null ? ` · ${percent}%` : '') + (rate(running.bytesPerSecond) ? ` · ${rate(running.bytesPerSecond)}` : '') : requests.length ? `${requests.length} download${requests.length === 1 ? '' : 's'} need setup` : queued.length ? `${queued.length} waiting to download` : downloads.length ? `${downloads.length} download${downloads.length === 1 ? '' : 's'}` : 'No downloads';
  return { downloads, requests, running, queued, attention, percent, count, summary };
}
function queueButton() {
  const { attention, count, summary } = queueState();
  const label = `Downloads: ${summary}${attention.length ? ' · needs attention' : ''}`;
  return `<button type="button" data-action="openDownloads" class="quiet icon-button queue-button" aria-haspopup="dialog" aria-expanded="${popover === 'downloads'}" title="${escapeHTML(label)}" aria-label="${escapeHTML(label)}">${icon('download')}${count ? `<span class="queue-badge${attention.length ? ' attention' : ''}" aria-hidden="true">${count}</span>` : ''}</button>`;
}
function renderActivity() {
  const { summary, attention, running, percent } = queueState();
  morph($('activity-bar'), `<div class="activity-left">${button('', 'playback', {}, { icon: state.paused ? 'play' : 'pause', title: state.paused ? 'Resume wallpaper playback' : 'Pause wallpaper playback', className: 'quiet icon-button', disabled: state.busy || !(state.wallpapers || []).some(item => item.active) })}<span class="activity-copy">${state.paused ? 'Playback paused' : 'Playback running'}</span></div><div class="activity-right">${state.import?.busy ? button(state.import.status || 'Importing…', 'openImport', {}, { icon: 'folder', className: 'quiet' }) : ''}${state.setup?.busy ? '<span class="activity-copy">Setting up SteamCMD…</span>' : ''}${running && !running.authenticating ? `<progress class="activity-progress" max="1"${percent !== null ? ` value="${clamp(running.progress)}"` : ''} aria-label="${escapeHTML(running.title)} download progress"></progress>` : ''}${button(`${summary}${attention.length ? ' · needs attention' : ''}`, 'openDownloads', {}, { icon: 'download', className: 'quiet' })}</div>`);
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
  const empty = succeeded.length ? 'Every download finished. Nothing needs you.' : 'No downloads yet. Pick a Workshop wallpaper and choose Download.';
  return `<div class="popover-heading"><h2 id="queue-popover-title">Downloads</h2>${button('', 'closePopover', {}, { icon: 'close', title: 'Close downloads', className: 'quiet icon-button' })}</div>${rows ? `<ul class="queue-list">${rows}</ul>` : `<p class="queue-empty">${empty}</p>`}<div class="popover-footer"><p class="queue-note">Downloads run one at a time. Steam may ask you to approve each sign-in.</p><div class="actions">${succeeded.length ? button(queueExpanded ? 'Hide completed' : `Show completed (${succeeded.length})`, 'toggleQueueHistory', {}, { className: 'link' }) : ''}${downloads.length > active.length ? button('Clear finished', 'clearDownloads', {}, { className: 'quiet' }) : ''}${button('Show download logs', 'showLogs', {}, { icon: 'folder', className: 'link' })}</div></div>`;
}
const needsReview = (item) => Boolean(item.error) || Boolean(item.cancelled);
function queueRequestRow(request) {
  return `<li class="queue-row attention" ${keyAttr(`request-${request.id}`)}><span class="queue-thumb">${previewThumb(request.thumbnail || request.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(request.title)}</p><p class="queue-status">${escapeHTML(stageHint(request.stage))}</p><div class="actions">${button('Continue setup', 'continueSetup', { id: request.id }, { className: 'primary' })}${button('', 'removeDownloadRequest', { id: request.id }, { icon: 'close', title: `Remove ${request.title} from downloads`, className: 'quiet icon-button' })}</div></div></li>`;
}
function queueJobRow(item) {
  const installedItem = (state.wallpapers || []).find(wallpaper => wallpaper.id === item.id);
  const percent = Number.isFinite(item.progress) ? Math.round(clamp(item.progress) * 100) : null;
  const running = item.pending && !item.queued;
  const needsAuth = running && Boolean(item.prompt || item.challenge);
  const review = !item.pending && needsReview(item);
  return `<li class="queue-row${needsAuth || review ? ' attention' : ''}" ${keyAttr(`job-${item.id}`)}><span class="queue-thumb">${previewThumb(item.thumbnail || item.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(item.title)}</p><p class="queue-status">${escapeHTML(item.status)}${item.queued ? ' · Waiting its turn' : running && transfer(item) ? ` · ${transfer(item)}` : ''}</p>${running ? `<progress max="1"${percent === null ? '' : ` value="${clamp(item.progress)}"`} aria-label="${escapeHTML(item.title)} download progress"></progress>` : ''}${item.error ? `<p class="notice error">${escapeHTML(item.error)}</p>` : ''}${item.warning ? `<p class="notice warning">${escapeHTML(item.warning)}</p>` : ''}<div class="actions">${needsAuth ? button('Finish sign-in', 'continueSetup', { id: item.id }, { icon: 'shield', className: 'primary' }) : ''}${item.pending ? button(item.queued ? 'Remove from queue' : 'Cancel', 'downloadCancel', { id: item.id }, { className: 'quiet' }) : ''}${review ? button('Try again', 'downloadRetry', { id: item.id }, { icon: 'refresh', disabled: !state.setup?.ready }) : ''}${installedItem ? `${button('Show in library', 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' })}${button('Show in Finder', 'reveal', { id: item.id }, { icon: 'folder', className: 'link' })}` : ''}</div></div></li>`;
}
function importMarkup() {
  const status = state.import || {};
  const report = status.report;
  return `<div class="popover-heading"><h2 id="import-popover-title">Import wallpapers</h2>${button('', 'closePopover', {}, { icon: 'close', title: 'Close import', className: 'quiet icon-button' })}</div><div class="popover-body"><p class="muted">Choose wallpaper folders or files. Imports copy the source files into your library and leave the originals untouched.</p><label class="field">If a wallpaper already exists<select id="import-duplicates"${disabled(status.busy)}>${selectOptions([['skip', 'Skip duplicates'], ['keepBoth', 'Keep both copies']], importDuplicates)}</select></label><div class="actions">${button('Choose wallpapers', 'import', { duplicates: importDuplicates }, { icon: 'folder', className: 'primary', disabled: status.busy })}${status.busy ? button('Cancel import', 'importCancel') : ''}</div>${status.status ? `<p class="muted" role="status">${escapeHTML(status.status)}</p>` : ''}${report ? `<div class="import-controls"><p>${Number(report.imported)} imported · ${Number(report.skipped)} skipped${report.cancelled ? ' · Cancelled' : ''}</p>${(report.failures || []).map(failure => `<p class="notice error">${escapeHTML(failure)}</p>`).join('')}</div>` : ''}</div>`;
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
  dialogTarget = null;
  dialogTrigger = null;
  dialogAccount = null;
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
  if (!waiting && !auth) { closeDialog(); return; }
  if (dialogAccount?.id !== dialogTarget) seedAccount(dialogTarget);
  const stage = waiting ? waiting.stage : 'auth';
  const open = node.open;
  node.dataset.stage = stage;
  morph(node, dialogMarkup(stage, waiting || own || auth, auth));
  if (!open) {
    node.showModal();
    (node.querySelector('.dialog-body input:not([disabled]), .dialog-body button.primary:not([disabled]), .dialog-body button:not([disabled])') || node).focus();
  }
}
function dialogMarkup(stage, subject, auth) {
  const body = stage === 'setup' ? setupStep() : stage === 'account' ? accountStep() : stage === 'resources' ? resourcesStep() : authStep(auth);
  const title = stage === 'auth' ? auth.prompt || auth.challenge ? 'Verify this Steam sign-in' : 'Connecting to Steam' : stageTitle(stage);
  const subtitle = stage === 'auth' && auth.id !== subject.id ? `${auth.title} · needed for ${subject.title}` : subject.title;
  return `<div class="dialog-head"><span class="dialog-thumb">${previewThumb(stage === 'auth' ? auth.thumbnail || auth.preview || subject.thumbnail || subject.preview : subject.thumbnail || subject.preview)}</span><div class="dialog-heading"><h2 id="download-dialog-title">${escapeHTML(title)}</h2><p class="muted">${escapeHTML(subtitle)}</p></div>${button('', 'dismissDialog', {}, { icon: 'close', title: 'Close without removing this download', className: 'quiet icon-button' })}</div><div class="dialog-body" data-stage="${stage}">${body}</div>`;
}
function setupStep() {
  const setup = state.setup || {};
  const retained = setup.candidatePath ? setup.canApprove ? `<p class="notice">This downloaded copy needs your approval before it can run:<br>${escapeHTML(setup.candidatePath)}</p>` : `<p class="notice warning">A downloaded copy is retained but not usable yet:<br>${escapeHTML(setup.candidatePath)}</p>` : '';
  return `<p>SteamCMD is Valve’s download tool. Install it here, or point to a copy you already have. Installing it does not sign you in.</p><p class="dialog-status" role="status">${escapeHTML(setup.status || (setup.ready ? 'SteamCMD is ready.' : 'SteamCMD is not installed yet.'))}</p>${setup.busy && Number.isFinite(setup.progress) ? `<progress max="1" value="${clamp(setup.progress)}" aria-label="SteamCMD installation progress"></progress>` : ''}${setup.error ? `<p class="notice error">${escapeHTML(setup.error)}</p>` : ''}${retained}<div class="dialog-actions">${setup.canApprove ? button('Allow this SteamCMD', 'setupApprove', {}, { icon: 'shield', className: 'primary', disabled: setup.busy }) : button('Install SteamCMD', 'setupInstall', {}, { icon: 'download', className: 'primary', disabled: setup.busy })}${button('Locate a copy', 'setupLocate', {}, { icon: 'folder', disabled: setup.busy })}${setup.busy && setup.canCancel !== false ? button('Cancel setup', 'setupCancel') : ''}${button('Not now', 'dismissDialog', {}, { className: 'quiet' })}</div>${setup.candidatePath ? `<div class="dialog-actions">${button('Show it in Finder', 'setupRevealCandidate', {}, { icon: 'folder', className: 'link' })}${button('Discard it', 'setupDiscardCandidate', {}, { className: 'link', disabled: setup.busy })}</div>` : ''}<p class="dialog-note">Approval applies only to the exact copy you allow. Gatekeeper and signature checks stay in force.</p>`;
}
function accountStep() {
  const working = busy('continueDownload', { id: dialogTarget });
  return `<form class="dialog-form" data-form="dialogContinue" ${keyAttr('dialog-account')}><p>Downloading needs a Steam account that owns Wallpaper Engine. Steam enforces that; this app does not check it.</p><label class="field">Steam login name<input data-input="account" type="text" autocomplete="username" autocapitalize="off" spellcheck="false" value="${escapeHTML(dialogAccount.account)}"${disabled(working)}></label><label class="check-label"><input type="checkbox" data-change="rememberSession"${checked(dialogAccount.rememberSession)}${disabled(working)}>Keep me signed in on this Mac</label>${state.savedAccount ? `<p class="dialog-note">Saved sign-in on this Mac: ${escapeHTML(state.savedAccount)}${dialogAccount.account.trim().toLowerCase() === String(state.savedAccount).trim().toLowerCase() ? ' · will be reused' : ''}</p>` : ''}<div class="dialog-actions"><button type="submit" class="primary"${disabled(working || !dialogAccount.account.trim())}>${icon('chevronRight')}<span class="button-label">Continue</span></button>${button('Not now', 'dismissDialog', {}, { className: 'quiet' })}</div><p class="dialog-note">Passwords and Steam Guard codes are asked for only when Steam requests them, go straight to the private SteamCMD session, and are never saved by this app.</p></form>`;
}
function resourcesStep() {
  const settings = state.settings || {};
  return `<p>Scene wallpapers need shared shaders and materials from a purchased Wallpaper Engine installation. Video wallpapers do not.</p><p class="notice warning">Steam downloads the full Windows build into temporary storage first — keep several gigabytes free — and only the shared resources are kept afterwards. No Windows program is ever run.</p>${settings.sceneAssetsWarning ? `<p class="notice warning">${escapeHTML(settings.sceneAssetsWarning)}</p>` : ''}${settings.sceneAssetsReady ? '<p class="dialog-status" role="status">Shared resources are already installed. Downloading again replaces them.</p>' : ''}<div class="dialog-actions">${button('Download shared resources', 'consentResources', { id: dialogTarget }, { icon: 'download', className: 'primary', disabled: busy('continueDownload', { id: dialogTarget }) })}${button('Locate an installation', 'locateAssets', {}, { icon: 'folder', disabled: state.setup?.busy })}${button('Not now', 'dismissDialog', {}, { className: 'quiet' })}</div><p class="dialog-note">Locating an existing installation skips the download entirely.</p>`;
}
function authStep(job) {
  const hint = challengeHint(job.challenge);
  const working = busy('downloadInput', { id: job.id });
  const waiting = !job.prompt && !job.challenge;
  const account = job.account || dialogAccount?.account || '';
  const identity = `<div class="dialog-identity"><p>Signing in as <span class="dialog-account">${escapeHTML(account || 'an unnamed account')}</span></p>${button('Change account', 'changeAccount', { id: job.id }, { className: 'link' })}</div>`;
  return `<p class="dialog-status" role="status">${escapeHTML(job.status)}</p>${identity}${waiting ? '<p>Steam is being contacted. Any password or Steam Guard request appears here.</p><progress aria-label="Connecting to Steam"></progress>' : ''}${hint ? `<p class="notice">${escapeHTML(hint)}</p>` : ''}${job.error ? `<p class="notice error">${escapeHTML(job.error)}</p>` : ''}${job.warning ? `<p class="notice warning">${escapeHTML(job.warning)}</p>` : ''}${job.prompt ? `<form class="dialog-form" data-form="dialogAuth" data-id="${escapeHTML(job.id)}" ${keyAttr(`auth-${job.id}-${job.prompt}`)}><label class="field" for="dialog-response">${escapeHTML(job.prompt)}<input id="dialog-response" name="response" type="${job.securePrompt ? 'password' : 'text'}" autocomplete="off" spellcheck="false" autocapitalize="off" required${disabled(working)}></label><div class="dialog-actions"><button type="submit" class="primary"${disabled(working)}><span class="button-label">Submit</span></button>${button('Not now', 'dismissDialog', {}, { className: 'quiet' })}</div></form>` : `<div class="dialog-actions">${button('Not now', 'dismissDialog', {}, { className: 'quiet' })}</div>`}<div class="dialog-actions">${button('Cancel this download', 'downloadCancel', { id: job.id }, { className: 'quiet' })}${button('Steam Guard in the Steam mobile app', 'openExternal', { url: 'https://store.steampowered.com/mobile' }, { icon: 'external', className: 'link' })}</div><p class="dialog-note">Only approve sign-ins you started yourself. Never share your password or recovery codes.</p>`;
}
let importDuplicates = 'skip';
async function searchWorkshop() { clearTimeout(searchTimer); await send('workshopSearch', { ...workshopDraft, tags: [...workshopDraft.tags] }); }
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
  else if (job?.pending && !job.queued && (job.authenticating || job.prompt || job.challenge)) openDialog(target, element);
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
    case 'clearInstalled': Object.assign(installed, { kind: 'All types', favorites: false, active: false }); render(); return;
    case 'toggleSelect': toggleSelection(id); return;
    case 'toggleSelecting': selecting = !selecting; if (!selecting) { selection.clear(); selectionAnchor = null; } render(); return;
    case 'selectAllVisible': for (const item of visibleWallpapers()) selection.add(item.id); selectionAnchor ??= [...selection][0] ?? null; renderGrid(false); return;
    case 'clearSelection': selection.clear(); selectionAnchor = null; renderGrid(false); return;
    case 'deleteSelected': if (selection.size) await send('deleteMany', { ids: [...selection] }); return;
    case 'clearWorkshopSearch': workshopDraft.text = ''; // falls through to reset filters
    case 'clearWorkshop': workshopDraft.kind = 'All types'; workshopDraft.tags = []; render(); await searchWorkshop(); return;
    case 'showInstalled': await send('navigate', { page: 'installed' }); await send('select', { id }); return;
    case 'clearProperty': await send('property', { id, propertyID: data.propertyId, value: '' }); return;
    case 'restoreProperty': drafts.delete(draftKey(id, data.propertyId)); await send(action, { id, propertyID: data.propertyId }); return;
    case 'revert': for (const key of drafts.keys()) if (key.startsWith(`${id}\u0000`)) drafts.delete(key); await send(action, { id }); return;
    case 'apply':
      for (const [key, value] of [...drafts]) if (key.startsWith(`${id}\u0000`)) { await send('property', { id, propertyID: key.split('\u0000')[1], value }); if (drafts.get(key) === value) drafts.delete(key); }
      await send(action, { id }); return;
    case 'navigate': await send(action, { page: data.page }); return;
    case 'refreshWorkshop': await searchWorkshop(); return;
    case 'toggleWorkshopFilters': await send('workshopFilters', { collapsed: !state.workshopFiltersCollapsed }); return;
    case 'workshopPage': await send(action, { page: Number(data.workshopPage) }); $('wallpaper-grid').scrollTop = 0; return;
    case 'openExternal': await send(action, { url: data.url }); return;
    case 'import': await send(action, { duplicates: importDuplicates }); return;
    case 'forgetAccount': await send(action); if (dialogAccount) dialogAccount.account = ''; render(); return;
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
  if (event.target.closest('#settings-content')) return;
  const control = event.target.closest('[data-action]');
  if (!control) {
    const tab = event.target.closest('.tabs [data-page]');
    if (tab) { run(send('navigate', { page: tab.dataset.page })); return; }
  }
  if (control && !control.disabled) {
    // Modifier clicks on installed tiles build a selection instead of changing the inspector.
    if (control.matches('.tile-select') && state?.page === 'installed' && (selecting || event.metaKey || event.ctrlKey || event.shiftKey)) { toggleSelection(control.dataset.id, { range: event.shiftKey }); return; }
    // Apply on the second click instead of starting another selection request first.
    const action = control.matches('.tile-select') && state?.page === 'installed' && event.detail === 2
      ? 'activate' : control.dataset.action;
    run(handleAction(action, control.dataset, control));
  }
  const openFilter = document.querySelector('.installed-filter[open]');
  if (openFilter && !openFilter.contains(event.target)) openFilter.open = false;
  if (popover && !event.target.closest('#queue-popover, #import-popover') && !['openDownloads', 'openImport'].includes(control?.dataset.action)) closePopover(false);
});
document.addEventListener('input', event => {
  const element = event.target;
  if (element.closest('#settings-content')) return;
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
  if (element.closest('#settings-content')) return;
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
  } else if (change === 'sort') { if (state.page === 'discover') { workshopDraft.sort = value; run(searchWorkshop()); } else { installed.sort = value; render(); } }
  else if (change === 'installedKind') { installed.kind = value; render(); }
  else if (change === 'installedFavorites') { installed.favorites = value; render(); }
  else if (change === 'installedActive') { installed.active = value; render(); }
  else if (change === 'workshopKind') { workshopDraft.kind = value; renderFilters(); run(searchWorkshop()); }
  else if (change === 'workshopTag') { workshopDraft.tags = element.checked ? [...new Set([...workshopDraft.tags, element.value])] : workshopDraft.tags.filter(tag => tag !== element.value); renderFilters(); run(searchWorkshop()); }
  else if (change === 'rememberSession' && dialogAccount) { dialogAccount.rememberSession = value; renderDialog(); }
});
document.addEventListener('submit', event => {
  const form = event.target;
  if (form.closest('#settings-content')) return;
  event.preventDefault();
  if (form.dataset.form === 'search' && state.page === 'discover') run(searchWorkshop());
  if (form.dataset.form === 'workshopPage' && state.page === 'discover') {
    const input = form.elements.page;
    const pages = Math.max(1, Number(state.workshop.totalPages) || 1);
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
// Inspector edge: drag to resize, double-click to return to the fluid width. The width is
// applied locally while dragging and sent natively once, on release, so the choice persists.
let inspectorResizing = false;
function applyInspectorWidth(width) {
  if (inspectorResizing) return;
  const page = $('library-page');
  const resizer = $('inspector-resizer');
  if (Number.isFinite(width) && width > 0) {
    page.style.setProperty('--inspector-user-width', `${Math.round(width)}px`);
    page.classList.add('inspector-sized');
    resizer.setAttribute('aria-valuenow', String(Math.round(width)));
  } else {
    page.style.removeProperty('--inspector-user-width');
    page.classList.remove('inspector-sized');
    resizer.removeAttribute('aria-valuenow');
  }
}
function inspectorWidthNow() { return Math.round($('inspector').getBoundingClientRect().width); }
async function commitInspectorWidth(width) {
  inspectorResizing = false;
  $('library-page').classList.remove('inspector-resizing');
  applyInspectorWidth(width);
  await run(send('inspectorWidth', { width: Number.isFinite(width) ? Math.round(width) : null }));
}
{
  const resizer = $('inspector-resizer');
  let startX = 0; let startWidth = 0; let pointerID = null;
  resizer.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    event.preventDefault();
    pointerID = event.pointerId; startX = event.clientX; startWidth = inspectorWidthNow();
    inspectorResizing = true;
    $('library-page').classList.add('inspector-resizing');
    try { resizer.setPointerCapture(pointerID); } catch { /* synthetic pointers have no capture */ }
  });
  resizer.addEventListener('pointermove', event => {
    if (!inspectorResizing || event.pointerId !== pointerID) return;
    const page = $('library-page');
    page.style.setProperty('--inspector-user-width', `${Math.round(startWidth + startX - event.clientX)}px`);
    page.classList.add('inspector-sized');
  });
  const finish = event => {
    if (!inspectorResizing || event.pointerId !== pointerID) return;
    pointerID = null;
    commitInspectorWidth(inspectorWidthNow());
  };
  resizer.addEventListener('pointerup', finish);
  resizer.addEventListener('pointercancel', finish);
  resizer.addEventListener('dblclick', () => { inspectorResizing = false; commitInspectorWidth(null); });
  resizer.addEventListener('keydown', event => {
    const step = event.shiftKey ? 48 : 16;
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); commitInspectorWidth(inspectorWidthNow() + (event.key === 'ArrowLeft' ? step : -step)); }
    else if (event.key === 'Home' || event.key === 'Backspace') { event.preventDefault(); commitInspectorWidth(null); }
  });
}
document.addEventListener('keydown', event => {
  if (event.target.closest('#settings-content')) return;
  if (event.key === 'Escape') {
    const disclosure = document.querySelector('.installed-filter[open]');
    if (disclosure) { disclosure.open = false; disclosure.querySelector('summary').focus(); }
    else if (popover) closePopover(true);
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
window.addEventListener('resize', () => { if (popover) renderPopover(); });
document.addEventListener('error', event => { if (event.target.tagName === 'IMG') { event.target.classList.add('failed'); event.target.style.visibility = 'hidden'; } }, true);
// Discover tiles show cached stills; the full animated preview streams only for the tile under the
// pointer (or keyboard focus), after a short dwell so sweeping across the grid downloads nothing.
function animateTile(id) {
  clearTimeout(animateTimer); animateTimer = null;
  if (id === animatedID) return;
  if (id === null) { animatedID = null; if (state?.page === 'discover') renderGrid(true); return; }
  animateTimer = setTimeout(() => { animateTimer = null; if (state?.page !== 'discover') return; animatedID = id; renderGrid(true); }, 180);
}
function hoveredTile(target, related) {
  const tile = target.closest?.('.tile-select');
  if (!tile || (related && tile.contains(related))) return undefined;
  return tile;
}
$('wallpaper-grid').addEventListener('pointerover', event => { if (event.pointerType !== 'mouse') return; const tile = hoveredTile(event.target, event.relatedTarget); if (tile) animateTile(tile.dataset.id); });
$('wallpaper-grid').addEventListener('pointerout', event => { if (event.pointerType !== 'mouse') return; if (hoveredTile(event.target, event.relatedTarget)) animateTile(null); });
$('wallpaper-grid').addEventListener('focusin', event => { const tile = event.target.closest('.tile-select'); if (tile) animateTile(tile.dataset.id); });
$('wallpaper-grid').addEventListener('focusout', event => { if (event.target.closest('.tile-select') && !event.relatedTarget?.closest?.('.tile-select')) animateTile(null); });
// Tiles pulse their placeholder until the image arrives, so a slow connection reads as loading, not broken.
document.addEventListener('load', event => { if (event.target.tagName === 'IMG') event.target.classList.add('loaded'); }, true);
run(send('ready'));
