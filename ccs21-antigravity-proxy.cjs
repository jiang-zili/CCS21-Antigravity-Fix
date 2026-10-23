'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const vm = require('node:vm');

// Known builds have pinned profiles. Later builds may use the complete,
// verified-compatible predicate below, regardless of minified symbol names.
const REVIEWED_BUNDLES = Object.freeze({
  '35f63c4b46aee4feb86e5997098b7baea5aea5223624ff373485afd0e07ba563': {
    version: '1.4.2', guard: 'function UNc(a,b=window.location.origin){if(!a||a==="null")return!1;',
  },
  'f7d226472f8562e9e3596a9ce8b155aa19b2f11648f94f0d45fcd09fd28abd98': {
    version: '1.4.3', guard: 'function PQc(a,b=window.location.origin){if(!a||a==="null")return!1;',
  },
});
const MAX_MAIN_JS_BYTES = 16 * 1024 * 1024;
const detectedProfiles = new Map();

// Accept the same origin-check algorithm after a backend update, independent
// of its minified function/variable names and HTTPS suffix allowlist. Match the
// complete predicate, not merely a version string or a function-name prefix.
function discoverOriginGuard(text) {
  const id = '[A-Za-z_$][A-Za-z0-9_$]*';
  const candidates = [...text.matchAll(new RegExp(
    'function\\s+(' + id + ')\\s*\\(\\s*(' + id + ')\\s*,\\s*(' + id + ')\\s*=\\s*window\\.location\\.origin\\s*\\)\\s*\\{' +
    '[\\s\\S]{0,4096}?\\}\\s*catch\\s*\\{\\s*return\\s*(?:!1|false)\\s*;?\\s*\\}\\s*\\}', 'g'))];
  const matches = [];
  for (const match of candidates) {
    const prefix = match[0].slice(0, match[0].indexOf('{') + 1);
    const locals = match[0].match(new RegExp('(?:let|const|var)\\s+(' + id + ')\\s*=\\s*new\\s+URL\\(\\s*' + match[2].replace(/\$/g,'\\$') + '\\s*\\)\\s*;'));
    const hostname = match[0].match(new RegExp('(?:let|const|var)\\s+(' + id + ')\\s*=\\s*(' + id + ')\\.hostname\\s*;'));
    if (!locals || !hostname || locals[1] !== hostname[2]) continue;
    const names = [match[1], match[2], match[3], locals[1], hostname[1]];
    if (new Set(names).size !== names.length) continue;
    const replacements = new Map(names.map((name, i) => [name, ['FN','VALUE','EXPECTED','URLVAR','HOST'][i]]));
    // Preserve string contents and property names when normalizing identifiers.
    let normalized = match[0].replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_$][A-Za-z0-9_$]*|\s+/g,
      (token, offset, source) => {
        if (/^\s+$/.test(token)) return '';
        // Only a complete quoted literal reaches this branch. Canonicalize
        // quote style without evaluating any part of the frontend bundle.
        if (/^["']/.test(token)) return JSON.stringify(vm.runInNewContext(token, Object.create(null), { timeout: 50 }));
        if (token === 'true') return '!0';
        if (token === 'false') return '!1';
        if (['var','const'].includes(token)) return 'let';
        return source[offset - 1] !== '.' && replacements.has(token) ? replacements.get(token) : token;
      });
    normalized = normalized.replace(/;\}/g, '}');
    const suffixes = /HOST\.endsWith\("(?:\.[a-z0-9-]+)+"\)(?:\|\|HOST\.endsWith\("(?:\.[a-z0-9-]+)+"\))*/g;
    normalized = normalized.replace(suffixes, 'HTTPS_SUFFIXES');
    const expected = 'functionFN(VALUE,EXPECTED=window.location.origin){if(!VALUE||VALUE==="null")return!1;' +
      'if(VALUE===EXPECTED||VALUE.startsWith("vscode-webview://")||VALUE.startsWith("vscode-file://"))return!0;' +
      'try{letURLVAR=newURL(VALUE);if(URLVAR.protocol!=="http:"&&URLVAR.protocol!=="https:")return!1;' +
      'letHOST=URLVAR.hostname;returnHOST==="localhost"||HOST==="127.0.0.1"||HOST==="[::1]"||HOST==="::1"?!0:' +
      'URLVAR.protocol==="https:"?HTTPS_SUFFIXES:!1}catch{return!1}}';
    if (normalized !== expected) continue;
    // Compile, without executing, the candidate and complete bundle.
    new vm.Script('(' + match[0] + ')');
    matches.push({ guard: prefix, valueName: match[2] });
  }
  if (matches.length !== 1) throw new Error('Backend origin-check structure changed; expected one compatible predicate, found ' + matches.length + '.');
  new vm.Script(text);
  return { ...matches[0], version: 'auto-detected', mode: 'structure-verified' };
}

function validateTheiaOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || url.username || url.password ||
      !/^[a-z0-9-]+\.webview\.localhost$/i.test(url.hostname) ||
      !url.port || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Expected one exact local Theia webview origin.');
  }
  return url.origin;
}

// CCS's WebviewImpl substitutes its actual origin/view ID into this URI.
// Never use cspSource here: it can contain a wildcard for all webviews.
function getTheiaWebviewOrigin(webview, resourceUri) {
  const resourceUrl = new URL(webview.asWebviewUri(resourceUri).toString());
  return validateTheiaOrigin(resourceUrl.origin);
}

function addExactFrameAncestor(policy, origin) {
  if (typeof policy !== 'string') throw new Error('Invalid backend CSP.');
  let found = false;
  const result = policy.split(';').map(directive => {
    if (!/^\s*frame-ancestors(?:\s|$)/i.test(directive)) return directive;
    found = true;
    const sources = directive.trim().split(/\s+/).slice(1);
    if (sources.includes("'none'") || sources.length === 0) {
      throw new Error('Backend CSP explicitly prohibits framing.');
    }
    const additions = [origin, 'file:'].filter(source => !sources.includes(source));
    return additions.length ? directive + ' ' + additions.join(' ') : directive;
  }).join(';');
  if (!found) throw new Error('Backend HTML is missing frame-ancestors protection.');
  return result;
}

function inspectAgyMainJs(body, reviewedBundles = REVIEWED_BUNDLES) {
  const source = Buffer.isBuffer(body) ? body : Buffer.from(body);
  if (source.length > MAX_MAIN_JS_BYTES) throw new Error('agy main.js exceeds supported size limit.');
  const sha256 = crypto.createHash('sha256').update(source).digest('hex');
  let profile = Object.prototype.hasOwnProperty.call(reviewedBundles, sha256) && reviewedBundles[sha256];
  if (!profile) {
    profile = detectedProfiles.get(sha256);
    if (!profile) {
      try { profile = discoverOriginGuard(source.toString('utf8')); }
      catch (error) { throw new Error('Unsupported agy origin-check structure; frontend SHA-256 ' + sha256 + '. ' + error.message); }
      if (detectedProfiles.size >= 16) detectedProfiles.delete(detectedProfiles.keys().next().value);
      detectedProfiles.set(sha256, profile);
    }
  }
  const text = source.toString('utf8');
  if (text.split(profile.guard).length !== 2) {
    throw new Error('Expected exactly one reviewed agy ' + profile.version + ' origin guard.');
  }
  return { version: profile.version, mode: profile.mode || 'hash-pinned', sha256, guard: profile.guard, valueName: profile.valueName || 'a' };
}

function adaptAgyMainJs(body, allowedOrigin, reviewedBundles = REVIEWED_BUNDLES) {
  const origin = validateTheiaOrigin(allowedOrigin);
  const profile = inspectAgyMainJs(body, reviewedBundles);
  const text = body.toString('utf8');
  return Buffer.from(text.replace(
    profile.guard,
    profile.guard + `if(${profile.valueName}===${JSON.stringify(origin)})return!0;`,
  ), 'utf8');
}

function validateBackendUrl(value) {
  const backend = new URL(value);
  if (backend.protocol !== 'http:' || backend.username || backend.password ||
      !['localhost', '127.0.0.1', '[::1]'].includes(backend.hostname) ||
      !backend.port || backend.pathname !== '/' || backend.search || backend.hash) {
    throw new Error('Expected a fixed HTTP loopback agy backend origin.');
  }
  return backend;
}

