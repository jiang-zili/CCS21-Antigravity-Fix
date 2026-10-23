#requires -Version 5.1
<#
Detects extension/backend versions and repairs compatible renderer structures.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [string]$ProfileDir,
    [string[]]$SearchRoot,
    [string]$BackendUrl,
    [string]$ReportDir,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolVersion = '1.3.0'
if (-not $ReportDir) { $ReportDir = Join-Path $PSScriptRoot 'AgentOutput' }
$adapter = @'
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
'@
$legacyOriginalHash = '09DE6AB0D4431872AD6A6293E33315A15359A1B7FE2B6AF7C0CB14294AFC8EC9'
$legacyPatchedMethod = 'async renderIframe(a,b,c){if(String(a.cspSource||"").includes(".webview.localhost")){var p=require("./ccs21-antigravity-proxy.cjs"),o=p.getTheiaWebviewOrigin(a,l.Uri.joinPath(this.context.extensionUri,"bridge.js"));b=await p.getProxyUrl(b,o,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function TextHash([string]$value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($value)))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
function FileHash([string]$path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead((IOPath $path))
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function BytesHash([byte[]]$bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
function GetRenderPlan([string]$source) {
    $id = '[A-Za-z_$][A-Za-z0-9_$]*'
    $pattern = '(?<![\w$])(?:async\s+)?renderIframe\s*\(\s*(?<view>'+$id+')\s*,\s*(?<server>'+$id+')\s*,\s*(?<options>'+$id+')\s*\)\s*\{\s*(?<body>(?:var|let|const)\s+(?<url>'+$id+')\s*=\s*this\.buildIframeUrl\(\s*\k<server>\s*,\s*\k<options>\s*\)\s*;\s*(?:console\.log\(`\[Jetski\] Loading iframe URL: \$\{'+$id+'\(\k<url>\)\}`\);\s*)?(?:return\s+)?this\.renderWebviewHtml\(\s*\k<view>\s*,\s*\k<server>\s*,\s*\k<url>\s*,\s*\k<options>\s*\)\s*;?\s*)\}'
    $found = [regex]::Matches($source,$pattern)
    if ($found.Count -ne 1) { throw ('Unsupported extension renderer structure: expected one local renderer, found ' + $found.Count + '. No files changed.') }
    $match = $found[0]
    if ($match.Value.Contains('__ccs21Embed')) { throw 'Renderer variable collision. No files changed.' }
    $view = $match.Groups['view'].Value
    $server = $match.Groups['server'].Value
    $options = $match.Groups['options'].Value
    $injection = '/*CCS21_AG_ADAPTER_START*/if(String('+$view+'.cspSource||"").includes(".webview.localhost")){var __ccs21EmbedAdapter=require("./ccs21-antigravity-proxy.cjs"),__ccs21EmbedOrigin=__ccs21EmbedAdapter.getTheiaWebviewOrigin('+$view+',this.context.extensionUri);'+$server+'=await __ccs21EmbedAdapter.getProxyUrl('+$server+',__ccs21EmbedOrigin,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}/*CCS21_AG_ADAPTER_END*/'
    $replacement = 'async renderIframe('+$view+','+$server+','+$options+'){'+$injection+$match.Groups['body'].Value+'}'
    return [PSCustomObject]@{ originalMethod=$match.Value; replacement=$replacement }
}
# Discovery is based on package identity and executable structure, never folder/version names.
function IOPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}
function Read-Property($Value, [string]$Name) {
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $null
}
function Get-CcsProcesses {
    try { return @(Get-CimInstance Win32_Process -Filter "Name='ccstudio.exe' OR Name='agy.exe'" -ErrorAction Stop) }
    catch {
        Write-Verbose 'Process command lines unavailable; using executable paths and explicit search roots.'
        return @(Get-Process -Name ccstudio,agy -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Name=($_.ProcessName + '.exe'); ExecutablePath=$_.Path; CommandLine=''; ProcessId=$_.Id }
        })
    }
}
function Get-LaunchPath([string]$CommandLine, [string]$Option) {
    $pattern = '(?:^|\s)--' + [regex]::Escape($Option) + '(?:=|\s+)(?:"(?<quoted>[^"]+)"|(?<plain>[^\s]+))'
    foreach ($match in [regex]::Matches($CommandLine,$pattern)) {
        if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value }
        else { $match.Groups['plain'].Value }
    }
}
function Get-SearchDirectories([string[]]$Roots, [int]$Depth=6) {
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $queue.Enqueue([PSCustomObject]@{ Path=[IO.Path]::GetFullPath($root); Level=0 })
    }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (-not $visited.Add($item.Path)) { continue }
        $item.Path
        if ($item.Level -ge $Depth) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $dir.Name -in @('node_modules','.git','AgentOutput')) { continue }
            $queue.Enqueue([PSCustomObject]@{ Path=$dir.FullName; Level=($item.Level+1) })
        }
    }
}
function Get-AntigravityPackage([string]$Directory) {
    $manifestPath = Join-Path $Directory 'package.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try {
        $pkg = [IO.File]::ReadAllText((IOPath $manifestPath)) | ConvertFrom-Json
        if ((Read-Property $pkg 'publisher') -ne 'google' -or (Read-Property $pkg 'name') -ne 'google-antigravity') { return }
        $main = [string](Read-Property $pkg 'main')
        if (-not $main) { $main = 'extension.js' }
        $root = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]'\/')
        $entry = [IO.Path]::GetFullPath((Join-Path $root $main))
        if (-not [IO.Path]::HasExtension($entry)) { $entry += '.js' }
        if (-not $entry.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package main escapes its extension directory.' }
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { return }
        [PSCustomObject]@{ Directory=$root; Entry=$entry; Package=$pkg; Version=[string](Read-Property $pkg 'version') }
    } catch { Write-Verbose ('Cannot use extension package ' + $Directory + ': ' + $_.Exception.Message) }
}
function Find-AntigravityExtensions([string[]]$Roots) {
    $result = @{}
    foreach ($dir in @(Get-SearchDirectories $Roots)) {
        $candidate = Get-AntigravityPackage $dir
        if ($null -ne $candidate) { $result[$candidate.Directory] = $candidate }
    }
    @($result.Values | Sort-Object Directory)
}
function Resolve-CcsExecutable([string]$Path) {
    if (-not $Path) { return }
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    $possibilities = @($Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $possibilities = @('ccstudio.exe','theia\ccstudio.exe','ccs\theia\ccstudio.exe') | ForEach-Object { Join-Path $Path $_ }
    }
    foreach ($exe in $possibilities) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetFileName($exe) -ine 'ccstudio.exe') { continue }
        $exe = [IO.Path]::GetFullPath($exe)
        $node = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $exe) '..\tools\node\node.exe'))
        if ((Test-Path -LiteralPath $node -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) 'resources') -PathType Container)) {
            return [PSCustomObject]@{ Executable=$exe; Node=$node }
        }
    }
}
function Find-CcsInstallations([object[]]$Processes, [string[]]$Roots) {
    $hints = @($Processes | Where-Object { $_.Name -ieq 'ccstudio.exe' } | ForEach-Object { $_.ExecutablePath })
    $running = @{}
    foreach ($hint in $hints) {
        $candidate=Resolve-CcsExecutable $hint
        if ($null -ne $candidate) { $running[$candidate.Executable]=$candidate }
    }
    if ($running.Count -gt 0) { return @($running.Values | Sort-Object Executable) }
    foreach ($name in @('CCS_HOME','CCS_INSTALL_DIR','TI_CCS_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $hints += $value }
    }
    # Registry/shortcut locations are hints, never required install locations.
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($app in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ([string](Read-Property $app 'DisplayName') -match '(?i)Code Composer|CCStudio') {
                $hints += [string](Read-Property $app 'InstallLocation')
                $icon = [string](Read-Property $app 'DisplayIcon')
                if ($icon) { $hints += ($icon -replace ',\s*-?\d+$','').Trim('"') }
            }
        }
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($special in @('Programs','CommonPrograms','Desktop','CommonDesktopDirectory')) {
            $folder = [Environment]::GetFolderPath($special)
            if (-not $folder) { continue }
            foreach ($dir in @(Get-SearchDirectories @($folder) 3)) {
                foreach ($link in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
                    $target = $shell.CreateShortcut($link.FullName).TargetPath
                    if ([IO.Path]::GetFileName($target) -ieq 'ccstudio.exe') { $hints += $target }
                }
            }
        }
    } catch { Write-Verbose 'Shortcut discovery unavailable.' }
    foreach ($dir in @(Get-SearchDirectories $Roots 3)) { $hints += $dir }
    $result = @{}
    foreach ($hint in @($hints | Where-Object { $_ } | Sort-Object -Unique)) {
        $candidate = Resolve-CcsExecutable $hint
        if ($null -ne $candidate) { $result[$candidate.Executable] = $candidate }
    }
    @($result.Values | Sort-Object Executable)
}
function Select-RepairTarget([object[]]$Candidates,[string]$Label,[string]$Property,[switch]$Headless) {
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    if ($Candidates.Count -gt 1 -and -not $Headless) {
        Write-Host ('Multiple ' + $Label + ' found. Select the intended installation:')
        for ($i=0;$i -lt $Candidates.Count;$i++) { Write-Host ('[{0}] {1}' -f ($i+1),$Candidates[$i].$Property) }
        $answer=0
        if ([int]::TryParse((Read-Host 'Number (empty cancels)'),[ref]$answer) -and $answer -ge 1 -and $answer -le $Candidates.Count) { return $Candidates[$answer-1] }
        throw 'Selection cancelled. No files changed.'
    }
    if ($Headless) { throw ('Found ' + $Candidates.Count + ' ' + $Label + '. Specify -ExtensionDir/-CcsExe or -ProfileDir/-SearchRoot; no files changed.') }
    Add-Type -AssemblyName System.Windows.Forms
    if ($Label -eq 'CCS executable') {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title='Select ccstudio.exe at its actual installation location'
        $dialog.Filter='CCStudio (ccstudio.exe)|ccstudio.exe'
    } else {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description='Select the Antigravity extension folder containing package.json'
    }
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Selection cancelled. No files changed.' }
        if ($Label -eq 'CCS executable') { $selected=Resolve-CcsExecutable $dialog.FileName }
        else { $selected=Get-AntigravityPackage $dialog.SelectedPath }
        if ($null -eq $selected) { throw 'Selected location has no compatible installation structure. No files changed.' }
        return $selected
    } finally { $dialog.Dispose() }
}

