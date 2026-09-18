const views = new WeakMap();
const sections = [['general', 'General'], ['appearance', 'Appearance'], ['performance', 'Performance'], ['displays', 'Displays'], ['library', 'Library & Steam'], ['storage', 'Storage'], ['about', 'About']];
const renderScales = [[1, '100% (native)'], [0.75, '75%'], [0.5, '50%']];
const videoBackends = [['compatibility', 'Compatibility'], ['native_preferred', 'Native video preferred (falls back automatically)']];

// Reports the scale the engine actually published. Quantizing here would let a
// value the control cannot offer be shown as one that it can.
function percent(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${Math.round(number * 100)}%` : 'Unavailable';
}

// A hand-edited config may hold a scale between the offered tiers. Carry it as its
// own option so the control shows the saved value instead of snapping the display
// to a neighbouring tier the user never chose.
function scaleOptions(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || renderScales.some(([step]) => step === number)) return renderScales;
  return [[number, `${percent(number)} (from configuration)`], ...renderScales];
}

function scaleValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : renderScales[0][0];
}

export function renderSettings(container, state, helpers) {
  let view = views.get(container);
  if (!view) {
    view = { container, state, helpers, section: 'general', settingsSectionToken: NaN, drafts: new Map(), pending: new Set(), error: '' };
    views.set(container, view);
    container.addEventListener('click', event => onClick(view, event));
    container.addEventListener('input', event => onInput(view, event));
    container.addEventListener('change', event => onChange(view, event));
    container.addEventListener('keydown', event => {
      const target = event.target.closest('[data-section]');
      if (!target || !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const index = sections.findIndex(([id]) => id === view.section);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? sections.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + sections.length) % sections.length;
      view.section = sections[next][0];
      draw(view);
      container.querySelector(`[data-section="${view.section}"]`).focus();
    });
  }
  view.state = state;
  view.helpers = helpers;
  const token = Number(state.settingsSectionToken);
  if (Number.isFinite(token) && token !== view.settingsSectionToken) {
    view.settingsSectionToken = token;
    if (sections.some(([id]) => id === state.settingsSection)) view.section = state.settingsSection;
  }
  // Prerequisites, sign-in and Steam Guard live only in the panel's focused download dialog.
  draw(view);
}

function draw(view) {
  const { state, helpers, drafts } = view;
  const e = value => helpers.escapeHTML(String(value ?? ''));
  const settings = state.settings || {};
  const setup = state.setup || {};
  const downloads = state.downloads || [];
  const scene = downloads.find(download => download.id === 'scene-assets');
  const anyDownload = downloads.some(download => download.pending);
  const busy = Boolean(state.busy || view.pending.size);
  const unavailable = !state.settings;
  const disabled = value => value ? ' disabled' : '';
  const draft = (key, fallback) => drafts.has(key) ? drafts.get(key) : fallback;
  const attrs = (action, args = {}) => `data-action="${e(action)}" data-args="${e(JSON.stringify(args))}"`;
  const button = (label, action, args = {}, off = false, style = '') => `<button type="button" class="settings-button ${style}" ${attrs(action, args)}${disabled(off)}>${e(label)}</button>`;
  const row = (key, label, control, note = '') => `<div class="settings-row" data-key="${e(key)}"><div class="settings-label">${e(label)}${note ? `<span class="settings-note">${e(note)}</span>` : ''}</div><div class="settings-control">${control}</div></div>`;
  const toggle = (key, label, checked, data, off = false) => `<label class="settings-switch"><input data-key="${e(key)}" type="checkbox" role="switch" aria-label="${e(label)}" ${data}${checked ? ' checked' : ''}${disabled(off)}><span aria-hidden="true"></span></label>`;
  const select = (key, label, value, options, data, off = false) => `<select data-key="${e(key)}" aria-label="${e(label)}" ${data}${disabled(off)}>${options.map(([id, title]) => `<option value="${e(id)}"${String(value ?? '') === String(id) ? ' selected' : ''}>${e(title)}</option>`).join('')}</select>`;
  const error = (key, message) => message ? `<div class="settings-error" role="alert" data-key="${key}">${e(message)}</div>` : '';
  const disclosure = (key, title, content) => `<details class="settings-disclosure" data-key="${e(key)}"><summary>${helpers.icon('chevronRight', 12)}${e(title)}</summary><div class="settings-disclosure-body">${content}</div></details>`;
  const section = (id, title, content, action = '') => `<section class="settings-page" id="settings-${id}" role="tabpanel" aria-labelledby="settings-tab-${id}" tabindex="0" data-key="page-${id}"${view.section === id ? '' : ' hidden'}><header class="settings-heading"><h2>${e(title)}</h2>${action}</header>${content}</section>`;
  const settingToggle = (key, label, off = false, note = '') => row(key, label, toggle(key, label, draft(key, settings[key]), `data-setting="${key}"`, off || busy || unavailable), note);
  const lockUnavailable = unavailable || settings.lockScreenStatus == null;
  const general = settingToggle('launchAtLogin', 'Launch at login', !settings.launchAtLoginAvailable, !settings.launchAtLoginAvailable ? 'Move the app to Applications to enable.' : '')
    + settingToggle('pauseOnBattery', 'Pause on battery')
    + settingToggle('keepWindowsOnWallpaperClick', 'Keep windows in place when clicking the wallpaper', false, 'Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers.')
    + `<div class="settings-group-gap"></div>`
    + settingToggle('lockScreenEnabled', 'Animate lock screen', lockUnavailable || settings.lockScreenBusy, 'Experimental')
    + row('lock-status', 'Lock screen status', `<span class="settings-status" role="status">${e(lockUnavailable ? 'Unavailable' : settings.lockScreenBusy ? `${settings.lockScreenStatus || 'Updating'}…` : settings.lockScreenStatus)}</span>${settings.lockScreenError ? button('Retry', 'lockScreenRetry', {}, busy || settings.lockScreenBusy) : ''}`)
    + error('lock-error', settings.lockScreenError)
    + disclosure('lock-context', 'Compatibility & permissions', '<p>Lock-screen animation uses private macOS wallpaper APIs and may stop working after an OS update. It replaces the Desktop and Idle provider on active wallpaper displays and reloads the wallpaper service. Disabling or quitting restores choices still owned by this app; other wallpaper changes are preserved.</p><p>Isolated asset copies need additional disk space. Rendering is not guaranteed on every macOS release. Playback respects pause and battery settings.</p>');

  const scaleSupported = settings.renderScaleSupported !== false;
  // Compare what the engine published, not the quantized select step: disabling the
  // battery profile restores the saved scale on that same snapshot, and the override
  // notice has to disappear with it.
  const scaleOverridden = Number(settings.renderScale) !== Number(settings.preferredRenderScale);
  const preferredScale = scaleValue(settings.preferredRenderScale);
  const batteryScale = scaleValue(settings.batteryRenderScale);
  const batteryActive = Boolean(settings.batteryProfileEnabled && settings.onBatteryPower);
  const sessions = Number(settings.sharedVideoDecodeSessions) || 0;
  const consumers = Number(settings.sharedVideoDecodeConsumers) || 0;
  const plural = (count, noun) => `${count} ${noun}${count === 1 ? '' : 's'}`;
  const backendLine = report => `${report.displayName || `Display ${report.displayId}`} — ${report.wallpaperTitle || report.wallpaperId}: ${report.backend}${report.fallbackReason ? ` (fallback: ${report.fallbackReason})` : ''}`;
  const backendReport = (settings.videoBackends || []).map(report => `<li>${e(backendLine(report))}</li>`).join('');
  const performance = `<h3>Video backend</h3>`
    + row('video-backend', 'Video playback', select('videoBackend', 'Video playback backend', draft('videoBackend', settings.videoBackend), videoBackends, 'data-setting="videoBackend"', busy || unavailable), 'Native uses the system video path where a wallpaper qualifies, and returns to Compatibility on its own where it does not.')
    + row('video-backend-report', 'In use now', backendReport ? `<ul class="settings-list">${backendReport}</ul>` : '<span class="settings-status" role="status">No video wallpaper is running.</span>')
    + `<div class="settings-group-gap"></div><h3>Render quality</h3>`
    + row('render-scale', 'Internal render scale', select('renderScale', 'Internal render scale', draft('renderScale', preferredScale), scaleOptions(preferredScale), 'data-setting="renderScale" data-number', busy || unavailable || !scaleSupported), scaleSupported ? 'Changes the internal rendering resolution only. Output size, placement and composition are unchanged; a lower scale is rendered smaller and drawn to the same area.' : 'Not applicable to the wallpapers currently running')
    + (scaleSupported && scaleOverridden ? row('render-scale-effective', 'Effective now', `<span class="settings-status" role="status">${e(`${percent(settings.renderScale)}${batteryActive ? ` — the battery profile is overriding your saved ${percent(settings.preferredRenderScale)}.` : ` — your saved ${percent(settings.preferredRenderScale)} is not in force right now.`}`)}</span>`) : '')
    + `<div class="settings-group-gap"></div><h3>Battery profile</h3>`
    + settingToggle('batteryProfileEnabled', 'Use a reduced quality profile on battery', false, 'Off unless you turn it on. It is a quality tradeoff you choose: while on battery power the render scale and frame rate below replace your saved quality. No power saving is measured or promised.')
    + (settings.batteryProfileEnabled ? row('battery-scale', 'Render scale on battery', select('batteryRenderScale', 'Render scale on battery', draft('batteryRenderScale', batteryScale), scaleOptions(batteryScale), 'data-setting="batteryRenderScale" data-number', busy || unavailable))
      + row('battery-fps', 'Frame rate on battery', `<input class="settings-number" data-key="batteryTargetFps" type="number" inputmode="numeric" aria-label="Frame rate on battery" min="1" max="240" step="1" value="${e(draft('batteryTargetFps', settings.batteryTargetFps))}" data-setting="batteryTargetFps"${disabled(busy || unavailable)}><span class="settings-unit">fps</span>`)
      + row('battery-state', 'Power source', `<span class="settings-status" role="status">${e(batteryActive ? `On battery — the battery profile is supplying the effective quality shown above.` : settings.onBatteryPower ? 'On battery' : 'Plugged in — your saved quality is in use.')}</span>`) : '')
    + `<div class="settings-group-gap"></div><h3>Scene wallpapers</h3>`
    + settingToggle('sceneOptimization', 'Scene render optimisation', false, 'On by default. Reuses the result of scene subgraphs whose inputs have not changed and removes render passes proven redundant. It applies to legacy scene wallpapers only and changes neither resolution, frame rate nor animation speed. Turn it off to compare.')
    + `<div class="settings-group-gap"></div><h3>Advanced</h3>`
    + settingToggle('contentPacing', 'Content pacing', false, 'Experimental, off by default. Drives presentation from the content’s own frame cadence instead of the display refresh.')
    + settingToggle('sharedVideoDecode', 'Shared video decode', false, 'Experimental, off by default. Lets equivalent display surfaces showing the same video share one decode session.')
    + (sessions || consumers ? row('shared-decode-report', 'Shared decode in use', `<span class="settings-status" role="status">${e(`${plural(sessions, 'session')} serving ${plural(consumers, 'surface')}`)}</span>`) : '')
    + disclosure('performance-context', 'What these settings change', '<p>Video playback selects a backend per wallpaper. Native is only used where the wallpaper qualifies; anything else keeps playing on Compatibility, and the list above names the backend each running wallpaper actually got.</p><p>Internal render scale is a quality tier, not a window or wallpaper size. It changes how many pixels are rasterized before the result is drawn into the same area, so text and detail soften as the scale drops.</p><p>Scene render optimisation reuses work inside a scene’s own render graph. It is not a quality tier: the same pixels are produced, and nothing outside legacy scene wallpapers is affected. This control reports the saved preference, not a reading taken from the renderer.</p><p>Content pacing and shared video decode are experimental and stay off until you enable them. Shared decode only merges work that is genuinely shared; surfaces still submit and present separately.</p>');

  // Theme preferences live natively and stay usable even when renderer settings are unavailable.
  const theme = { mode: 'system', accent: '#80bbff', tone: 'neutral', ...(window.__appTheme || {}), ...(state.theme || {}) };
  const themeKey = name => `theme-${name}`;
  const themeBusy = name => view.pending.has(themeKey(name)) || view.pending.has(themeKey('reset'));
  const themePending = ['mode', 'accent', 'tone', 'reset'].some(themeBusy);
  const themeValue = name => draft(themeKey(name), theme[name]);
  const accent = /^#[0-9a-f]{6}$/i.test(String(themeValue('accent'))) ? String(themeValue('accent')) : '#80bbff';
  const appearance = row(themeKey('mode-row'), 'Appearance', select(themeKey('mode'), 'Appearance', themeValue('mode'), [['system', 'System (Auto)'], ['light', 'Light'], ['dark', 'Dark']], 'data-theme-setting="mode"', themeBusy('mode')), 'System follows the macOS light and dark setting.')
    + row(themeKey('accent-row'), 'Accent color', `<input data-key="${e(themeKey('accent'))}" type="color" aria-label="Accent color" value="${e(accent)}" data-theme-setting="accent"${disabled(themeBusy('accent'))}><output class="settings-hex" data-value-for="${e(themeKey('accent'))}">${e(accent.toUpperCase())}</output>`, 'Colors buttons, links and focus rings.')
    + row(themeKey('tone-row'), 'Surface tone', select(themeKey('tone'), 'Surface tone', themeValue('tone'), [['neutral', 'Neutral'], ['warm', 'Warm'], ['cool', 'Cool']], 'data-theme-setting="tone"', themeBusy('tone')), 'Warms or cools the window background.')
    + row(themeKey('reset-row'), 'Theme defaults', button('Reset appearance', 'resetTheme', {}, themePending), 'Restores System, the default accent and Neutral tone.')
    + `<p class="settings-footnote">Appearance changes apply immediately and are remembered for next launch. They style this app’s interface only — wallpaper colors, playback and display settings are untouched.</p>`;

  const displays = (state.displays || []).map(display => {
    const id = display.id;
    const primary = id === 'primary';
    const mirror = display.mode === 'mirror';
    const off = busy || !display.enabled;
    const playbackOff = off || (!mirror && !display.wallpaperID);
    const options = !mirror && state.options?.id === display.wallpaperID ? state.options : null;
    const config = options?.displays?.find(item => item.id === id);
    const playback = config ? { ...display, ...config, muted: options.muted, volume: options.volume } : display;
    const data = key => `data-display="${e(id)}" data-display-setting="${key}"`;
    const key = name => `display-${id}-${name}`;
    const name = label => `${label} for ${display.title}`;
    const wallpaper = (state.wallpapers || []).find(item => item.id === display.wallpaperID);
    const number = (field, label, min, max, step, suffix = '') => `<input class="settings-number" data-key="${e(key(field))}" type="number" inputmode="decimal" aria-label="${e(name(label))}" min="${min}"${max == null ? '' : ` max="${max}"`} step="${step}" value="${e(draft(key(field), playback[field]))}" ${data(field)}${disabled(playbackOff)}>${suffix ? `<span class="settings-unit">${e(suffix)}</span>` : ''}`;
    return `<div class="settings-display" data-key="display-${e(id)}"><h3>${e(display.title)}${primary ? '<span class="settings-note">Primary display</span>' : ''}</h3>`
      + row(key('enabled-row'), 'Enable wallpaper', toggle(key('enabled'), name('Enable wallpaper'), draft(key('enabled'), display.enabled), data('enabled'), busy || primary))
      + row(key('mode-row'), 'Display mode', select(key('mode'), name('Display mode'), draft(key('mode'), display.mode), [['standalone', 'Independent'], ['mirror', 'Mirror another display']], data('mode'), off || primary))
      + (mirror ? row(key('target-row'), 'Mirror source', select(key('mirrorTarget'), name('Mirror source'), draft(key('mirrorTarget'), display.mirrorTarget), [['', 'Choose display'], ...(display.mirrorTargets || []).map(target => [target.id, target.title])], data('mirrorTarget'), off || !display.mirrorTargets?.length), !display.mirrorTargets?.length ? 'No compatible display available.' : '') : row(key('wallpaper-row'), 'Wallpaper', button('Choose…', 'chooseDisplayWallpaper', { displayID: id }, off) + button('Eject', 'eject', { id: display.wallpaperID, displayID: id }, off || !display.wallpaperID), wallpaper?.title || (display.wallpaperID ? display.wallpaperID : 'None selected')))
      + disclosure(key('advanced'), 'Playback & scaling', (!mirror && !display.wallpaperID ? '<div class="settings-note">Choose a wallpaper to adjust playback.</div>' : '') + row(key('scaling-row'), 'Scaling', select(key('scalingMode'), name('Scaling'), draft(key('scalingMode'), playback.scalingMode), [['none', 'None'], ['stretch', 'Stretch'], ['match', 'Match'], ['fill', 'Fill']], data('scalingMode'), playbackOff))
        + row(key('factor-row'), 'Scale factor', number('scalingFactor', 'Scale factor', Number.MIN_VALUE, null, 'any', '×'))
        + row(key('fps-row'), 'Frame rate', number('fps', 'Frame rate', 1, playback.maxFps || 60, 1, 'fps'))
        + row(key('muted-row'), 'Mute audio', toggle(key('muted'), name('Mute audio'), draft(key('muted'), playback.muted), data('muted'), playbackOff))
        + row(key('volume-row'), 'Volume', `<input data-key="${e(key('volume'))}" type="range" aria-label="${e(name('Volume'))}" min="0" max="1" step="0.01" value="${e(draft(key('volume'), playback.volume))}" ${data('volume')}${disabled(playbackOff || playback.muted)}><output class="settings-unit" data-value-for="${e(key('volume'))}">${Math.round(Number(draft(key('volume'), playback.volume || 0)) * 100)}%</output>`)) + '</div>';
  }).join('') || '<div class="settings-empty">No displays connected.</div>';

  const scenePending = Boolean(scene?.pending);
  const sceneRequest = (state.downloadRequests || []).find(request => request.id === 'scene-assets');
  const sceneAuth = scenePending && !scene.queued && Boolean(scene.prompt || scene.challenge || scene.authenticating);
  const setupLocked = busy || setup.busy || anyDownload;
  const setupControls = setup.busy ? button('Cancel installation', 'setupCancel', {}, busy || setup.canCancel === false) : button(setup.candidatePath ? 'Continue installation' : setup.ready ? 'Reinstall…' : 'Install SteamCMD', 'setupInstall', {}, setupLocked, !setup.ready ? 'settings-primary' : '') + button('Locate…', 'setupLocate', {}, setupLocked);
  const candidate = setup.candidatePath ? row('candidate', 'Downloaded installation', button('Show in Finder', 'setupRevealCandidate', {}, busy) + button('Discard…', 'setupDiscardCandidate', {}, setupLocked, 'settings-destructive'), setup.candidatePath) : '';
  const progress = setup.busy && Number.isFinite(setup.progress) ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, setup.progress))}" aria-label="SteamCMD installation progress"></progress>` : '';
  const sceneStatus = scene ? scene.status
    : sceneRequest ? sceneRequest.stage === 'setup' ? 'Waiting for SteamCMD setup.' : sceneRequest.stage === 'account' ? 'Waiting for your Steam sign-in.' : 'Waiting for your go-ahead on the download.'
      : settings.sceneAssetsReady ? 'Installed. Scene wallpapers can play.' : 'Not installed. Scene wallpapers cannot play yet.';
  // Downloading, signing in and Steam Guard all happen in the panel's download dialog; this is a summary with one way in.
  const sceneSummary = `<div class="settings-download" data-key="scene-resources" aria-busy="${scenePending}"><h3>Shared scene resources</h3><div class="settings-status" role="status">${e(sceneStatus)}</div>`
    + (scenePending ? `<progress class="settings-progress" max="1"${Number.isFinite(scene.progress) ? ` value="${Math.max(0, Math.min(1, scene.progress))}"` : ''} aria-label="Shared resources download progress"></progress>` : '')
    + error('scene-error', scene?.error)
    + (scene?.warning ? `<div class="settings-notice" role="status">${e(scene.warning)}</div>` : '')
    + `<div class="settings-form-actions">`
    + (sceneAuth ? button('Finish sign-in…', 'openSceneDialog', {}, busy, 'settings-primary') : '')
    + (scenePending ? button(scene.queued ? 'Cancel queued download' : 'Cancel download', 'downloadCancel', { id: scene.id }, busy) : '')
    + (!scenePending && sceneRequest ? button('Continue setup…', 'openSceneDialog', {}, busy, 'settings-primary') + button('Remove request', 'removeDownloadRequest', { id: sceneRequest.id }, busy, 'settings-destructive') : '')
    + (!scenePending && !sceneRequest ? button(settings.sceneAssetsReady ? 'Download again…' : 'Download from Steam…', 'requestSceneAssets', {}, busy, 'settings-primary') : '')
    + (!scenePending ? button('Locate an installation…', 'locateAssets', {}, busy || setup.busy) : '')
    + `</div><p class="settings-note">Steam downloads the full Windows build into temporary storage — keep several gigabytes free — and only the shared resources are kept afterwards. No Windows program is ever run. Downloading needs a Steam account that owns Wallpaper Engine; Steam enforces that.</p></div>`;
  const library = row('library-path', 'Wallpaper library', button('Show in Finder', 'showLibrary', {}, busy), settings.libraryPath || 'Unavailable')
    + `<div class="settings-group-gap"></div><h3>SteamCMD</h3>`
    + row('steam-status', 'Installation', `<span class="settings-status" role="status">${e(setup.status || (setup.ready ? 'Ready' : 'Not installed'))}</span>`)
    + progress + error('setup-error', setup.error)
    + `<div class="settings-form-actions">${setupControls}${setup.canApprove ? button('Allow this SteamCMD…', 'setupApprove', {}, setupLocked) : ''}</div>`
    + candidate
    + (anyDownload && !setup.busy ? '<div class="settings-note">Installation changes are unavailable while downloads are running.</div>' : '')
    + `<div class="settings-group-gap"></div>`
    + row('assets-ready', 'Scene resources', `<span class="settings-status">${settings.sceneAssetsReady ? 'Ready' : 'Not installed'}</span>`)
    + (settings.sceneAssetsWarning ? `<div class="settings-notice" role="status">${e(settings.sceneAssetsWarning)}</div>` : '')
    + sceneSummary
    + row('saved-account', 'Saved Steam sign-in', state.savedAccount ? button('Forget account…', 'forgetAccount', {}, anyDownload || busy, 'settings-destructive') : '<span class="settings-note">None saved</span>', state.savedAccount || '')
    + disclosure('library-context', 'Setup, compatibility & account privacy', `<p>Scene wallpapers need shared resources from a purchased Wallpaper Engine installation. Videos do not. Locate its assets folder or download the shared assets once through Steam. Scene support is experimental; effects and scripts may differ from Windows.</p><p>Steam downloads the Windows version to temporary storage; only shared assets are kept. Windows programs are never run. Allow several GB of temporary space. Imports are copied; original files and your Steam library stay untouched.</p><p>SteamCMD is Valve’s download tool. Install it without signing in. Downloading requires a Steam account that owns Wallpaper Engine; Steam enforces access. Passwords and Steam Guard codes go directly to the private SteamCMD terminal and are not saved by this app. “Keep me signed in” saves Steam-issued sign-in cache on this Mac. Forgetting removes only this Mac’s saved sign-in.</p><p>Approve Steam Guard in the Steam mobile app, or enter the fresh code when requested. Steam may require a new sign-in after expiry or security changes. If Steam reports too many attempts, wait before retrying.</p><p>Security approval applies only to the exact downloaded SteamCMD copy after native confirmation. It does not disable Gatekeeper or signature checks.</p>${settings.assetsPath ? `<div class="settings-path">${e(settings.assetsPath)}</div>` : ''}<div class="settings-help-links">${button('Wallpaper Engine on Steam', 'openExternal', { url: 'https://store.steampowered.com/app/431960/Wallpaper_Engine/' })}${button('Rosetta installation', 'openExternal', { url: 'https://support.apple.com/en-us/102527' })}${button('macOS app security', 'openExternal', { url: 'https://support.apple.com/en-us/102445' })}</div>`);
  const storage = row('shader-cache', 'Shader cache', button('Clear…', 'clearCache', {}, busy || unavailable || !settings.shaderCacheBytes), bytes(settings.shaderCacheBytes))
    + row('logs', 'Logs', button('Show in Finder', 'showLogs', {}, busy || unavailable) + button('Clear…', 'clearLogs', {}, busy || unavailable || !settings.logBytes), bytes(settings.logBytes))
    + row('download-history', 'Completed downloads', button('Clear history', 'clearDownloads', {}, busy || !downloads.some(download => !download.pending)))
    + disclosure('storage-context', 'What gets removed', '<p>Clearing the shader cache removes compiled shaders. They are rebuilt as wallpapers load, which may temporarily slow playback. Clearing logs removes diagnostic history, not wallpapers or settings. Clearing download history keeps downloaded files.</p>');
  const versionRow = (id, label, value) => row(id, label, `<span class="settings-version">${e(value || 'Unavailable')}</span>`);
  const update = state.update || {};
  const updateBusy = Boolean(update.busy) || ['checkForUpdates', 'downloadUpdate', 'installUpdate', 'openReleases', 'revealDownloadedUpdate'].some(action => view.pending.has(action));
  const updateProgress = update.status === 'downloading'
    ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, Number(update.percent || 0) / 100))}" aria-label="${e(update.progressLabel || 'Update download progress')}"></progress>`
      + (Number(update.total) > 0 ? `<div class="settings-note">${e(bytes(update.transferred))} of ${e(bytes(update.total))}</div>` : '')
    : '';
  const updateActions = (update.showsAction && update.action ? button(update.actionLabel || 'Check for Updates', update.action, {}, updateBusy || busy, update.status === 'available' || update.status === 'ready' ? 'settings-primary' : '') : '')
    + (update.showsReleases ? button(update.releasesLabel || 'Open GitHub Releases', 'openReleases', {}, updateBusy) : '')
    + (update.showsReveal ? button(update.revealLabel || 'Show in Finder', 'revealDownloadedUpdate', {}, updateBusy) : '');
  const about = `<div class="settings-product"><h3>MacWallpaperEngine</h3><span class="settings-note">Independent macOS client</span></div>`
    + versionRow('app-version', 'App version', state.version)
    + versionRow('bridge-version', 'Bridge', settings.bridgeVersion)
    + versionRow('core-version', 'Core', settings.coreVersion)
    + versionRow('shader-version', 'Shader pipeline', settings.shaderVersion)
    + versionRow('git-version', 'Git revision', settings.gitSha)
    + `<div class="settings-group-gap"></div>`
    + `<div class="settings-download" data-key="about-updates" aria-busy="${updateBusy}"><h3>Updates</h3><div class="settings-status" role="status" aria-live="polite">${e(update.statusText || 'Updates not yet checked')}</div>`
    + updateProgress
    + `<div class="settings-form-actions">${updateActions}</div>`
    + `<p class="settings-note">${e(update.footnote || 'Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm.')}</p></div>`
    + `<div class="settings-group-gap"></div>`
    + row('renderer-source', 'Scene renderer', button('bigsaltyfishes / Wallpaper Engine for macOS', 'openExternal', { url: 'https://github.com/bigsaltyfishes/wallpaper-engine-for-macos.git' }))
    + `<div class="settings-attribution">Not affiliated with Wallpaper Engine or Valve. Built on the GPLv2-only open-source renderer. Workshop browsing is independently implemented. No warranty is provided.</div>`
    + button('GNU General Public License v2', 'openExternal', { url: 'https://www.gnu.org/licenses/old-licenses/gpl-2.0.html' });
  const html = `<div class="settings-layout" data-key="settings-layout"><nav class="settings-nav" aria-label="Settings categories" role="tablist" aria-orientation="vertical" data-key="settings-nav">${sections.map(([id, title]) => `<button type="button" id="settings-tab-${id}" role="tab" aria-selected="${id === view.section}" aria-controls="settings-${id}" tabindex="${id === view.section ? '0' : '-1'}" data-key="nav-${id}" data-section="${id}">${e(title)}</button>`).join('')}</nav><div class="settings-scroll" data-key="settings-scroll">${error('settings-action-error', view.error || state.error)}${unavailable ? '<div class="settings-notice" role="status">Settings are unavailable. Try refreshing the library.</div>' : ''}${section('general', 'General', general)}${section('appearance', 'Appearance', appearance)}${section('performance', 'Performance', performance)}${section('displays', 'Displays', displays, button('Refresh', 'refreshDisplays', {}, busy))}${section('library', 'Library & Steam', library)}${section('storage', 'Storage', storage)}${section('about', 'About', about)}</div></div>`;
  const template = document.createElement('template');
  template.innerHTML = html;
  reconcile(view.container, template.content);
}