// Run before installing and on every new backend/view pair. Never accept a
// version string as proof: agy can update independently of the extension.
function checkBackend(backendUrl) {
  const backend = validateBackendUrl(backendUrl);
  return new Promise((resolve, reject) => {
    const request = http.get(new URL('/main.js', backend), {
      headers: { 'accept-encoding': 'identity' }, agent: false,
    }, response => {
      if (response.statusCode !== 200 ||
          !/^(?:application|text)\/(?:javascript|x-javascript)(?:\s*;|$)/i.test(String(response.headers['content-type'] || '')) ||
          (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity')) {
        response.resume(); reject(new Error('Cannot verify agy main.js response.')); return;
      }
      const chunks = [];
      let total = 0;
      response.on('data', chunk => {
        total += chunk.length;
        if (total > MAX_MAIN_JS_BYTES) response.destroy(new Error('agy main.js exceeds reviewed size limit.'));
        else chunks.push(chunk);
      });
      response.once('error', reject);
      response.once('end', () => {
        try { resolve(inspectAgyMainJs(Buffer.concat(chunks))); } catch (error) { reject(error); }
      });
    });
    request.setTimeout(8000, () => request.destroy(new Error('agy backend check timed out.')));
    const deadline = setTimeout(() => request.destroy(new Error('agy backend check deadline exceeded.')), 12000);
    request.once('close', () => clearTimeout(deadline));
    request.once('error', reject);
  });
}

/**
 * Adapt one agy backend for one exact CCS/Theia webview origin.
 * The backend target is fixed; all HTTP bodies, CSRF/auth headers, and WebSocket
 * traffic pass through unchanged. The HTML frame-ancestors directive and one
 * hash-pinned JavaScript message guard admit the exact origin. Binds to loopback.
 */
async function createCcsEmbedProxy({ backendUrl, allowedOrigin }) {
  const backend = validateBackendUrl(backendUrl);
  const origin = validateTheiaOrigin(allowedOrigin);

  const sockets = new Set();
  const upstreams = new Set();
  let closing = false;
  let closePromise;

  function requestOptions(req) {
    if (!req.url || !req.url.startsWith('/') || req.url.startsWith('//')) {
      throw new Error('Only relative backend paths are accepted.');
    }
    const headers = { ...req.headers };
    if (req.method === 'GET' && new URL(req.url, backend).pathname === '/main.js') {
      // The reviewed rewrite requires complete, uncompressed source bytes.
      headers['accept-encoding'] = 'identity';
      delete headers['if-none-match'];
      delete headers['if-modified-since'];
      delete headers['if-range'];
      delete headers.range;
    }
    return {
      hostname: backend.hostname === '[::1]' ? '::1' : backend.hostname,
      port: Number(backend.port),
      method: req.method,
      path: req.url,
      headers,
      agent: false,
    };
  }

  function trackUpstream(upstream) {
    upstreams.add(upstream);
    upstream.once('close', () => upstreams.delete(upstream));
    return upstream;
  }

  const server = http.createServer((req, res) => {
    if (closing) { res.writeHead(503).end(); return; }
    let options;
    try { options = requestOptions(req); }
    catch { res.writeHead(400).end(); return; }
    const adaptMainJs = req.method === 'GET' && new URL(req.url, backend).pathname === '/main.js';
    const upstream = trackUpstream(http.request(options, upstreamRes => {
      const headers = { ...upstreamRes.headers };
      if (adaptMainJs) {
        if (upstreamRes.statusCode !== 200 ||
            !/^(?:application|text)\/(?:javascript|x-javascript)(?:\s*;|$)/i.test(String(headers['content-type'] || '')) ||
            (headers['content-encoding'] && headers['content-encoding'] !== 'identity')) {
          upstreamRes.resume();
          res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end('The CCS adapter cannot verify this agy JavaScript response.');
          return;
        }
        const chunks = [];
        let total = 0;
        upstreamRes.on('data', chunk => {
          total += chunk.length;
          if (total > MAX_MAIN_JS_BYTES) {
            upstreamRes.destroy(new Error('agy main.js exceeds reviewed size limit.'));
          } else {
            chunks.push(chunk);
          }
        });
        upstreamRes.once('error', () => {
          if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end('The CCS adapter could not read agy JavaScript.');
        });
        upstreamRes.once('end', () => {
          let patched;
          try { patched = adaptAgyMainJs(Buffer.concat(chunks), origin); }
          catch (error) {
            console.error('[Antigravity CCS adapter]', error.message);
            res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end('The CCS adapter does not support this agy JavaScript version.');
            return;
          }
          for (const name of ['etag', 'last-modified', 'content-encoding',
            'transfer-encoding', 'content-range', 'accept-ranges', 'content-md5']) {
            delete headers[name];
          }
          headers['content-length'] = String(patched.length);
          headers['cache-control'] = 'no-store';
          res.writeHead(200, headers);
          res.end(patched);
        });
        return;
      }
      try {
        if (/^text\/html(?:\s*;|$)/i.test(String(headers['content-type'] || ''))) {
          const csp = headers['content-security-policy'];
          headers['content-security-policy'] = Array.isArray(csp)
            ? csp.map(policy => addExactFrameAncestor(policy, origin))
            : addExactFrameAncestor(csp, origin);
        }
      } catch {
        upstreamRes.destroy();
        res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end('The CCS adapter could not preserve the backend framing policy.');
        return;
      }
      res.writeHead(upstreamRes.statusCode || 502, headers);
      upstreamRes.pipe(res);
      res.once('close', () => upstreamRes.destroy());
    }));
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502).end();
      else res.destroy();
    });
    req.once('aborted', () => upstream.destroy());
    res.once('close', () => { if (!res.writableFinished) upstream.destroy(); });
    req.pipe(upstream);
  });

  server.on('connection', socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });

  server.on('upgrade', (req, socket, head) => {
    if (closing || String(req.headers.upgrade).toLowerCase() !== 'websocket') {
      socket.destroy(); return;
    }
    let options;
    try { options = requestOptions(req); }
    catch { socket.destroy(); return; }
    const upstream = trackUpstream(http.request(options));
    upstream.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
      sockets.add(upstreamSocket);
      upstreamSocket.once('close', () => sockets.delete(upstreamSocket));
      let response = `HTTP/${upstreamRes.httpVersion} ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n`;
      for (let i = 0; i < upstreamRes.rawHeaders.length; i += 2) {
        response += `${upstreamRes.rawHeaders[i]}: ${upstreamRes.rawHeaders[i + 1]}\r\n`;
      }
      socket.write(response + '\r\n');
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      socket.pipe(upstreamSocket).pipe(socket);
      socket.on('error', () => upstreamSocket.destroy());
      upstreamSocket.on('error', () => socket.destroy());
      socket.once('close', () => upstreamSocket.destroy());
      upstreamSocket.once('close', () => socket.destroy());
    });
    // Preserve rejection status and headers; never convert a rejected upgrade.
    upstream.on('response', upstreamRes => {
      let response = `HTTP/${upstreamRes.httpVersion} ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n`;
      for (let i = 0; i < upstreamRes.rawHeaders.length; i += 2) {
        response += `${upstreamRes.rawHeaders[i]}: ${upstreamRes.rawHeaders[i + 1]}\r\n`;
      }
      socket.write(response + '\r\n');
      upstreamRes.pipe(socket);
    });
    upstream.on('error', () => socket.destroy());
    socket.once('close', () => upstream.destroy());
    upstream.end();
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  server.unref();

  return {
    url: `http://127.0.0.1:${server.address().port}`,
    allowedOrigin: origin,
    dispose() {
      if (closePromise) return closePromise;
      closing = true;
      closePromise = new Promise(resolve => {
        server.close(resolve);
        for (const upstream of upstreams) upstream.destroy();
        for (const socket of sockets) socket.destroy();
      });
      return closePromise;
    },
  };
}

