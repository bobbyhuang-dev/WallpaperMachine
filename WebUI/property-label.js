// Author markup is data, never panel markup. Parse in an inert template and rebuild
// only presentation nodes; even links and images receive app-owned attributes.
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const allowed = new Set(['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'div', 'span', 'center', 'b', 'strong', 'i', 'em', 'u', 's', 'small', 'big', 'sub', 'sup', 'br', 'hr', 'ul', 'ol', 'li']);
const excluded = new Set(['script', 'style', 'template', 'iframe', 'object', 'embed', 'svg', 'math', 'form', 'input', 'button', 'select', 'textarea', 'video', 'audio', 'source', 'link', 'meta', 'base']);
const cache = new Map();

function externalURL(value) {
  try {
    const url = new URL(value);
    const hosts = ['steamcommunity.com', 'store.steampowered.com', 'github.com', 'www.gnu.org', 'support.apple.com', 'space.bilibili.com', 'www.bilibili.com'];
    return url.protocol === 'https:' && !url.username && !url.password && !url.port && hosts.includes(url.hostname) ? url : null;
  } catch { return null; }
}
function imageAddress(value) {
  return typeof value === 'string' && /^mwe-ui:\/\/property-image\/[a-f0-9]{64}$/.test(value) ? value : '';
}
function dimension(value, percent = false) {
  const text = String(value || '').trim();
  if (percent && /^\d+(?:\.\d+)?%$/.test(text)) return `${Math.max(1, Math.min(100, parseFloat(text)))}%`;
  return /^\d+$/.test(text) && Number(text) > 0 ? String(Math.min(2048, Number(text))) : '';
}

export function renderPropertyLabel(property) {
  if (!property.labelHTML) return escapeHTML(property.label);
  const source = String(property.labelHTML).slice(0, 32768);
  const images = property.labelImages || {};
  const key = JSON.stringify([source, images]);
  if (cache.has(key)) return cache.get(key);
  const template = document.createElement('template');
  template.innerHTML = source;
  let remaining = 1000;
  const render = (node, depth = 0, linked = false) => {
    if (--remaining < 0 || depth > 24) return '';
    if (node.nodeType === Node.TEXT_NODE) return escapeHTML(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const tag = node.localName.toLowerCase();
    if (excluded.has(tag) || node.namespaceURI !== 'http://www.w3.org/1999/xhtml') return '';
    if (tag === 'img') {
      const raw = node.getAttribute('src') || '';
      const src = Object.hasOwn(images, raw) ? imageAddress(images[raw]) : '';
      const alt = node.getAttribute('alt') || '';
      if (!src) return escapeHTML(alt);
      const width = dimension(node.getAttribute('width'), true);
      const height = dimension(node.getAttribute('height'));
      return `<img src="${escapeHTML(src)}" alt="${escapeHTML(alt)}"${width ? ` width="${width}"` : ''}${height ? ` data-label-height="${height}"` : ''} loading="lazy" decoding="async" referrerpolicy="no-referrer">`;
    }
    const children = () => [...node.childNodes].map(child => render(child, depth + 1, linked || tag === 'a')).join('');
    if (tag === 'a') {
      const content = children();
      const url = externalURL(node.getAttribute('href'));
      if (!url || linked) return `<span class="author-accent">${content}</span>`;
      const name = node.textContent.trim() || node.querySelector('img')?.getAttribute('alt') || url.hostname;
      return `<button type="button" class="author-link" data-action="openExternal" data-url="${escapeHTML(url.href)}" aria-label="${escapeHTML(name)}">${content}</button>`;
    }
    if (tag === 'font') {
      const color = node.getAttribute('color') || '';
      const size = node.getAttribute('size') || '';
      return `<font${/^(#[a-f0-9]{3,8}|[a-z]{1,24})$/i.test(color) ? ` color="${escapeHTML(color)}"` : ''}${/^[1-7]$/.test(size) ? ` size="${size}"` : ''}>${children()}</font>`;
    }
    if (!allowed.has(tag)) return children();
    if (tag === 'br' || tag === 'hr') return `<${tag}>`;
    return `<${tag}>${children()}</${tag}>`;
  };
  const result = [...template.content.childNodes].map(node => render(node)).join('').trim();
  if (cache.size >= 256) cache.clear();
  cache.set(key, result);
  return result;
}
