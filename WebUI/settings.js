import { t } from './i18n.js';

const views = new WeakMap();
// Labels below are English source strings; every one is passed through t() where it is drawn.
const sections = [['general', 'General'], ['appearance', 'Appearance'], ['performance', 'Performance'], ['displays', 'Displays'], ['library', 'Library & Steam'], ['storage', 'Storage'], ['about', 'About']];
const renderScales = [[1, '100% (native)'], [0.75, '75%'], [0.5, '50%']];
const videoBackends = [['compatibility', 'Compatibility'], ['native_preferred', 'Native video preferred (falls back automatically)']];
const sceneRenderers = [['compatibility', 'Compatibility'], ['native_metal_preferred', 'Native Metal preferred (falls back automatically)']];
// How a scene's video textures reached the shaders sampling them, as the
// renderer reported it. `none` is deliberately absent: a scene with no video
// has nothing to say, and naming it would read as a failure.
const videoPaths = {
  bgra: 'sampled directly, no conversion',
  nv12_direct: 'planes sampled directly, no conversion',
  nv12_converted: 'converted once per frame',
  nv12_mixed: 'planes sampled directly, plus one shared conversion',
  nv12_converted_preparing: 'converted once per frame, direct sampling still being prepared',
};
// The renderer's own words for why a scene is still updating. `unknown_input`
// is deliberately not folded into a generic phrase: it means the renderer found
// an input it could not account for and kept the scene running, which is the
// whole diagnosis when on-demand appears to do nothing.
const demandReasons = {
  script: 'a script', animation: 'animation', particles: 'particles', video: 'video',
  audio_response: 'audio response', time_uniform: 'a time-based effect',
  animated_sprite: 'an animated sprite', dynamic_mesh: 'a dynamic mesh', puppet: 'a puppet',
  feedback: 'a feedback pass', text_binding: 'bound text', sound: 'sound',
  node_binding: 'a bound node', unknown_input: 'an input the renderer could not account for',
  text_layout_pending: 'text still being laid out',
};
// Every mode the bridge can emit. `unknown` is a running scene that could not be
// read, which is not the same as one that is ticking, so it gets its own words.
const sceneModes = {
  continuous: 'updating continuously', waiting_for_event: 'waiting for events',
  waiting_for_deadline: 'waiting for a timer', user_paused: 'paused by you',
  policy_suspended: 'suspended by the app', not_applicable: 'not applicable to this wallpaper',
  unknown: 'running — state could not be read',
};
// Only backends that actually drew something are named here. A scene with no
// backend yet is a phase of its own and is worded separately below.
const sceneBackends = { legacy_vulkan: 'Compatibility', native_metal: 'Native Metal' };