const proxiesByContext = new WeakMap();

async function getProxyUrl(backendUrl, allowedOrigin, context) {
  if (!context || !Array.isArray(context.subscriptions)) {
    throw new Error('Expected the extension context for proxy lifetime management.');
  }
  const origin = validateTheiaOrigin(allowedOrigin);
  const backendOrigin = new URL(backendUrl).origin;
  let cache = proxiesByContext.get(context);
  if (!cache) {
    cache = new Map();
    proxiesByContext.set(context, cache);
  }
  const key = backendOrigin + ' ' + origin;
  let pending = cache.get(key);
  if (!pending) {
    pending = checkBackend(backendUrl).then(profile => {
      console.log('[Antigravity CCS adapter] agy ' + profile.version + ', ' + profile.mode + ', SHA-256 ' + profile.sha256);
      return createCcsEmbedProxy({ backendUrl, allowedOrigin: origin });
    }).then(proxy => {
      context.subscriptions.push({ dispose: () => { void proxy.dispose(); } });
      return proxy;
    }).catch(error => {
      cache.delete(key);
      throw error;
    });
    cache.set(key, pending);
  }
  return (await pending).url;
}

module.exports = { getProxyUrl, createCcsEmbedProxy, getTheiaWebviewOrigin, adaptAgyMainJs, inspectAgyMainJs, checkBackend, discoverOriginGuard };

if (require.main === module) {
  if (process.argv.length === 4 && process.argv[2] === '--binary-version') {
    require('node:child_process').execFile(process.argv[3], ['--version'], {
      timeout: 5000, windowsHide: true,
    }, (error, stdout, stderr) => {
      const match = (String(stdout) + String(stderr)).match(/\d+\.\d+\.\d+[^\s]*/);
      console.log(match ? match[0] : 'unknown');
    });
  } else if (process.argv.length !== 4 || process.argv[2] !== '--check-backend') {
    console.error('Usage: node ccs21-antigravity-proxy.cjs --check-backend http://127.0.0.1:PORT');
    process.exitCode = 2;
  } else {
    checkBackend(process.argv[3]).then(({ version, mode, sha256 }) => {
      console.log(JSON.stringify({ compatible: true, version, mode, sha256 }));
    }).catch(error => { console.error(error.message); process.exitCode = 1; });
  }
}

