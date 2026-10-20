#requires -Version 5.1
<#
Detects extension/backend versions and repairs compatible renderer structures.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [string]$BackendUrl,
    [string]$ReportDir,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolVersion = '1.2.0'
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
    'function (' + id + ')\\((' + id + '),(' + id + ')=window\\.location\\.origin\\)\\{' +
    '[\\s\\S]{0,4096}?\\}catch\\{return!1\\}\\}', 'g'))];
  const matches = [];
  for (const match of candidates) {
    const prefix = 'function ' + match[1] + '(' + match[2] + ',' + match[3] + '=window.location.origin){';
    const locals = match[0].match(new RegExp('let (' + id + ')=new URL\\(' + match[2].replace(/\$/g,'\\$') + '\\);'));
    const hostname = match[0].match(new RegExp('let (' + id + ')=(' + id + ')\\.hostname;'));
    if (!locals || !hostname || locals[1] !== hostname[2]) continue;
    const names = [match[1], match[2], match[3], locals[1], hostname[1]];
    if (new Set(names).size !== names.length) continue;
    const replacements = new Map(names.map((name, i) => [name, ['FN','VALUE','EXPECTED','URLVAR','HOST'][i]]));
    // Preserve string contents and property names when normalizing identifiers.
    let normalized = match[0].replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_$][A-Za-z0-9_$]*|\s+/g,
      (token, offset, source) => {
        if (/^\s+$/.test(token)) return '';
        return source[offset - 1] !== '.' && replacements.has(token) ? replacements.get(token) : token;
      });
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
    matches.push({ guard: prefix + 'if(!' + match[2] + '||' + match[2] + '==="null")return!1;', valueName: match[2] });
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
    $stream = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function GetRenderPlan([string]$source) {
    $id = '[A-Za-z_$][A-Za-z0-9_$]*'
    $pattern = 'renderIframe\((?<view>'+$id+'),(?<server>'+$id+'),(?<options>'+$id+')\)\{(?<body>(?:var|let|const) (?<url>'+$id+')=this\.buildIframeUrl\(\k<server>,\k<options>\);console\.log\(`\[Jetski\] Loading iframe URL: \$\{'+$id+'\(\k<url>\)\}`\);this\.renderWebviewHtml\(\k<view>,\k<server>,\k<url>,\k<options>\))\}'
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
if ($CheckOnly -and $Restore) { throw 'Use either -CheckOnly or -Restore.' }
if (-not $ExtensionDir) {
    $ccsRoot = Join-Path $env:LOCALAPPDATA 'Texas Instruments\CCS'
    $candidates = @(Get-ChildItem -LiteralPath $ccsRoot -Directory -Filter 'ccs21*' | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
        $deployment = Join-Path $_.FullName 'theia\deployedPlugins'
        if (Test-Path -LiteralPath $deployment) {
            Get-ChildItem -LiteralPath $deployment -Directory -Filter 'google.google-antigravity*' | ForEach-Object {
                $candidate = Join-Path $_.FullName 'extension'
                if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { Get-Item -LiteralPath $candidate }
            }
        }
        }
    })
    if ($candidates.Count -ne 1) { throw 'Expected one CCS21 Antigravity installation. Pass -ExtensionDir with its extension folder.' }
    $ExtensionDir = $candidates[0].FullName
}
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$package = Get-Content -LiteralPath (Join-Path $ExtensionDir 'package.json') -Raw | ConvertFrom-Json
if ($package.publisher -ne 'google' -or $package.name -ne 'google-antigravity' -or $package.version -notmatch '^\d+\.\d+\.\d+') {
    throw 'Expected a Google Antigravity extension package with a valid version.'
}
Write-Host ('Detected Antigravity extension ' + $package.version + '. Checking renderer structure.')
$entryFile = Join-Path $ExtensionDir 'extension.js'
$helperFile = Join-Path $ExtensionDir 'ccs21-antigravity-proxy.cjs'
$legacyBackupFile = Join-Path $ExtensionDir 'ccs21-antigravity-backup\extension.js.original'
$backupRoot = Join-Path $ExtensionDir 'AgentOutput\CCS21-Antigravity'
$manifestFile = Join-Path $backupRoot 'installed.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestFile) { $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json }
$current = [IO.File]::ReadAllText($entryFile)
$currentHash = FileHash $entryFile
$legacyPatched = $current.Contains($legacyPatchedMethod)
$alreadyPatched = $legacyPatched -or $current.Contains('/*CCS21_AG_ADAPTER_START*/')
if ($alreadyPatched -and -not $legacyPatched) {
    if ($null -eq $manifest -or $currentHash -ne $manifest.patchedSha256) { throw 'Installed patch changed or its manifest is missing. No files changed.' }
    $sourceBackup = [IO.Path]::GetFullPath([string]$manifest.originalFile)
    if (-not $sourceBackup.StartsWith([IO.Path]::GetFullPath($backupRoot) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup manifest points outside AgentOutput.' }
    if ((FileHash $sourceBackup) -ne $manifest.originalSha256) { throw 'Original backup failed SHA-256 validation.' }
    $original = [IO.File]::ReadAllText($sourceBackup)
} elseif ($legacyPatched) {
    $sourceBackup = Join-Path $backupRoot 'extension.js.original'
    if (-not (Test-Path -LiteralPath $sourceBackup)) { $sourceBackup = $legacyBackupFile }
    if (-not (Test-Path -LiteralPath $sourceBackup)) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText($sourceBackup)
    if ((TextHash $original) -ne $legacyOriginalHash) { throw 'Legacy original backup does not match the reviewed build.' }
} else { $original = $current }
$originalHash = TextHash $original
# Keep Windows PowerShell 5.1 paths below MAX_PATH. Verify the full hash on
# every reuse, so a shortened directory name never authorizes another source.
$backupDir = Join-Path $backupRoot $originalHash.Substring(0,12)
$backupFile = Join-Path $backupDir 'extension.js.original'
$plan = GetRenderPlan $original
$patched = $original.Replace($plan.originalMethod,$plan.replacement)
if ($legacyPatched -and $currentHash -ne (TextHash ($original.Replace($plan.originalMethod,$legacyPatchedMethod)))) { throw 'Other legacy extension changes detected; refusing to overwrite.' }
Write-Host ('Compatible renderer detected. Source SHA-256: ' + $originalHash)
if (Test-Path -LiteralPath $helperFile) {
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
        $ccsPaths = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Where-Object { $_ -like '*\ccs21*\ccs\theia\ccstudio.exe' } | Sort-Object -Unique)
        if ($ccsPaths.Count -eq 1) { $CcsExe = $ccsPaths[0] }
        elseif (Test-Path -LiteralPath 'C:\ti\ccs2101\ccs\theia\ccstudio.exe') { $CcsExe = 'C:\ti\ccs2101\ccs\theia\ccstudio.exe' }
    }
    if (-not $CcsExe -or -not (Test-Path -LiteralPath $CcsExe)) { throw 'Pass -CcsExe pointing to the CCS21 executable. No files changed.' }
    $nodeExe = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CcsExe) '..\tools\node\node.exe'))
    if (-not (Test-Path -LiteralPath $nodeExe)) { throw 'CCS bundled Node.js was not found. No files changed.' }
    $backendUrls = @()
    $backendProcesses = @(Get-CimInstance Win32_Process -Filter "Name='agy.exe'")
    if ($BackendUrl) { $backendUrls = @($BackendUrl) }
    else {
        $backendUrls = @($backendProcesses | ForEach-Object {
            if ($_.CommandLine -match '(?:^|\s)--hub-port=(\d+)(?:\s|$)') { 'http://127.0.0.1:' + $Matches[1] }
        } | Sort-Object -Unique)
    }
    if ($backendUrls.Count -eq 0) { throw 'Open CCS21 and the Antigravity panel first, then rerun. No running agy backend was found; no files changed.' }
    $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('ccs21-antigravity-check-' + [Guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [IO.File]::WriteAllText($probeFile,$adapter,$utf8)
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
    } finally { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile } }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not (Test-Path -LiteralPath $helperFile)) { throw 'Patched entry point is missing its adapter. Run repair.' }
    $adapterCurrent = (Test-Path -LiteralPath $helperFile) -and ((FileHash $helperFile) -eq (TextHash $adapter))
    Write-Host ('Compatible Antigravity ' + $package.version + '. Current adapter installed: ' + ($alreadyPatched -and $adapterCurrent -and -not $legacyPatched))
    if ($alreadyPatched -and ($legacyPatched -or -not $adapterCurrent)) { Write-Host 'Legacy adapter found. Run repair to enable automatic update compatibility.' }
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    if (Test-Path -LiteralPath $backupFile) {
        if ((FileHash $backupFile) -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllText($backupFile,$original,$utf8) }
    $snapshotDir = Join-Path $backupDir ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $snapshotDir | Out-Null
    Copy-Item -LiteralPath $entryFile -Destination (Join-Path $snapshotDir 'extension.js.before')
    $previousHelper = $null
    if (Test-Path -LiteralPath $helperFile) {
        $previousHelper = [IO.File]::ReadAllBytes($helperFile)
        Copy-Item -LiteralPath $helperFile -Destination (Join-Path $snapshotDir 'proxy.cjs.before')
    }
    try {
        [IO.File]::WriteAllText($helperFile,$adapter,$utf8)
        [IO.File]::WriteAllText($entryFile,$patched,$utf8)
        if ((FileHash $entryFile) -ne (TextHash $patched) -or (FileHash $helperFile) -ne (TextHash $adapter)) { throw 'Patch verification failed.' }
        [PSCustomObject]@{ toolVersion=$toolVersion; extensionVersion=$package.version; originalFile=$backupFile; originalSha256=$originalHash; patchedSha256=(TextHash $patched); adapterSha256=(TextHash $adapter) } | ConvertTo-Json | Set-Content -LiteralPath $manifestFile -Encoding UTF8
    } catch {
        [IO.File]::WriteAllText($entryFile,$current,$utf8)
        if ($null -ne $previousHelper) { [IO.File]::WriteAllBytes($helperFile,$previousHelper) }
        elseif (Test-Path -LiteralPath $helperFile) { Remove-Item -LiteralPath $helperFile }
        throw
    }
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $reportFile = Join-Path $ReportDir ('repair-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
    [PSCustomObject]@{ toolVersion=$toolVersion; extension=$ExtensionDir; extensionVersion=$package.version; installed=$true; installedBackendVersions=$binaryVersions; backendChecks=$backendChecks; uiVerified=$false; status='installed-reload-required'; backup=$snapshotDir } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host ('Adapter ' + $toolVersion + ' installed; running backend compatibility verified. Backup: ' + $snapshotDir) -ForegroundColor Green
    Write-Host 'UI verification is pending. Reload CCS21 and confirm the Antigravity panel opens.'
    Write-Host ('Report: ' + $reportFile)
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllText($entryFile,$original,$utf8)
    if ((FileHash $entryFile) -ne $originalHash) { throw 'Restore verification failed.' }
    if (Test-Path -LiteralPath $helperFile) { Remove-Item -LiteralPath $helperFile }
    Write-Host 'Original extension.js restored and verified.' -ForegroundColor Green
} else { Write-Host 'Original extension is already present.' }
if ($NoRestart) { Write-Host 'In CCS use Developer: Reload Window to load the change.'; return }
$running = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and $_.Path -like '*\ccs21*\ccs\theia\ccstudio.exe'
})
if ($running.Count -gt 1) { throw 'Multiple CCS21 windows are open. Reload each window manually.' }
if ($running.Count -eq 1) {
    if (-not $CcsExe) { $CcsExe = $running[0].Path }
    Write-Host 'Restarting CCS21. Save changes if CCS asks; no process will be force-killed.'
    if (-not $running[0].CloseMainWindow()) { throw 'CCS did not accept a graceful close. Use Developer: Reload Window.' }
    if (-not $running[0].WaitForExit(30000)) { throw 'CCS is still open, possibly awaiting Save. Complete that dialog, then restart CCS.' }
}
if ($running.Count -eq 0 -and @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\ccs21*\ccs\theia\ccstudio.exe' }).Count -gt 0) {
    Write-Host 'CCS21 is running but its window cannot be identified. Use Developer: Reload Window; no duplicate CCS instance was started.'
    return
}
if (-not $CcsExe) {
    $executables = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $tiRoot = Join-Path $_.Root 'ti'
        if (Test-Path -LiteralPath $tiRoot) {
            Get-ChildItem -LiteralPath $tiRoot -Directory -Filter 'ccs21*' | ForEach-Object {
                $exe = Join-Path $_.FullName 'ccs\theia\ccstudio.exe'
                if (Test-Path -LiteralPath $exe) { $exe }
            }
        }
    })
    if ($executables.Count -eq 1) { $CcsExe = $executables[0] }
}
if ($CcsExe -and (Test-Path -LiteralPath $CcsExe)) { Start-Process -FilePath $CcsExe -WindowStyle Hidden }
else { Write-Host 'Repair complete. Open CCS21 manually.' }