// Keep live controls, selection, IME composition, scroll positions and disclosures intact.
function reconcile(parent, desired) {
  let cursor = parent.firstChild;
  for (const incoming of Array.from(desired.childNodes)) {
    const key = incoming.nodeType === Node.ELEMENT_NODE ? incoming.getAttribute('data-key') : null;
    let existing = key ? Array.from(parent.childNodes).find(node => node.nodeType === Node.ELEMENT_NODE && node.getAttribute('data-key') === key) : cursor;
    if (!existing || existing.nodeType !== incoming.nodeType || existing.nodeName !== incoming.nodeName || (!key && existing.nodeType === Node.ELEMENT_NODE && existing.hasAttribute('data-key'))) {
      existing = incoming.cloneNode(true);
      parent.insertBefore(existing, cursor);
    } else {
      if (existing !== cursor) parent.insertBefore(existing, cursor);
      if (existing.nodeType === Node.TEXT_NODE) {
        if (existing.data !== incoming.data) existing.data = incoming.data;
      } else if (existing.nodeType === Node.ELEMENT_NODE) {
        for (const attribute of Array.from(existing.attributes)) {
          if (attribute.name === 'open' && existing.tagName === 'DETAILS') continue;
          if (!incoming.hasAttribute(attribute.name)) existing.removeAttribute(attribute.name);
        }
        for (const attribute of incoming.attributes) {
          if (existing.getAttribute(attribute.name) !== attribute.value) existing.setAttribute(attribute.name, attribute.value);
        }
        if (existing.tagName === 'INPUT') {
          if (existing.type === 'checkbox') existing.checked = incoming.checked;
          else if (existing !== document.activeElement && existing.value !== incoming.value) existing.value = incoming.value;
        }
        reconcile(existing, incoming);
        if (existing.tagName === 'SELECT' && existing !== document.activeElement) existing.value = incoming.value;
      }
    }
    cursor = existing.nextSibling;
  }
  while (cursor) {
    const next = cursor.nextSibling;
    cursor.remove();
    cursor = next;
  }
}