# Dot-sourcing exposes pure planning/discovery functions for isolated tests.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($CheckOnly -and $Restore) { throw 'Use either -CheckOnly or -Restore.' }
$processInventory = @(Get-CcsProcesses)
if (-not $ExtensionDir) {
    $roots = @()
    if ($ProfileDir) { $roots = @($ProfileDir) }
    elseif ($SearchRoot) { $roots = @($SearchRoot) }
    else {
        foreach ($proc in $processInventory | Where-Object { $_.Name -ieq 'ccstudio.exe' }) {
            foreach ($option in @('user-data-dir','plugins','extensions-dir')) {
                foreach ($launchPath in @(Get-LaunchPath ([string]$proc.CommandLine) $option)) {
                    $launchPath=$launchPath -replace '^local-dir:',''
                    $roots += $launchPath
                    $parent=Split-Path -Parent $launchPath
                    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent 'theia') -PathType Container)) { $roots += $parent }
                }
            }
        }
        $roots = @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Sort-Object -Unique)
        # Active launch paths take precedence over stale profiles.
        $active = @(Find-AntigravityExtensions $roots)
        if ($active.Count -eq 0) {
            foreach ($base in @($env:LOCALAPPDATA,$env:APPDATA)) {
                if ($base) { $roots += Join-Path $base 'Texas Instruments\CCS' }
            }
        }
    }
    $target = Select-RepairTarget @(Find-AntigravityExtensions $roots) 'Antigravity extension' 'Directory' -Headless:$NonInteractive
    $ExtensionDir = $target.Directory
}
$extensionInfo = Get-AntigravityPackage $ExtensionDir
if ($null -eq $extensionInfo) { throw 'Expected a Google Antigravity package and an existing package.main entry inside its directory. No files changed.' }
$ExtensionDir = $extensionInfo.Directory
$package = $extensionInfo.Package
Write-Host ('Detected Antigravity extension ' + $package.version + '. Checking renderer structure.')
$entryFile = $extensionInfo.Entry
$helperFile = Join-Path (Split-Path -Parent $entryFile) 'ccs21-antigravity-proxy.cjs'
$legacyBackupFile = Join-Path $ExtensionDir 'ccs21-antigravity-backup\extension.js.original'
$backupRoot = Join-Path $ExtensionDir 'AgentOutput\CCS21-Antigravity'
$manifestFile = Join-Path $backupRoot 'installed.json'
$manifest = $null
if ([IO.File]::Exists((IOPath $manifestFile))) { $manifest = [IO.File]::ReadAllText((IOPath $manifestFile)) | ConvertFrom-Json }
$current = [IO.File]::ReadAllText((IOPath $entryFile))
$currentBytes = [IO.File]::ReadAllBytes((IOPath $entryFile))
$currentHash = FileHash $entryFile
$legacyPatched = $current.Contains($legacyPatchedMethod)
$alreadyPatched = $legacyPatched -or $current.Contains('/*CCS21_AG_ADAPTER_START*/')
if ($alreadyPatched -and -not $legacyPatched) {
    if ($null -eq $manifest -or $currentHash -ne $manifest.patchedSha256) { throw 'Installed patch changed or its manifest is missing. No files changed.' }
    $sourceBackup = [IO.Path]::GetFullPath([string]$manifest.originalFile)
    if (-not $sourceBackup.StartsWith([IO.Path]::GetFullPath($backupRoot) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup manifest points outside AgentOutput.' }
    if ((FileHash $sourceBackup) -ne $manifest.originalSha256) { throw 'Original backup failed SHA-256 validation.' }
    $original = [IO.File]::ReadAllText((IOPath $sourceBackup))
} elseif ($legacyPatched) {
    $sourceBackup = Join-Path $backupRoot 'extension.js.original'
    if (-not ([IO.File]::Exists((IOPath $sourceBackup)))) { $sourceBackup = $legacyBackupFile }
    if (-not ([IO.File]::Exists((IOPath $sourceBackup)))) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText((IOPath $sourceBackup))
    if ((TextHash $original) -ne $legacyOriginalHash) { throw 'Legacy original backup does not match the reviewed build.' }
} else { $original = $current }
if ($alreadyPatched) { $originalBytes = [IO.File]::ReadAllBytes((IOPath $sourceBackup)) }
else { $originalBytes = $currentBytes }
$originalHash = BytesHash $originalBytes
# Keep Windows PowerShell 5.1 paths below MAX_PATH. Verify the full hash on
# every reuse, so a shortened directory name never authorizes another source.
$backupDir = Join-Path $backupRoot $originalHash.Substring(0,12)
$backupFile = Join-Path $backupDir 'extension.js.original'
$plan = GetRenderPlan $original
$patched = $original.Replace($plan.originalMethod,$plan.replacement)
if ($legacyPatched -and $currentHash -ne (TextHash ($original.Replace($plan.originalMethod,$legacyPatchedMethod)))) { throw 'Other legacy extension changes detected; refusing to overwrite.' }
Write-Host ('Compatible renderer detected. Source SHA-256: ' + $originalHash)
if ([IO.File]::Exists((IOPath $helperFile))) {
    $helperHash = FileHash $helperFile
    $knownHelpers = @((TextHash $adapter),'D9F36391B8F33025E4BE0502F7BE55E49042A9766509A44646AF2A7F6FFC30B3','F7DDA1CDB4A063D3C128A201439A45FD35203ACBDA193B0CF6B4E3EFC241069E')
    if ($null -ne $manifest) { $knownHelpers += [string]$manifest.adapterSha256 }
    if ($helperHash -notin $knownHelpers) { throw 'Adapter file has unexpected local edits; refusing to overwrite.' }
}
# Preflight the real frontend, not just package.json: agy updates independently.
$backendChecks = @()
$binaryVersions = @()
if (-not $Restore) {
    if (-not $CcsExe) {
        $ccsTarget = Select-RepairTarget @(Find-CcsInstallations $processInventory $SearchRoot) 'CCS executable' 'Executable' -Headless:$NonInteractive
    } else {
        $ccsTarget = Resolve-CcsExecutable $CcsExe
    }
    if ($null -eq $ccsTarget) { throw 'Selected CCS has no bundled Node.js/resources structure. No files changed.' }
    $CcsExe = $ccsTarget.Executable
    $nodeExe = $ccsTarget.Node
    Write-Host ('CCS executable: ' + $CcsExe)
    $backendUrls = @()
    $backendProcesses = @($processInventory | Where-Object { $_.Name -ieq 'agy.exe' })
    if ($BackendUrl) { $backendUrls = @($BackendUrl) }
    else {
        $backendUrls = @($backendProcesses | ForEach-Object {
            if ($_.CommandLine -match '(?:^|\s)--hub-port(?:=|\s+)(\d+)(?:\s|$)') { 'http://127.0.0.1:' + $Matches[1] }
        } | Sort-Object -Unique)
    }
    if ($backendUrls.Count -gt 1) { Write-Host 'Multiple local agy backends found; checking each. Use -BackendUrl to check one specific session.' }
    if ($backendUrls.Count -eq 0) { Write-Host 'No backend address available. Install-time backend check pending; the adapter checks it when the panel opens.' }
    $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('ccs21-antigravity-check-' + [Guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [IO.File]::WriteAllText((IOPath $probeFile),$adapter,$utf8)
        & $nodeExe --check $probeFile
        if ($LASTEXITCODE -ne 0) { throw 'Bundled Node.js cannot parse this adapter. No files changed.' }
        $syntaxFile = [IO.Path]::ChangeExtension($probeFile,'.js')
        try {
            [IO.File]::WriteAllText((IOPath $syntaxFile),$patched,$utf8)
            & $nodeExe --check $syntaxFile
            if ($LASTEXITCODE -ne 0) { throw 'Patched extension syntax check failed. No files changed.' }
        } finally { if ([IO.File]::Exists((IOPath $syntaxFile))) { [IO.File]::Delete((IOPath $syntaxFile)) } }
        foreach ($binary in @($backendProcesses | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ } | Sort-Object -Unique)) {
            # Installed and running versions may differ after an update.
            $installedVersion = (& $nodeExe $probeFile --binary-version $binary) -join ''
            $binaryVersions += [PSCustomObject]@{ executable=$binary; installedVersion=$installedVersion }
            Write-Host ('Installed agy executable version: ' + $installedVersion)
        }
        foreach ($url in $backendUrls) {
            $probeOutput = & $nodeExe $probeFile --check-backend $url 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('Backend check failed: ' + ($probeOutput -join ' ') + '. No files changed.') }
            $probe = ($probeOutput -join '') | ConvertFrom-Json
            $backendChecks += [PSCustomObject]@{ url=$url; version=$probe.version; mode=$probe.mode; sha256=$probe.sha256 }
            Write-Host ('Verified running agy ' + $probe.version + ' (' + $probe.mode + '), frontend: ' + $probe.sha256)
        }
    } finally { if ([IO.File]::Exists((IOPath $probeFile))) { [IO.File]::Delete((IOPath $probeFile)) } }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not ([IO.File]::Exists((IOPath $helperFile)))) { throw 'Patched entry point is missing its adapter. Run repair.' }
    $adapterCurrent = ([IO.File]::Exists((IOPath $helperFile))) -and ((FileHash $helperFile) -eq (TextHash $adapter))
    Write-Host ('Compatible Antigravity ' + $package.version + '. Current adapter installed: ' + ($alreadyPatched -and $adapterCurrent -and -not $legacyPatched))
    if ($alreadyPatched -and ($legacyPatched -or -not $adapterCurrent)) { Write-Host 'Legacy adapter found. Run repair to enable automatic update compatibility.' }
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    # Fail on an unwritable report location before touching the extension.
    [IO.Directory]::CreateDirectory((IOPath $ReportDir)) | Out-Null
    $reportProbe = Join-Path $ReportDir ('.write-check-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText((IOPath $reportProbe),'',$utf8)
    [IO.File]::Delete((IOPath $reportProbe))
    if (-not (Test-Path -LiteralPath $backupDir)) { [IO.Directory]::CreateDirectory((IOPath $backupDir)) | Out-Null }
    if ([IO.File]::Exists((IOPath $backupFile))) {
        if ((FileHash $backupFile) -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllBytes((IOPath $backupFile),$originalBytes) }
    $snapshotDir = Join-Path $backupDir ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
    [IO.Directory]::CreateDirectory((IOPath $snapshotDir)) | Out-Null
    [IO.File]::Copy((IOPath $entryFile),(IOPath (Join-Path $snapshotDir 'extension.js.before')))
    $previousHelper = $null
    if ([IO.File]::Exists((IOPath $helperFile))) {
        $previousHelper = [IO.File]::ReadAllBytes((IOPath $helperFile))
        [IO.File]::Copy((IOPath $helperFile),(IOPath (Join-Path $snapshotDir 'proxy.cjs.before')))
    }
    $previousManifest = $null
    if ([IO.File]::Exists((IOPath $manifestFile))) {
        $previousManifest = [IO.File]::ReadAllBytes((IOPath $manifestFile))
        [IO.File]::Copy((IOPath $manifestFile),(IOPath (Join-Path $snapshotDir 'installed.json.before')))
    }
    if ((FileHash $entryFile) -ne $currentHash) { throw 'Extension changed during preflight. Rerun repair.' }
    try {
        [IO.File]::WriteAllText((IOPath $helperFile),$adapter,$utf8)
        [IO.File]::WriteAllText((IOPath $entryFile),$patched,$utf8)
        if ((FileHash $entryFile) -ne (TextHash $patched) -or (FileHash $helperFile) -ne (TextHash $adapter)) { throw 'Patch verification failed.' }
        $manifestJson = [PSCustomObject]@{ toolVersion=$toolVersion; extensionVersion=$package.version; originalFile=$backupFile; originalSha256=$originalHash; patchedSha256=(TextHash $patched); adapterSha256=(TextHash $adapter) } | ConvertTo-Json
        [IO.File]::WriteAllText((IOPath $manifestFile),$manifestJson,$utf8)
    } catch {
        [IO.File]::WriteAllBytes((IOPath $entryFile),$currentBytes)
        if ($null -ne $previousHelper) { [IO.File]::WriteAllBytes((IOPath $helperFile),$previousHelper) }
        elseif ([IO.File]::Exists((IOPath $helperFile))) { [IO.File]::Delete((IOPath $helperFile)) }
        if ($null -ne $previousManifest) { [IO.File]::WriteAllBytes((IOPath $manifestFile),$previousManifest) }
        elseif ([IO.File]::Exists((IOPath $manifestFile))) { [IO.File]::Delete((IOPath $manifestFile)) }
        throw
    }
    [IO.Directory]::CreateDirectory((IOPath $ReportDir)) | Out-Null
    $reportFile = Join-Path $ReportDir ('repair-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
    $reportJson = [PSCustomObject]@{ toolVersion=$toolVersion; extension=$ExtensionDir; entryFile=$entryFile; ccsExecutable=$CcsExe; extensionVersion=$package.version; installed=$true; installedBackendVersions=$binaryVersions; backendChecks=$backendChecks; backendVerified=($backendChecks.Count -gt 0); uiVerified=$false; status='installed-reload-required'; backup=$snapshotDir } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((IOPath $reportFile),$reportJson,$utf8)
    Write-Host ('Adapter ' + $toolVersion + ' installed. Backend verified: ' + ($backendChecks.Count -gt 0) + '. Backup: ' + $snapshotDir) -ForegroundColor Green
    Write-Host 'UI verification is pending. Reload CCS21 and confirm the Antigravity panel opens.'
    Write-Host ('Report: ' + $reportFile)
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllBytes((IOPath $entryFile),$originalBytes)
    if ((FileHash $entryFile) -ne $originalHash) { throw 'Restore verification failed.' }
    if ([IO.File]::Exists((IOPath $helperFile))) { [IO.File]::Delete((IOPath $helperFile)) }
    Write-Host 'Original extension.js restored and verified.' -ForegroundColor Green
} else { Write-Host 'Original extension is already present.' }
if ($NoRestart) { Write-Host 'In CCS use Developer: Reload Window to load the change.'; return }
$running = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and ($CcsExe -and $_.Path -ieq $CcsExe)
})
if ($running.Count -gt 1) { throw 'Multiple CCS21 windows are open. Reload each window manually.' }
if ($running.Count -eq 1) {
    $launch = @($processInventory | Where-Object { $_.ProcessId -eq $running[0].Id -and $_.CommandLine })
    if ($launch.Count -ne 1 -or $launch[0].CommandLine -notmatch '^\s*(?:"[^"]+"|\S+)\s*(?<arguments>[\s\S]*)$') {
        Write-Host 'Original launch arguments unavailable. Use Developer: Reload Window to retain your profile/workspace.'
        return
    }
    $restartArguments = $Matches['arguments']
    if (-not $CcsExe) { $CcsExe = $running[0].Path }
    Write-Host 'Restarting CCS21. Save changes if CCS asks; no process will be force-killed.'
    if (-not $running[0].CloseMainWindow()) { throw 'CCS did not accept a graceful close. Use Developer: Reload Window.' }
    if (-not $running[0].WaitForExit(30000)) { throw 'CCS is still open, possibly awaiting Save. Complete that dialog, then restart CCS.' }
}
if ($running.Count -eq 0) {
    Write-Host 'Open or reload the selected CCS installation to load the change. No duplicate instance was started.'
    return
}
if ($CcsExe -and ([IO.File]::Exists((IOPath $CcsExe)))) {
    if ($restartArguments) { Start-Process -FilePath $CcsExe -ArgumentList $restartArguments -WindowStyle Hidden }
    else { Start-Process -FilePath $CcsExe -WindowStyle Hidden }
}
else { Write-Host 'Repair complete. Open CCS21 manually.' }