// Reports the scale the engine actually published. Quantizing here would let a
// value the control cannot offer be shown as one that it can.
function percent(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${Math.round(number * 100)}%` : t('Unavailable');
}

// A hand-edited config may hold a scale between the offered tiers. Carry it as its
// own option so the control shows the saved value instead of snapping the display
// to a neighbouring tier the user never chose.
function scaleOptions(value) {
  const number = Number(value);
  const scales = renderScales.map(([step, label]) => [step, t(label)]);
  if (!Number.isFinite(number) || renderScales.some(([step]) => step === number)) return scales;
  return [[number, t('{percent} (from configuration)', { percent: percent(number) })], ...scales];
}
const localizedOptions = (entries) => entries.map(([id, label]) => [id, t(label)]);

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
  const settingToggle = (key, label, off = false, note = '') => row(key, t(label), toggle(key, t(label), draft(key, settings[key]), `data-setting="${key}"`, off || busy || unavailable), note);
  const paragraphs = (...texts) => texts.map(text => `<p>${e(text)}</p>`).join('');
  const lockUnavailable = unavailable || settings.lockScreenStatus == null;
  // Language lives natively beside the theme, so it stays usable when renderer settings are unavailable.
  // Option names are each language's own name and are deliberately left untranslated.
  const languageState = state.language || {};
  const languageOptions = [['system', t('System (Auto)')], ...(languageState.options || []).map(option => [option.id, option.name])];
  const languageValue = draft('language', languageState.preference || 'system');
  const general = row('language', t('Language'), select('language', t('Language'), languageValue, languageOptions, 'data-language-setting', view.pending.has('language')), t('The interface switches at once. Menus and dialogs follow the next time you open the app.'))
    + `<div class="settings-group-gap"></div>`
    + settingToggle('launchAtLogin', 'Launch at login', !settings.launchAtLoginAvailable, !settings.launchAtLoginAvailable ? t('Move the app to Applications to enable.') : '')
    + settingToggle('pauseOnBattery', 'Pause on battery')
    + settingToggle('keepWindowsOnWallpaperClick', 'Keep windows in place when clicking the wallpaper', false, t('Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers.'))
    + `<div class="settings-group-gap"></div>`
    + settingToggle('lockScreenEnabled', 'Animate lock screen', lockUnavailable || settings.lockScreenBusy, t('Experimental'))
    + row('lock-status', t('Lock screen status'), `<span class="settings-status" role="status">${e(lockUnavailable ? t('Unavailable') : settings.lockScreenBusy ? `${settings.lockScreenStatus || t('Updating')}…` : settings.lockScreenStatus)}</span>${settings.lockScreenError ? button(t('Retry'), 'lockScreenRetry', {}, busy || settings.lockScreenBusy) : ''}`)
    + error('lock-error', settings.lockScreenError)
    + disclosure('lock-context', t('Compatibility & permissions'), paragraphs(t('Lock-screen animation uses private macOS wallpaper APIs and may stop working after an OS update. It replaces the Desktop and Idle provider on active wallpaper displays and reloads the wallpaper service. Disabling or quitting restores choices still owned by this app; other wallpaper changes are preserved.'), t('Isolated asset copies need additional disk space. Rendering is not guaranteed on every macOS release. Playback respects pause and battery settings.')));

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
  const displayName = (name, id) => name || t('Display {id}', { id });
  const backendLine = report => `${displayName(report.displayName, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId}: ${report.backend}${report.fallbackReason ? ` ${t('(fallback: {reason})', { reason: report.fallbackReason })}` : ''}`;
  const backendReport = (settings.videoBackends || []).map(report => `<li>${e(backendLine(report))}</li>`).join('');
  // `no_frame_yet` is not a content reason — the scene simply has not finished a
  // first frame — so it is reported as starting rather than listed as a cause.
  const sceneModeLine = report => {
    const where = `${displayName(report.display, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId || t('wallpaper')}`;
    const reasons = Array.isArray(report.reasons) ? report.reasons : [];
    if (reasons.includes('no_frame_yet')) return `${where}: ${t('starting — no frame drawn yet')}`;
    const named = reasons.map(reason => t(demandReasons[reason]) || reason);
    const mode = t(sceneModes[report.mode]) || t('state reported as {mode}', { mode: report.mode });
    return `${where}: ${mode}${named.length ? ` (${named.join(', ')})` : ''}`;
  };
  // Three separate facts, none of them the saved preference. No backend has been
  // reported yet means the scene is still being read and no backend has been
  // chosen — not that one was chosen and could not be named. A scene drawn by
  // Compatibility while Native Metal was preferred fell back, and the renderer's
  // own reason is shown when it supplied one; an absent reason is left absent
  // rather than filled in with a guess.
  const sceneRendererLine = report => {
    const where = `${displayName(report.display, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId || t('wallpaper')}`;
    if (!report.backend || report.backend === 'unknown') return `${where}: ${t('preparing — no backend chosen yet')}`;
    // A name this build does not know is still a backend that drew the scene,
    // so it is reported verbatim instead of being folded into preparing.
    const backend = t(sceneBackends[report.backend]) || report.backend;
    const fellBack = report.backend === 'legacy_vulkan' && settings.sceneRenderer === 'native_metal_preferred';
    // Only ever named when the renderer observed one: a scene with no video,
    // or one that has not drawn yet, reports `none` and says nothing here.
    const video = t(videoPaths[report.videoPath]);
    return `${where}: ${backend}${fellBack && report.fallbackReason ? ` ${t('(fell back: {reason})', { reason: report.fallbackReason })}` : ''}${video ? ` ${t('— video: {path}', { path: video })}` : ''}`;
  };
  const sceneModeReport = (settings.sceneUpdateModes || []).map(report => `<li>${e(sceneModeLine(report))}</li>`).join('');
  const sceneBackendReport = (settings.sceneRenderers || []).map(report => `<li>${e(sceneRendererLine(report))}</li>`).join('');
  // Read from what actually drew a scene, not from the preference: the note it
  // gates is only true of a surface that really is on the native backend.
  const nativeSceneRunning = (settings.sceneRenderers || []).some(report => report.backend === 'native_metal');
  // The saved preference and what is running are different facts. A scene the
  // renderer could not answer for is counted as unknown rather than as applied,
  // because "we could not tell" is not evidence that the setting took.
  const sceneOptimizationRows = (settings.sceneRenderers || []).filter(report => report.backend && report.backend !== 'unknown');
  const applied = sceneOptimizationRows.filter(report => report.optimizationApplied === true).length;
  const pending = sceneOptimizationRows.filter(report => report.optimizationApplied === false).length;
  const unknownApplied = sceneOptimizationRows.length - applied - pending;
  const savedState = settings.sceneOptimization ? t('Saved on') : t('Saved off');
  const total = sceneOptimizationRows.length;
  const sceneOptimizationStatus = total === 0
    ? ''
    : pending > 0
      ? t('{saved}; applying to {pending} of {total} running scenes on their next frame.', { saved: savedState, pending, total })
      : unknownApplied > 0
        ? t('{saved}; {applied} of {total} running scenes confirmed, the rest could not be read.', { saved: savedState, applied, total })
        : applied === 1 ? t('{saved} and in force on the running scene.', { saved: savedState }) : t('{saved} and in force on all {applied} running scenes.', { saved: savedState, applied });
  const noVideo = `<span class="settings-status" role="status">${e(t('No video wallpaper is running.'))}</span>`;
  const noScene = `<span class="settings-status" role="status">${e(t('No scene wallpaper is running.'))}</span>`;
  const performance = `<h3>${e(t('Video backend'))}</h3>`
    + row('video-backend', t('Video playback'), select('videoBackend', t('Video playback backend'), draft('videoBackend', settings.videoBackend), localizedOptions(videoBackends), 'data-setting="videoBackend"', busy || unavailable), t('Native uses the system video path where a wallpaper qualifies, and returns to Compatibility on its own where it does not.'))
    + row('video-backend-report', t('In use now'), backendReport ? `<ul class="settings-list">${backendReport}</ul>` : noVideo)
    + `<div class="settings-group-gap"></div><h3>${e(t('Render quality'))}</h3>`
    + row('render-scale', t('Internal render scale'), select('renderScale', t('Internal render scale'), draft('renderScale', preferredScale), scaleOptions(preferredScale), 'data-setting="renderScale" data-number', busy || unavailable || !scaleSupported), scaleSupported ? t('Changes the internal rendering resolution only. Output size, placement and composition are unchanged; a lower scale is rendered smaller and drawn to the same area.') : t('Not applicable to the wallpapers currently running'))
    + (scaleSupported && scaleOverridden ? row('render-scale-effective', t('Effective now'), `<span class="settings-status" role="status">${e(batteryActive ? t('{effective} — the battery profile is overriding your saved {saved}.', { effective: percent(settings.renderScale), saved: percent(settings.preferredRenderScale) }) : t('{effective} — your saved {saved} is not in force right now.', { effective: percent(settings.renderScale), saved: percent(settings.preferredRenderScale) }))}</span>`) : '')
    + `<div class="settings-group-gap"></div><h3>${e(t('Battery profile'))}</h3>`
    + settingToggle('batteryProfileEnabled', 'Use a reduced quality profile on battery', false, t('Off unless you turn it on. It is a quality tradeoff you choose: while on battery power the render scale and frame rate below replace your saved quality. No power saving is measured or promised.'))
    + (settings.batteryProfileEnabled ? row('battery-scale', t('Render scale on battery'), select('batteryRenderScale', t('Render scale on battery'), draft('batteryRenderScale', batteryScale), scaleOptions(batteryScale), 'data-setting="batteryRenderScale" data-number', busy || unavailable))
      + row('battery-fps', t('Frame rate on battery'), `<input class="settings-number" data-key="batteryTargetFps" type="number" inputmode="numeric" aria-label="${e(t('Frame rate on battery'))}" min="1" max="240" step="1" value="${e(draft('batteryTargetFps', settings.batteryTargetFps))}" data-setting="batteryTargetFps"${disabled(busy || unavailable)}><span class="settings-unit">fps</span>`)
      + row('battery-state', t('Power source'), `<span class="settings-status" role="status">${e(batteryActive ? t('On battery — the battery profile is supplying the effective quality shown above.') : settings.onBatteryPower ? t('On battery') : t('Plugged in — your saved quality is in use.'))}</span>`) : '')
    + `<div class="settings-group-gap"></div><h3>${e(t('Scene wallpapers'))}</h3>`
    + settingToggle('sceneOptimization', 'Scene render optimisation', false, `${t('On by default. Reuses the result of scene subgraphs whose inputs have not changed and removes render passes proven redundant. It applies to scene wallpapers on both renderers — Compatibility and Native Metal — and takes effect on the next frame in both directions, changing neither resolution, frame rate nor animation speed. Turn it off to compare.')}${nativeSceneRunning ? ` ${t('Which targets qualify depends on the scene, so a scene with nothing still in it saves nothing on either renderer.')}` : ''}`)
    + (sceneOptimizationStatus ? row('scene-optimization-state', t('In force now'), `<span class="settings-status" role="status">${e(sceneOptimizationStatus)}</span>`) : '')
    + settingToggle('sceneOnDemand', 'Update only when the scene changes', false, t('Off unless you turn it on. A scene the renderer can prove has nothing left to update stops its repeating frame timer and wakes on events instead; anything it cannot prove keeps running normally. It is not a frame-rate limit, and scripts, sound and input keep working. No power saving is measured or promised.'))
    + row('scene-update-report', t('Updating now'), sceneModeReport ? `<ul class="settings-list">${sceneModeReport}</ul>` : noScene)
    + row('scene-renderer', t('Scene renderer'), select('sceneRenderer', t('Scene renderer'), draft('sceneRenderer', settings.sceneRenderer), localizedOptions(sceneRenderers), 'data-setting="sceneRenderer"', busy || unavailable), t('Native Metal draws only scenes it can draw in full: image layers, sprite-sheet animation, two-dimensional puppets deformed by their own skinning shader, two-dimensional sprite, sprite-trail, rope and rope-trail particles, perspective cameras for those layer types, ordinary effect chains and post-processing, same-frame layer links, and BGRA or 8-bit NV12 video textures. Anything else — lit particles, 3D models, dynamic lighting, history-feedback effects, HDR video and the rest — falls back to Compatibility as a whole scene, and this applies to desktop wallpapers only, the lock screen staying on Compatibility.'))
    + row('scene-renderer-report', t('Drawn by'), sceneBackendReport ? `<ul class="settings-list">${sceneBackendReport}</ul>` : noScene)
    + `<div class="settings-group-gap"></div><h3>${e(t('Advanced'))}</h3>`
    + settingToggle('contentPacing', 'Content pacing', false, t('Experimental, off by default. Drives presentation from the content’s own frame cadence instead of the display refresh.'))
    + settingToggle('sharedVideoDecode', 'Shared video decode', false, t('Experimental, off by default. Lets equivalent display surfaces showing the same video share one decode session.'))
    + settingToggle('sceneVideoPlaneSampling', 'Direct video plane sampling', false, t('Experimental, off by default. Inside a scene drawn by Native Metal, lets a layer\u2019s own shader read the decoder\u2019s two video planes instead of a colour image converted for it each frame. Only materials whose shader could be translated for it take part, and only while the decoder produces 8-bit NV12; everything else keeps converting, and nothing here changes which renderer draws a scene. The list above names the path each running scene actually took. No power saving is measured or promised.'))
    + (sessions || consumers ? row('shared-decode-report', t('Shared decode in use'), `<span class="settings-status" role="status">${e(t('{sessions} serving {surfaces}', { sessions: t(sessions === 1 ? '{count} session' : '{count} sessions', { count: sessions }), surfaces: t(consumers === 1 ? '{count} surface' : '{count} surfaces', { count: consumers }) }))}</span>`) : '')
    + disclosure('performance-context', t('What these settings change'), paragraphs(t('Video playback selects a backend per wallpaper. Native is only used where the wallpaper qualifies; anything else keeps playing on Compatibility, and the list above names the backend each running wallpaper actually got.'), t('Internal render scale is a quality tier, not a window or wallpaper size. It changes how many pixels are rasterized before the result is drawn into the same area, so text and detail soften as the scale drops.'), t('Scene render optimisation reuses work inside a scene’s own render graph. It is not a quality tier: the same pixels are produced, and nothing outside scene wallpapers is affected. Both scene renderers implement it, and neither reports a power saving — only that some passes were not run. The toggle is the saved preference; the line beneath it is read back from each running scene, so a change that has not reached a scene yet is visible as such instead of looking applied.'), t('Content pacing, shared video decode and direct video plane sampling are experimental and stay off until you enable them. Shared decode only merges work that is genuinely shared; surfaces still submit and present separately. Direct plane sampling removes a per-frame colour conversion where a layer\u2019s own shader can do the conversion while it samples; where it cannot, the conversion stays and the picture is produced exactly as before.')));

  // Theme preferences live natively and stay usable even when renderer settings are unavailable.
  const theme = { mode: 'system', accent: '#80bbff', tone: 'neutral', ...(window.__appTheme || {}), ...(state.theme || {}) };
  const themeKey = name => `theme-${name}`;
  const themeBusy = name => view.pending.has(themeKey(name)) || view.pending.has(themeKey('reset'));
  const themePending = ['mode', 'accent', 'tone', 'reset'].some(themeBusy);
  const themeValue = name => draft(themeKey(name), theme[name]);
  const accent = /^#[0-9a-f]{6}$/i.test(String(themeValue('accent'))) ? String(themeValue('accent')) : '#80bbff';
  const appearance = row(themeKey('mode-row'), t('Appearance'), select(themeKey('mode'), t('Appearance'), themeValue('mode'), localizedOptions([['system', 'System (Auto)'], ['light', 'Light'], ['dark', 'Dark']]), 'data-theme-setting="mode"', themeBusy('mode')), t('System follows the macOS light and dark setting.'))
    + row(themeKey('accent-row'), t('Accent color'), `<input data-key="${e(themeKey('accent'))}" type="color" aria-label="${e(t('Accent color'))}" value="${e(accent)}" data-theme-setting="accent"${disabled(themeBusy('accent'))}><output class="settings-hex" data-value-for="${e(themeKey('accent'))}">${e(accent.toUpperCase())}</output>`, t('Colors buttons, links and focus rings.'))
    + row(themeKey('tone-row'), t('Surface tone'), select(themeKey('tone'), t('Surface tone'), themeValue('tone'), localizedOptions([['neutral', 'Neutral'], ['warm', 'Warm'], ['cool', 'Cool']]), 'data-theme-setting="tone"', themeBusy('tone')), t('Warms or cools the window background.'))
    + row(themeKey('reset-row'), t('Theme defaults'), button(t('Reset appearance'), 'resetTheme', {}, themePending), t('Restores System, the default accent and Neutral tone.'))
    + `<p class="settings-footnote">${e(t('Appearance changes apply immediately and are remembered for next launch. They style this app’s interface only — wallpaper colors, playback and display settings are untouched.'))}</p>`;

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
    const name = label => t('{label} for {display}', { label, display: display.title });
    const wallpaper = (state.wallpapers || []).find(item => item.id === display.wallpaperID);
    const number = (field, label, min, max, step, suffix = '') => `<input class="settings-number" data-key="${e(key(field))}" type="number" inputmode="decimal" aria-label="${e(name(label))}" min="${min}"${max == null ? '' : ` max="${max}"`} step="${step}" value="${e(draft(key(field), playback[field]))}" ${data(field)}${disabled(playbackOff)}>${suffix ? `<span class="settings-unit">${e(suffix)}</span>` : ''}`;
    return `<div class="settings-display" data-key="display-${e(id)}"><h3>${e(display.title)}${primary ? `<span class="settings-note">${e(t('Primary display'))}</span>` : ''}</h3>`
      + row(key('enabled-row'), t('Enable wallpaper'), toggle(key('enabled'), name(t('Enable wallpaper')), draft(key('enabled'), display.enabled), data('enabled'), busy || primary))
      + row(key('mode-row'), t('Display mode'), select(key('mode'), name(t('Display mode')), draft(key('mode'), display.mode), localizedOptions([['standalone', 'Independent'], ['mirror', 'Mirror another display']]), data('mode'), off || primary))
      + (mirror ? row(key('target-row'), t('Mirror source'), select(key('mirrorTarget'), name(t('Mirror source')), draft(key('mirrorTarget'), display.mirrorTarget), [['', t('Choose display')], ...(display.mirrorTargets || []).map(target => [target.id, target.title])], data('mirrorTarget'), off || !display.mirrorTargets?.length), !display.mirrorTargets?.length ? t('No compatible display available.') : '') : row(key('wallpaper-row'), t('Wallpaper'), button(t('Choose…'), 'chooseDisplayWallpaper', { displayID: id }, off) + button(t('Eject'), 'eject', { id: display.wallpaperID, displayID: id }, off || !display.wallpaperID), wallpaper?.title || (display.wallpaperID ? display.wallpaperID : t('None selected'))))
      + disclosure(key('advanced'), t('Playback & scaling'), (!mirror && !display.wallpaperID ? `<div class="settings-note">${e(t('Choose a wallpaper to adjust playback.'))}</div>` : '') + row(key('scaling-row'), t('Scaling'), select(key('scalingMode'), name(t('Scaling')), draft(key('scalingMode'), playback.scalingMode), localizedOptions([['none', 'No scaling'], ['stretch', 'Stretch'], ['match', 'Match'], ['fill', 'Fill']]), data('scalingMode'), playbackOff))
        + row(key('factor-row'), t('Scale factor'), number('scalingFactor', t('Scale factor'), Number.MIN_VALUE, null, 'any', '×'))
        + row(key('fps-row'), t('Frame rate'), number('fps', t('Frame rate'), 1, playback.maxFps || 60, 1, 'fps'))
        + row(key('muted-row'), t('Mute audio'), toggle(key('muted'), name(t('Mute audio')), draft(key('muted'), playback.muted), data('muted'), playbackOff))
        + row(key('volume-row'), t('Volume'), `<input data-key="${e(key('volume'))}" type="range" aria-label="${e(name(t('Volume')))}" min="0" max="1" step="0.01" value="${e(draft(key('volume'), playback.volume))}" ${data('volume')}${disabled(playbackOff || playback.muted)}><output class="settings-unit" data-value-for="${e(key('volume'))}">${Math.round(Number(draft(key('volume'), playback.volume || 0)) * 100)}%</output>`)) + '</div>';
  }).join('') || `<div class="settings-empty">${e(t('No displays connected.'))}</div>`;

  const scenePending = Boolean(scene?.pending);
  const sceneRequest = (state.downloadRequests || []).find(request => request.id === 'scene-assets');
  const sceneAuth = scenePending && !scene.queued && Boolean(scene.prompt || scene.challenge || scene.authenticating);
  const setupLocked = busy || setup.busy || anyDownload;
  const setupControls = setup.busy ? button(t('Cancel installation'), 'setupCancel', {}, busy || setup.canCancel === false) : button(setup.candidatePath ? t('Continue installation') : setup.ready ? t('Reinstall…') : t('Install SteamCMD'), 'setupInstall', {}, setupLocked, !setup.ready ? 'settings-primary' : '') + button(t('Locate…'), 'setupLocate', {}, setupLocked);
  const candidate = setup.candidatePath ? row('candidate', t('Downloaded installation'), button(t('Show in Finder'), 'setupRevealCandidate', {}, busy) + button(t('Discard…'), 'setupDiscardCandidate', {}, setupLocked, 'settings-destructive'), setup.candidatePath) : '';
  const progress = setup.busy && Number.isFinite(setup.progress) ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, setup.progress))}" aria-label="${e(t('SteamCMD installation progress'))}"></progress>` : '';
  const sceneStatus = scene ? scene.status
    : sceneRequest ? sceneRequest.stage === 'setup' ? t('Waiting for SteamCMD setup.') : sceneRequest.stage === 'account' ? t('Waiting for your Steam sign-in.') : t('Waiting for your go-ahead on the download.')
      : settings.sceneAssetsReady ? t('Installed. Scene wallpapers can play.') : t('Not installed. Scene wallpapers cannot play yet.');
  // Downloading, signing in and Steam Guard all happen in the panel's download dialog; this is a summary with one way in.
  const sceneSummary = `<div class="settings-download" data-key="scene-resources" aria-busy="${scenePending}"><h3>${e(t('Shared scene resources'))}</h3><div class="settings-status" role="status">${e(sceneStatus)}</div>`
    + (scenePending ? `<progress class="settings-progress" max="1"${Number.isFinite(scene.progress) ? ` value="${Math.max(0, Math.min(1, scene.progress))}"` : ''} aria-label="${e(t('Shared resources download progress'))}"></progress>` : '')
    + error('scene-error', scene?.error)
    + (scene?.warning ? `<div class="settings-notice" role="status">${e(scene.warning)}</div>` : '')
    + `<div class="settings-form-actions">`
    + (sceneAuth ? button(t('Finish sign-in…'), 'openSceneDialog', {}, busy, 'settings-primary') : '')
    + (scenePending ? button(scene.queued ? t('Cancel queued download') : t('Cancel download'), 'downloadCancel', { id: scene.id }, busy) : '')
    + (!scenePending && sceneRequest ? button(t('Continue setup…'), 'openSceneDialog', {}, busy, 'settings-primary') + button(t('Remove request'), 'removeDownloadRequest', { id: sceneRequest.id }, busy, 'settings-destructive') : '')
    + (!scenePending && !sceneRequest ? button(settings.sceneAssetsReady ? t('Download again…') : t('Download from Steam…'), 'requestSceneAssets', {}, busy, 'settings-primary') : '')
    + (!scenePending ? button(t('Locate an installation…'), 'locateAssets', {}, busy || setup.busy) : '')
    + `</div><p class="settings-note">${e(t('Steam downloads the full Windows build into temporary storage — keep several gigabytes free — and only the shared resources are kept afterwards. No Windows program is ever run. Downloading needs a Steam account that owns Wallpaper Engine; Steam enforces that.'))}</p></div>`;
  const library = row('library-path', t('Wallpaper library'), button(t('Show in Finder'), 'showLibrary', {}, busy), settings.libraryPath || t('Unavailable'))
    + `<div class="settings-group-gap"></div><h3>SteamCMD</h3>`
    + row('steam-status', t('Installation'), `<span class="settings-status" role="status">${e(setup.status || (setup.ready ? t('Ready') : t('Not installed')))}</span>`)
    + progress + error('setup-error', setup.error)
    + `<div class="settings-form-actions">${setupControls}${setup.canApprove ? button(t('Allow this SteamCMD…'), 'setupApprove', {}, setupLocked) : ''}</div>`
    + candidate
    + (anyDownload && !setup.busy ? `<div class="settings-note">${e(t('Installation changes are unavailable while downloads are running.'))}</div>` : '')
    + `<div class="settings-group-gap"></div>`
    + row('assets-ready', t('Scene resources'), `<span class="settings-status">${e(settings.sceneAssetsReady ? t('Ready') : t('Not installed'))}</span>`)
    + (settings.sceneAssetsWarning ? `<div class="settings-notice" role="status">${e(settings.sceneAssetsWarning)}</div>` : '')
    + sceneSummary
    + row('steam-account', t('Steam account'), state.savedAccount ? button(t('Log out…'), 'logOutSteam', {}, anyDownload || busy, 'settings-destructive') : `<span class="settings-note">${e(t('Not signed in'))}</span>`, state.savedAccount ? `${t('Signed in as {account}', { account: state.savedAccount })}${anyDownload ? t(' · log out once downloads finish') : ''}` : t('You sign in when a download starts.'))
    + disclosure('library-context', t('Setup, compatibility & account privacy'), `${paragraphs(t('Scene wallpapers need shared resources from a purchased Wallpaper Engine installation. Videos do not. Locate its assets folder or download the shared assets once through Steam. Scene support is experimental; effects and scripts may differ from Windows.'), t('Steam downloads the Windows version to temporary storage; only shared assets are kept. Windows programs are never run. Allow several GB of temporary space. Imports are copied; original files and your Steam library stay untouched.'), t('SteamCMD is Valve’s download tool. Install it without signing in. Downloading requires a Steam account that owns Wallpaper Engine; Steam enforces access. Passwords and Steam Guard codes go directly to the private SteamCMD terminal and are not saved by this app. “Keep me signed in” saves Steam-issued sign-in cache on this Mac. Logging out removes only this Mac’s saved sign-in; other Steam devices stay signed in.'), t('Approve Steam Guard in the Steam mobile app, or enter the fresh code when requested. Steam may require a new sign-in after expiry or security changes. If Steam reports too many attempts, wait before retrying.'), t('Security approval applies only to the exact downloaded SteamCMD copy after native confirmation. It does not disable Gatekeeper or signature checks.'))}${settings.assetsPath ? `<div class="settings-path">${e(settings.assetsPath)}</div>` : ''}<div class="settings-help-links">${button(t('Wallpaper Engine on Steam'), 'openExternal', { url: 'https://store.steampowered.com/app/431960/Wallpaper_Engine/' })}${button(t('Rosetta installation'), 'openExternal', { url: 'https://support.apple.com/en-us/102527' })}${button(t('macOS app security'), 'openExternal', { url: 'https://support.apple.com/en-us/102445' })}</div>`);
  // Nil released-bytes means no purge has run this session; 0 means one ran and
  // found nothing. They read differently on purpose.
  const released = settings.userAssetsReleasedBytes;
  const storage = row('user-assets', t('Wallpaper files you chose'), button(t('Show in Finder'), 'revealUserAssets', {}, busy || unavailable) + button(t('Clear unused caches…'), 'purgeUnreferencedUserAssets', {}, busy || unavailable), settings.userAssetsPath || t('Unavailable'))
    + `<div class="settings-note" data-key="user-assets-note">${e(t('Files you pick for a wallpaper’s settings are copied here and kept. “Clear unused caches” removes only regenerable caches under this folder — never a file you imported.'))}${released == null ? '' : ` ${e(t('Last clear released {size}.', { size: bytes(released) }))}`}</div>`
    + `<div class="settings-group-gap"></div>`
    + row('shader-cache', t('Shader cache'), button(t('Clear…'), 'clearCache', {}, busy || unavailable || !settings.shaderCacheBytes), bytes(settings.shaderCacheBytes))
    + row('logs', t('Logs'), button(t('Show in Finder'), 'showLogs', {}, busy || unavailable) + button(t('Clear…'), 'clearLogs', {}, busy || unavailable || !settings.logBytes), bytes(settings.logBytes))
    + row('download-history', t('Completed downloads'), button(t('Clear history'), 'clearDownloads', {}, busy || !downloads.some(download => !download.pending)))
    + disclosure('storage-context', t('What gets removed'), paragraphs(t('Clearing the shader cache removes compiled shaders, including the compiled render pipelines kept alongside them. They are rebuilt as wallpapers load, which may temporarily slow playback. Clearing logs removes diagnostic history, not wallpapers or settings. Clearing download history keeps downloaded files.'), t('Files you chose for a wallpaper’s file or folder settings are copied into the managed folder above so they survive a cache clean and a wallpaper update. Nothing on this page deletes them; removing one means clearing that setting on the wallpaper itself.')));
  const versionRow = (id, label, value) => row(id, label, `<span class="settings-version">${e(value || t('Unavailable'))}</span>`);
  const update = state.update || {};
  const updateBusy = Boolean(update.busy) || ['checkForUpdates', 'downloadUpdate', 'installUpdate', 'openReleases', 'revealDownloadedUpdate'].some(action => view.pending.has(action));
  const updateProgress = update.status === 'downloading'
    ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, Number(update.percent || 0) / 100))}" aria-label="${e(update.progressLabel || t('Update download progress'))}"></progress>`
      + (Number(update.total) > 0 ? `<div class="settings-note">${e(t('{received} of {expected}', { received: bytes(update.transferred), expected: bytes(update.total) }))}</div>` : '')
    : '';
  const updateActions = (update.showsAction && update.action ? button(update.actionLabel || t('Check for Updates'), update.action, {}, updateBusy || busy, update.status === 'available' || update.status === 'ready' ? 'settings-primary' : '') : '')
    + (update.showsReleases ? button(update.releasesLabel || t('Open GitHub Releases'), 'openReleases', {}, updateBusy) : '')
    + (update.showsReveal ? button(update.revealLabel || t('Show in Finder'), 'revealDownloadedUpdate', {}, updateBusy) : '');
  const about = `<div class="settings-product"><h3>MacWallpaperEngine</h3><span class="settings-note">${e(t('Independent macOS client'))}</span></div>`
    + versionRow('app-version', t('App version'), state.version)
    + versionRow('bridge-version', t('Bridge'), settings.bridgeVersion)
    + versionRow('core-version', t('Core'), settings.coreVersion)
    + versionRow('shader-version', t('Shader pipeline'), settings.shaderVersion)
    + versionRow('git-version', t('Git revision'), settings.gitSha)
    + `<div class="settings-group-gap"></div>`
    + `<div class="settings-download" data-key="about-updates" aria-busy="${updateBusy}"><h3>${e(t('Updates'))}</h3><div class="settings-status" role="status" aria-live="polite">${e(update.statusText || t('Updates not yet checked'))}</div>`
    + updateProgress
    + `<div class="settings-form-actions">${updateActions}</div>`
    + `<p class="settings-note">${e(update.footnote || t('Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm.'))}</p></div>`
    + `<div class="settings-group-gap"></div>`
    + row('renderer-source', t('Scene renderer'), button('bigsaltyfishes / Wallpaper Engine for macOS', 'openExternal', { url: 'https://github.com/bigsaltyfishes/wallpaper-engine-for-macos.git' }))
    + `<div class="settings-attribution">${e(t('Not affiliated with Wallpaper Engine or Valve. Built on the GPLv2-only open-source renderer. Workshop browsing is independently implemented. No warranty is provided.'))}</div>`
    + button(t('GNU General Public License v2'), 'openExternal', { url: 'https://www.gnu.org/licenses/old-licenses/gpl-2.0.html' });
  const html = `<div class="settings-layout" data-key="settings-layout"><nav class="settings-nav" aria-label="${e(t('Settings categories'))}" role="tablist" aria-orientation="vertical" data-key="settings-nav">${sections.map(([id, title]) => `<button type="button" id="settings-tab-${id}" role="tab" aria-selected="${id === view.section}" aria-controls="settings-${id}" tabindex="${id === view.section ? '0' : '-1'}" data-key="nav-${id}" data-section="${id}">${e(t(title))}</button>`).join('')}</nav><div class="settings-scroll" data-key="settings-scroll">${error('settings-action-error', view.error || state.error)}${unavailable ? `<div class="settings-notice" role="status">${e(t('Settings are unavailable. Try refreshing the library.'))}</div>` : ''}${section('general', t('General'), general)}${section('appearance', t('Appearance'), appearance)}${section('performance', t('Performance'), performance)}${section('displays', t('Displays'), displays, button(t('Refresh'), 'refreshDisplays', {}, busy))}${section('library', t('Library & Steam'), library)}${section('storage', t('Storage'), storage)}${section('about', t('About'), about)}</div></div>`;
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
  if (input.dataset.languageSetting !== undefined) {
    view.drafts.set('language', input.value);
    await perform(view, 'language', 'languageSetting', { value: String(input.value) });
    view.drafts.delete('language');
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
  if (!Number.isFinite(value)) return t('Unavailable');
  if (value < 1024) return `${value} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let size = value / 1024;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
  return `${size.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[unit]}`;
}