function onInput(view, event) {
  const input = event.target;
  if (!input.matches('input[data-key]')) return;
  const key = input.dataset.key;
  view.drafts.set(key, input.type === 'checkbox' ? input.checked : input.value);
  if (input.dataset.local) draw(view);
  // Color pickers stream input events while the macOS picker is open; only the readout follows, never a redraw or a save.
  if (input.type === 'range' || input.type === 'color') {
    const output = Array.from(view.container.querySelectorAll('[data-value-for]')).find(node => node.dataset.valueFor === key);
    if (output) output.textContent = input.type === 'color' ? String(input.value).toUpperCase() : `${Math.round(Number(input.value) * 100)}%`;
  }
}

async function onChange(view, event) {
  const input = event.target;
  if (input.dataset.local) {
    view.drafts.set(input.dataset.key, input.type === 'checkbox' ? input.checked : input.value);
    draw(view);
    return;
  }
  if (input.dataset.themeSetting) {
    const themeDraft = input.dataset.key;
    view.drafts.set(themeDraft, input.value);
    await perform(view, themeDraft, 'themeSetting', { key: input.dataset.themeSetting, value: String(input.value) });
    view.drafts.delete(themeDraft);
    draw(view);
    return;
  }
  if (!input.dataset.setting && !input.dataset.displaySetting) return;
  let value = input.type === 'checkbox' ? input.checked : input.value;
  if (input.type === 'number' || input.type === 'range') {
    if (!input.checkValidity() || input.value.trim() === '' || !Number.isFinite(Number(input.value))) {
      input.reportValidity();
      return;
    }
    value = Number(value);
  }
  // A <select> always yields a string; numeric settings must reach Swift as numbers.
  if (input.dataset.number !== undefined && typeof value === 'string') {
    if (!Number.isFinite(Number(value))) return;
    value = Number(value);
  }
  if (input.dataset.displaySetting === 'mirrorTarget' && !value) return;
  const key = input.dataset.key;
  view.drafts.set(key, value);
  await perform(view, key, input.dataset.setting ? 'setting' : 'displaySetting', input.dataset.setting ? { key: input.dataset.setting, value } : { displayID: input.dataset.display, key: input.dataset.displaySetting, value }, () => view.drafts.delete(key));
  view.drafts.delete(key);
  draw(view);
}

