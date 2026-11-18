const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const dns = require('node:dns/promises');
const net = require('node:net');

const port = Number(process.env.PORT) || 4173;
const host = process.env.HOST || '127.0.0.1';
const root = __dirname;
const api = 'https://hn.algolia.com/api/v1';
const hnApi = 'https://hacker-news.firebaseio.com/v0';

function send(res, status, body, type = 'application/json; charset=utf-8') {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': type.startsWith('text/html') ? 'no-cache' : 'public, max-age=60',
    'x-content-type-options': 'nosniff',
  });
  res.end(body);
}

async function getJson(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(12000) });
  if (!response.ok) throw new Error(`News service returned ${response.status}`);
  return response.json();
}

function publicAddress(address) {
  if (net.isIP(address) === 4) {
    const parts = address.split('.').map(Number);
    return !(parts[0] === 0 || parts[0] === 10 || parts[0] === 127 ||
      parts[0] >= 224 || (parts[0] === 169 && parts[1] === 254) ||
      (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] === 192 && parts[1] === 168) ||
      (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) ||
      (parts[0] === 192 && parts[1] === 0 && parts[2] <= 2) ||
      (parts[0] === 198 && [18, 19, 51].includes(parts[1])) ||
      (parts[0] === 203 && parts[1] === 0 && parts[2] === 113));
  }
  if (net.isIP(address) === 6) {
    const value = address.toLowerCase();
    if (value.startsWith('::ffff:')) return publicAddress(value.slice(7));
    return /^[23]/.test(value) && !value.startsWith('2001:db8:');
  }
  return false;
}

async function validateUrl(raw) {
  const url = new URL(raw);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
      !['', '80', '443'].includes(url.port) ||
      url.hostname.toLowerCase() === 'localhost' || url.hostname.endsWith('.local')) {
    throw new Error('This article URL cannot be opened in the reader');
  }
  const addresses = await dns.lookup(url.hostname, { all: true });
  if (!addresses.length || addresses.some(({ address }) => !publicAddress(address))) {
    throw new Error('This article URL cannot be opened in the reader');
  }
  return url;
}

async function getArticle(raw) {
  let target = raw;
  for (let i = 0; i < 4; i++) {
    const url = await validateUrl(target);
    const response = await fetch(url, {
      redirect: 'manual',
      signal: AbortSignal.timeout(12000),
      headers: { 'user-agent': 'Mozilla/5.0 (compatible; SidecarReader/1.0)', accept: 'text/html' },
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      if (!location) throw new Error('Article redirect has no destination');
      target = new URL(location, url).href;
      continue;
    }
    if (!response.ok) throw new Error(`Article site returned ${response.status}`);
    if (!response.headers.get('content-type')?.toLowerCase().includes('text/html')) {
      throw new Error('This link is not an HTML article');
    }
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 2_000_000) {
        await reader.cancel();
        throw new Error('Article is too large for the reader');
      }
      chunks.push(value);
    }
    return { html: new TextDecoder().decode(Buffer.concat(chunks)), url: url.href };
  }
  throw new Error('Article redirected too many times');
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (req.method !== 'GET') return send(res, 405, JSON.stringify({ error: 'Method not allowed' }));
    if (url.pathname === '/' || url.pathname === '/index.html') {
      return send(res, 200, await fs.readFile(path.join(root, 'index.html')), 'text/html; charset=utf-8');
    }
    if (url.pathname === '/api/feed') {
      const newest = url.searchParams.get('view') === 'new';
      const requestedPage = Number(url.searchParams.get('page'));
      const page = Number.isInteger(requestedPage) && requestedPage >= 0 ? requestedPage : 0;
      if (!newest) {
        const pageSize = 15;
        const topStoryIds = await getJson(`${hnApi}/topstories.json`);
        const start = page * pageSize;
        const ids = topStoryIds.slice(start, start + pageSize);
        const items = await Promise.all(ids.map(id => getJson(`${hnApi}/item/${id}.json`)));
        const hits = items.filter(story => story?.type === 'story' && story.title).map(story => ({
          objectID: String(story.id),
          title: story.title,
          url: story.url || null,
          points: story.score ?? 0,
          author: story.by,
          created_at: new Date(story.time * 1000).toISOString(),
          num_comments: story.descendants ?? 0,
        }));
        return send(res, 200, JSON.stringify({ hits, hasMore: start + pageSize < topStoryIds.length }));
      }
      const data = await getJson(`${api}/search_by_date?tags=story&hitsPerPage=40&page=${page}`);
      return send(res, 200, JSON.stringify({ hits: data.hits, hasMore: page + 1 < data.nbPages }));
    }
    const item = url.pathname.match(/^\/api\/item\/(\d+)$/);
    if (item) return send(res, 200, JSON.stringify(await getJson(`${api}/items/${item[1]}`)));
    const article = url.pathname.match(/^\/api\/article\/(\d+)$/);
    if (article) {
      const story = await getJson(`${api}/items/${article[1]}`);
      if (!story.url) return send(res, 422, JSON.stringify({ error: 'This is a text post; read it in the discussion panel.' }));
      return send(res, 200, JSON.stringify(await getArticle(story.url)));
    }
    send(res, 404, JSON.stringify({ error: 'Not found' }));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    send(res, 502, JSON.stringify({ error: message }));
  }
});

server.listen(port, host, () => {
  console.log(`Sidecar running at http://${host}:${port}`);
});
