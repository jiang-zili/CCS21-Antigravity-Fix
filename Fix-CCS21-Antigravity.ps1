#requires -Version 5.1
<#
Repairs the reviewed Google Antigravity 1.8.0 / agy 1.4.2 CCS21 build.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$adapter = @'
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

// agy 1.4.2 rejects messages from Theia's per-view localhost origin before
// mounting its UI. Pin the reviewed bundle so a future backend cannot receive
// an unreviewed JavaScript rewrite.
const AGY_142_MAIN_SHA256 = '35f63c4b46aee4feb86e5997098b7baea5aea5223624ff373485afd0e07ba563';
const AGY_142_ORIGIN_GUARD = 'function UNc(a,b=window.location.origin){if(!a||a==="null")return!1;';
const MAX_MAIN_JS_BYTES = 16 * 1024 * 1024;

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

function adaptAgyMainJs(body, allowedOrigin, expectedHash = AGY_142_MAIN_SHA256) {
  const origin = validateTheiaOrigin(allowedOrigin);
  const source = Buffer.isBuffer(body) ? body : Buffer.from(body);
  if (crypto.createHash('sha256').update(source).digest('hex') !== expectedHash) {
    throw new Error('Unsupported agy main.js version; exact bundle hash changed.');
  }
  const text = source.toString('utf8');
  if (text.split(AGY_142_ORIGIN_GUARD).length !== 2) {
    throw new Error('Expected exactly one agy 1.4.2 origin guard.');
  }
  return Buffer.from(text.replace(
    AGY_142_ORIGIN_GUARD,
    AGY_142_ORIGIN_GUARD + `if(a===${JSON.stringify(origin)})return!0;`,
  ), 'utf8');
}

/**
 * Adapt one agy backend for one exact CCS/Theia webview origin.
 * The backend target is fixed; all HTTP bodies, CSRF/auth headers, and WebSocket
 * traffic pass through unchanged. The HTML frame-ancestors directive and one
 * hash-pinned JavaScript message guard admit the exact origin. Binds to loopback.
 */
async function createCcsEmbedProxy({ backendUrl, allowedOrigin }) {
  const backend = new URL(backendUrl);
  const origin = validateTheiaOrigin(allowedOrigin);
  if (backend.protocol !== 'http:' || backend.username || backend.password ||
      !['localhost', '127.0.0.1', '[::1]'].includes(backend.hostname) ||
      !backend.port || backend.pathname !== '/' || backend.search || backend.hash) {
    throw new Error('Expected a fixed HTTP loopback agy backend origin.');
  }

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
    pending = createCcsEmbedProxy({ backendUrl, allowedOrigin: origin }).then(proxy => {
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

module.exports = { getProxyUrl, createCcsEmbedProxy, getTheiaWebviewOrigin, adaptAgyMainJs };
'@
$originalHash = '09DE6AB0D4431872AD6A6293E33315A15359A1B7FE2B6AF7C0CB14294AFC8EC9'
$oldMethod = 'renderIframe(a,b,c){var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$newMethod = 'async renderIframe(a,b,c){if(String(a.cspSource||"").includes(".webview.localhost")){var p=require("./ccs21-antigravity-proxy.cjs"),o=p.getTheiaWebviewOrigin(a,l.Uri.joinPath(this.context.extensionUri,"bridge.js"));b=await p.getProxyUrl(b,o,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function TextHash([string]$value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($value)))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
if (-not $ExtensionDir) {
    $ccsRoot = Join-Path $env:LOCALAPPDATA 'Texas Instruments\CCS'
    $candidates = @(Get-ChildItem -LiteralPath $ccsRoot -Directory -Filter 'ccs21*' | ForEach-Object {
        $deployment = Join-Path $_.FullName '0\theia\deployedPlugins'
        if (Test-Path -LiteralPath $deployment) {
            Get-ChildItem -LiteralPath $deployment -Directory -Filter 'google.google-antigravity*' | ForEach-Object {
                $candidate = Join-Path $_.FullName 'extension'
                if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { Get-Item -LiteralPath $candidate }
            }
        }
    })
    if ($candidates.Count -ne 1) { throw 'Expected one CCS21 Antigravity installation. Pass -ExtensionDir with its extension folder.' }
    $ExtensionDir = $candidates[0].FullName
}
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$package = Get-Content -LiteralPath (Join-Path $ExtensionDir 'package.json') -Raw | ConvertFrom-Json
if ($package.publisher -ne 'google' -or $package.name -ne 'google-antigravity' -or $package.version -ne '1.8.0') {
    throw 'Unsupported extension. This repair supports the reviewed Antigravity 1.8.0 build only.'
}
$entryFile = Join-Path $ExtensionDir 'extension.js'
$helperFile = Join-Path $ExtensionDir 'ccs21-antigravity-proxy.cjs'
$backupDir = Join-Path $ExtensionDir 'ccs21-antigravity-backup'
$backupFile = Join-Path $backupDir 'extension.js.original'
$current = [IO.File]::ReadAllText($entryFile)
$currentHash = (Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash
$alreadyPatched = $current.Contains($newMethod)
if ($alreadyPatched) {
    if (-not (Test-Path -LiteralPath $backupFile)) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText($backupFile)
} else { $original = $current }
if ((TextHash $original) -ne $originalHash) { throw 'Extension source differs from the reviewed build; no changes made.' }
if (($original.Split(@($oldMethod),[StringSplitOptions]::None)).Count -ne 2) { throw 'Expected exactly one known renderIframe implementation.' }
$patched = $original.Replace($oldMethod,$newMethod)
if ($alreadyPatched -and $currentHash -ne (TextHash $patched)) { throw 'Other extension changes detected; refusing to overwrite.' }
if (Test-Path -LiteralPath $helperFile) {
    if ((Get-FileHash -LiteralPath $helperFile -Algorithm SHA256).Hash -ne (TextHash $adapter)) { throw 'Adapter file has unexpected contents; refusing to overwrite.' }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not (Test-Path -LiteralPath $helperFile)) { throw 'Patched entry point is missing its adapter. Run repair.' }
    Write-Host ('Compatible Antigravity 1.8.0 found. Adapter installed: ' + $alreadyPatched)
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    if (Test-Path -LiteralPath $backupFile) {
        if ((Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllText($backupFile,$original,$utf8) }
    [IO.File]::WriteAllText($helperFile,$adapter,$utf8)
    try {
        [IO.File]::WriteAllText($entryFile,$patched,$utf8)
        if ((Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash -ne (TextHash $patched)) { throw 'Patch verification failed.' }
    } catch {
        [IO.File]::WriteAllText($entryFile,$original,$utf8)
        throw
    }
    Write-Host 'Repair installed and verified. Original extension.js is backed up.' -ForegroundColor Green
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllText($entryFile,$original,$utf8)
    if ((Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Restore verification failed.' }
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