async function onClick(view, event) {
  const tab = event.target.closest('[data-section]');
  if (tab) {
    view.section = tab.dataset.section;
    draw(view);
    view.container.querySelector('.settings-scroll').scrollTop = 0;
    return;
  }
  const button = event.target.closest('button[data-action]');
  if (!button || button.disabled) return;
  const action = button.dataset.action;
  const args = JSON.parse(button.dataset.args || '{}');
  if (action === 'resetTheme') {
    for (const draftKey of [...view.drafts.keys()]) if (draftKey.startsWith('theme-')) view.drafts.delete(draftKey);
    await perform(view, 'theme-reset', 'resetTheme', {});
    return;
  }
  if (action === 'chooseDisplayWallpaper') {
    await perform(view, 'choose-display', 'target', { id: args.displayID }, async () => {
      await view.helpers.send('navigate', { page: 'installed' });
    });
    return;
  }
  if (action === 'requestSceneAssets') { await view.helpers.requestAssets(button); return; }
  if (action === 'openSceneDialog') { view.helpers.openDownloadDialog('scene-assets', button); return; }
  await perform(view, action, action, args);
}

async function perform(view, key, action, args, after) {
  if (view.pending.has(key)) return;
  view.pending.add(key);
  view.error = '';
  draw(view);
  try {
    const state = await view.helpers.send(action, args);
    if (state) view.state = state;
    if (after) await after();
  } catch (error) {
    view.error = error instanceof Error ? error.message : String(error);
  } finally {
    view.pending.delete(key);
    draw(view);
  }
}

function bytes(value) {
  if (!Number.isFinite(value)) return 'Unavailable';
  if (value < 1024) return `${value} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let size = value / 1024;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
  return `${size.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[unit]}`;
}
