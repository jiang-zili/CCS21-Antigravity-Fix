'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const path = require('node:path');
const zlib = require('node:zlib');
// Installed beside this file; the repository copy lives in vendor/.
const acorn = require(require('node:fs').existsSync(path.join(__dirname, 'ccs-antigravity-acorn.cjs'))
  ? './ccs-antigravity-acorn.cjs' : './vendor/acorn.cjs');
const MAX_MAIN_JS_BYTES = 32 * 1024 * 1024;
const profileCache = new Map();
const EXPECTED_GUARD = 'function guard(value,expected=window.location.origin){' +
  'if(!value||value==="null")return false;' +
  'if(value===expected||value.startsWith("vscode-webview://")||value.startsWith("vscode-file://"))return true;' +
  'try{let parsed=new URL(value);if(parsed.protocol!=="http:"&&parsed.protocol!=="https:")return false;' +
  'let host=parsed.hostname;return host==="localhost"||host==="127.0.0.1"||host==="[::1]"||host==="::1"?true:' +
  'parsed.protocol==="https:"?host.endsWith(".google.com"):false}catch{return false}}';

function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  if (node.type) visit(node);
  for (const key of Object.keys(node)) {
    if (key === 'start' || key === 'end') continue;
    const value = node[key];
    if (Array.isArray(value)) value.forEach(child => walk(child, visit));
    else if (value && typeof value === 'object') walk(value, visit);
  }
}

function canonicalGuard(fn) {
  if (!['FunctionExpression','ArrowFunctionExpression'].includes(fn.type) ||
      fn.async || fn.generator || fn.body.type !== 'BlockStatement' || fn.params.length !== 2) return null;
  const first = fn.params[0];
  const second = fn.params[1].type === 'AssignmentPattern' ? fn.params[1].left : fn.params[1];
  if (first.type !== 'Identifier' || second.type !== 'Identifier' || first.name === second.name) return null;
  const names = new Map([[first.name,'VALUE'],[second.name,'EXPECTED']]);
  let parsedName;
  walk(fn.body, node => {
    if (node.type === 'VariableDeclarator' && node.id.type === 'Identifier' && node.init &&
        node.init.type === 'NewExpression' && node.init.callee.name === 'URL' &&
        node.init.arguments.length === 1 && node.init.arguments[0].name === first.name) {
      if (parsedName) parsedName = '!ambiguous'; else parsedName = node.id.name;
    }
  });
  if (!parsedName || parsedName === '!ambiguous' || names.has(parsedName)) return null;
  names.set(parsedName,'PARSED');
  let hostName;
  walk(fn.body, node => {
    if (node.type === 'VariableDeclarator' && node.id.type === 'Identifier' && node.init &&
        node.init.type === 'MemberExpression' && node.init.object.name === parsedName &&
        !node.init.computed && node.init.property.name === 'hostname') {
      if (hostName) hostName = '!ambiguous'; else hostName = node.id.name;
    }
  });
  if (!hostName || hostName === '!ambiguous' || names.has(hostName)) return null;
  names.set(hostName,'HOST');
  function normalize(node, property) {
    if (node == null || typeof node !== 'object') return node;
    if (Array.isArray(node)) return node.map(n => normalize(n));
    if (node.type === 'Identifier') return {type:'Identifier',name:property ? node.name : (names.get(node.name) || node.name)};
    if (node.type === 'UnaryExpression' && node.operator === '!' && node.argument.type === 'Literal' &&
        [0,1,true,false].includes(node.argument.value)) return {type:'Literal',value:!node.argument.value};
    if (node.type === 'CallExpression' && node.callee.type === 'MemberExpression' &&
        node.callee.object.name === hostName && node.callee.property.name === 'endsWith' &&
        node.arguments.length === 1 && node.arguments[0].type === 'Literal' &&
        /^(?:\.[a-z0-9-]+)+$/i.test(node.arguments[0].value)) return {type:'HttpsSuffix'};
    if (node.type === 'LogicalExpression') {
      const parts = [];
      function collect(n) {
        if (n.type === 'LogicalExpression' && n.operator === node.operator) {collect(n.left);collect(n.right);}
        else parts.push(JSON.stringify(normalize(n)));
      }
      collect(node.left);collect(node.right);
      const unique = [...new Set(parts)].sort();
      return unique.length === 1 ? JSON.parse(unique[0]) : {type:'Logical',operator:node.operator,parts:unique};
    }
    const result = {};
    for (const key of Object.keys(node).sort()) {
      if (['start','end','loc','range','raw','id'].includes(key) &&
          (key !== 'id' || ['FunctionExpression','ArrowFunctionExpression'].includes(node.type))) continue;
      if (node.type === 'CatchClause' && key === 'param') continue;
      if (node.type === 'Literal' && key !== 'type' && key !== 'value') continue;
      if (node.type === 'VariableDeclaration' && key === 'kind') continue;
      result[key] = normalize(node[key], node.type === 'MemberExpression' && key === 'property' && !node.computed);
    }
    return result;
  }
  return {shape:JSON.stringify(normalize(fn.body)),valueName:first.name};
}
// Reviewed backend guard with configured allowedDomains; preserve its full algorithm.
const CONFIGURED_DOMAIN_GUARD = "function NTc(a,b=window.location.origin){if(!a||a===\"null\")return!1;if(a===b||a.startsWith(\"vscode-webview://\")||a.startsWith(\"vscode-file://\"))return!0;try{let k=new URL(a);if(k.protocol!==\"http:\"&&k.protocol!==\"https:\")return!1;let l=k.hostname;if(l===\"localhost\"||l===\"127.0.0.1\"||l===\"[::1]\"||l===\"::1\")var c=!0;else{if(k.protocol===\"https:\"){var d;if(!(d=l.endsWith(\".google.com\")||l.endsWith(\".googleplex.com\")||l.endsWith(\".googlers.com\")||l.endsWith(\".googleprod.com\")||l.endsWith(\".cloudworkstations.dev\")||l.endsWith(\".cloudworkstations.googleusercontent.com\")||\nl.endsWith(\".cloudshell.dev\")||l.endsWith(\".cloudshell.googleusercontent.com\")))a:{var f=typeof window!==\"undefined\"?window.__APP_CONFIG__?.allowedDomains:void 0;if(f?.length){var g=l.toLowerCase();for(let m of f){let n=m.trim().toLowerCase().replace(/^\\*\\./,\"\").replace(/^\\.+|\\.+$/g,\"\");if(n&&n.includes(\".\")&&!n.includes(\"*\")&&(g===n||g.endsWith(`.${n}`))){d=!0;break a}}}d=!1}var h=d}else h=!1;c=h}return c}catch{return!1}}";
const configuredDomainShape = canonicalGuard(acorn.parseExpressionAt(CONFIGURED_DOMAIN_GUARD,0,{ecmaVersion:"latest"})).shape;
const expectedShape = canonicalGuard(acorn.parseExpressionAt(EXPECTED_GUARD,0,{ecmaVersion:'latest'})).shape;

// Parse only candidate functions, not a 10-30 MB application AST. Whitespace,
// quotes, minified names, boolean spellings and arrow functions are immaterial.
function discoverOriginGuard(text) {
  const found = new Map();
  const anchors = [...text.matchAll(/(["'])vscode-webview:\/\/\1/g)];
  if (anchors.length > 64) throw new Error('Too many origin-check candidates.');
  for (const anchor of anchors) {
    const start = Math.max(0,anchor.index-4096);
    const prefix = text.slice(start,anchor.index);
    const headers = /\bfunction(?:\s+[A-Za-z_$][\w$]*)?\s*\(|\([^(){};]{1,512}\)\s*=>\s*\{/g;
    for (const header of prefix.matchAll(headers)) {
      const at = start + header.index;
      if (found.has(at)) continue;
      let fn;
      try {fn = acorn.parseExpressionAt(text,at,{ecmaVersion:'latest'});} catch {continue;}
      if (fn.end < anchor.index || fn.end-anchor.index > 8192) continue;
      const profile = canonicalGuard(fn);
      if (!profile || profile.shape !== expectedShape && profile.shape !== configuredDomainShape) continue;
      found.set(at,{bodyStart:fn.body.start+1,functionStart:fn.start,functionEnd:fn.end,valueName:profile.valueName});
    }
  }
  if(found.size) {
    const pending=new Set(found.keys());
    const last=Math.max(...pending);
    const tokenizer=acorn.tokenizer(text,{ecmaVersion:'latest',sourceType:'module',allowHashBang:true});
    for(;;) {const token=tokenizer.getToken();if(token.start>last||token.type.label==='eof')break;pending.delete(token.start);}
    // A matching function printed inside a string/comment is data, not code.
    for(const invalid of pending)found.delete(invalid);
  }
  if (found.size !== 1) throw new Error('Expected one compatible origin predicate; found '+found.size+'.');
  return {...found.values().next().value,mode:'ast-verified',version:'auto-detected'};
}

function inspectAgyMainJs(body) {
  const source = Buffer.isBuffer(body) ? body : Buffer.from(body);
  if (source.length > MAX_MAIN_JS_BYTES) throw new Error('Frontend exceeds 32 MB limit.');
  const sha256 = crypto.createHash('sha256').update(source).digest('hex');
  let profile = profileCache.get(sha256);
  if (!profile) {
    profile = {...discoverOriginGuard(source.toString('utf8')),sha256};
    if (profileCache.size >= 16) profileCache.delete(profileCache.keys().next().value);
    profileCache.set(sha256,profile);
  }
  return profile;
}

function validateTheiaOrigin(value) {
  const url = new URL(value);
  if (!['http:','https:'].includes(url.protocol) || url.username || url.password ||
      !/^(?:[a-z0-9-]+\.)?webview\.localhost$/i.test(url.hostname) ||
      url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Expected one exact local Theia webview origin.');
  }
  return url.origin;
}

// CCS's WebviewImpl substitutes its actual origin/view ID into this URI.
// Never use cspSource here: it can contain a wildcard for all webviews.
function getTheiaWebviewOrigin(webview, resourceUri) {
  const resourceUrl = new URL(webview.asWebviewUri(resourceUri).toString());
  if(resourceUrl.username||resourceUrl.password)throw new Error('Unexpected credentials in the Webview resource URI.');
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

function adaptAgyMainJs(body, allowedOrigin) {
  const origin = validateTheiaOrigin(allowedOrigin);
  const source = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const profile = inspectAgyMainJs(source);
  const text = source.toString('utf8');
  const injection = '/*CCS_ANTIGRAVITY_ORIGIN*/if('+profile.valueName+'==='+JSON.stringify(origin)+')return true;';
  return Buffer.from(text.slice(0,profile.bodyStart)+injection+text.slice(profile.bodyStart),'utf8');
}

function validateBackendUrl(value) {
  const backend = new URL(value);
  if (backend.protocol !== 'http:' || backend.username || backend.password ||
      !['localhost','127.0.0.1','[::1]'].includes(backend.hostname) ||
      backend.pathname !== '/' || backend.search || backend.hash) throw new Error('Expected one HTTP loopback backend origin.');
  return backend;
}

function decodeBody(body, encoding) {
  const options = {maxOutputLength:MAX_MAIN_JS_BYTES};
  if (!encoding || encoding === 'identity') return body;
  if (encoding === 'gzip') return zlib.gunzipSync(body,options);
  if (encoding === 'deflate') return zlib.inflateSync(body,options);
  if (encoding === 'br') return zlib.brotliDecompressSync(body,options);
  throw new Error('Unsupported frontend content encoding.');
}

function readLocal(url) {
  validateBackendUrl(url.origin);
  return new Promise((resolve,reject)=>{
    const request = http.get(url,{headers:{'accept-encoding':'identity'},agent:false},response=>{
      const chunks=[];let size=0;
      response.on('data',chunk=>{size+=chunk.length;if(size>MAX_MAIN_JS_BYTES)response.destroy(new Error('Frontend exceeds 32 MB limit.'));else chunks.push(chunk);});
      response.once('error',reject);
      response.once('end',()=>{try{resolve({status:response.statusCode,headers:response.headers,body:decodeBody(Buffer.concat(chunks),response.headers['content-encoding'])});}catch(error){reject(error);}});
    });
    const timer=setTimeout(()=>request.destroy(new Error('Backend inspection timed out.')),12000);
    request.once('close',()=>clearTimeout(timer));request.once('error',reject);
  });
}

async function checkBackend(value) {
  const backend=validateBackendUrl(value);
  const root=await readLocal(new URL('/',backend));
  const pending=[];const seen=new Set();
  const add=(relative,base)=>{try{const url=new URL(relative.replace(/&amp;/g,'&'),base);if(url.origin===backend.origin&&!seen.has(url.href)&&pending.length<32){seen.add(url.href);pending.push(url);}}catch{}};
  for(const tag of root.body.toString('utf8').matchAll(/<script\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1/gi))add(tag[2],backend);
  add('/main.js',backend);
  let total=0;
  for(let index=0;index<pending.length;index++) {
    const url=pending[index];const response=await readLocal(url);
    if(response.status!==200||!/javascript|ecmascript/i.test(String(response.headers['content-type']||'')))continue;
    total+=response.body.length;if(total>64*1024*1024)throw new Error('Frontend inspection exceeds 64 MB budget.');
    const text=response.body.toString('utf8');
    if(/vscode-webview:\/\//.test(text))return {...inspectAgyMainJs(response.body),scriptPath:url.pathname+url.search};
    for(const imported of text.matchAll(/(?:\bfrom\s*|\bimport\s*(?:\(\s*)?)(["'])(\.{1,2}\/[^"']+\.m?js(?:\?[^"']*)?)\1/g))add(imported[2],url);
  }
  throw new Error('No compatible origin predicate found in local frontend scripts.');
}

/**
 * Adapt one agy backend for one exact CCS/Theia webview origin.
 * The backend target is fixed; all HTTP bodies, CSRF/auth headers, and WebSocket
 * traffic pass through unchanged. The HTML frame-ancestors directive and one
 * structurally verified JavaScript message guard admit the exact origin.
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
    if (req.method === 'GET') {
      // The reviewed rewrite requires complete, uncompressed source bytes.
      headers['accept-encoding'] = 'identity';
      delete headers['if-none-match'];
      delete headers['if-modified-since'];
      delete headers['if-range'];
      delete headers.range;
    }
    return {
      hostname: backend.hostname === '[::1]' ? '::1' : backend.hostname,
      port: Number(backend.port || 80),
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
    const upstream = trackUpstream(http.request(options, upstreamRes => {
      const headers = { ...upstreamRes.headers };
      const adaptMainJs = req.method === 'GET' && /^(?:application|text)\/(?:javascript|ecmascript|x-javascript)(?:\s*;|$)/i.test(String(headers['content-type'] || ''));
      if (adaptMainJs) {
        if (upstreamRes.statusCode !== 200) {res.writeHead(upstreamRes.statusCode,headers);upstreamRes.pipe(res);return;}
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
          const raw=Buffer.concat(chunks);
          try {
            const decoded=decodeBody(raw,headers['content-encoding']);
            if(!/vscode-webview:\/\//.test(decoded.toString('utf8'))) {res.writeHead(200,headers);res.end(raw);return;}
            patched = adaptAgyMainJs(decoded, origin);
          }
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
    upstream.setTimeout(15000,()=>upstream.destroy(new Error('Backend request timed out.')));
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
    pending = checkBackend(backendUrl).then(()=>createCcsEmbedProxy({ backendUrl, allowedOrigin: origin })).then(proxy => {
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

// Wrap only this extension's VS Code API. No renderer names, bundled aliases,
// extension versions, entry-file locations or backend ports are assumed.
function wrapVsCodeApi(vscode, getContext) {
  const viewProxies=new WeakMap();const webviewProxies=new WeakMap();const cancellations=new WeakMap();
  // Some hosts freeze API objects. A facade avoids Proxy invariants on their
  // non-configurable namespace properties, while preserving class exports.
  function facade(source,overrides) {
    return new Proxy({}, {
      get(_target,key){return overrides.get(source,key);},
      set(_target,key,value){return overrides.set?overrides.set(source,key,value):Reflect.set(source,key,value,source);},
      has(_target,key){return key in source;},ownKeys(){return Reflect.ownKeys(source);},
      getOwnPropertyDescriptor(_target,key){const descriptor=Reflect.getOwnPropertyDescriptor(source,key);return descriptor?{...descriptor,configurable:true}:undefined;},
      getPrototypeOf(){return Reflect.getPrototypeOf(source);},
    });
  }
  const method=(target,key)=>{const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;};
  function wrapWebview(webview) {
    if(webviewProxies.has(webview))return webviewProxies.get(webview);
    let generation=0;let requestedHtml;
    const proxy=facade(webview,{
      get(target,key){if(key==='html'&&requestedHtml!==undefined)return requestedHtml;return method(target,key);},
      set(target,key,value){
        if(key!=='html')return Reflect.set(target,key,value,target);
        requestedHtml=value;const current=++generation;const context=getContext();
        let origin;
        try {origin=getTheiaWebviewOrigin(target,context.extensionUri);} catch {target.html=value;return true;}
        if(typeof value!=='string'||!/<iframe\b/i.test(value)){target.html=value;return true;}
        const urls=[...new Set(value.match(/http:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?=[\/\s"'<>?#;]|$)/gi)||[])];
        if(!urls.length){target.html=value;return true;}
        Promise.all(urls.map(async url=>[url,await getProxyUrl(url,origin,context)])).then(replacements=>{
          if(current!==generation)return;
          let html=value;
          for(const [before,after] of replacements) {
            const escaped=before.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
            html=html.replace(new RegExp(escaped+'(?=[/\\s"\'<>?#;]|$)','g'),after);
          }
          target.html=html;
        }).catch(error=>{
          console.error('[Antigravity CCS adapter]',error.message);
          if(current===generation)target.html='<!doctype html><html><body>Antigravity could not load. Run the repair check to inspect backend compatibility.</body></html>';
        });
        return true;
      },
    });
    cancellations.set(webview,()=>{generation++;});webviewProxies.set(webview,proxy);return proxy;
  }
  function wrapView(view) {
    if(!view)return view;
    if(viewProxies.has(view))return viewProxies.get(view);
    const webview=view.webview;
    if(!webview)return view;
    wrapWebview(webview);
    // The host may invalidate the panel.webview getter before firing disposal.
    if(typeof view.onDidDispose==='function')view.onDidDispose(()=>{const cancel=cancellations.get(webview);if(cancel)cancel();});
    const proxy=facade(view,{get(target,key){return key==='webview'?wrapWebview(target.webview):method(target,key);},set(target,key,value){return Reflect.set(target,key,value,target);}});
    viewProxies.set(view,proxy);return proxy;
  }
  function wrapProvider(provider,positions) {
    return facade(provider,{get(target,key){const original=Reflect.get(target,key,target);
      if(typeof original==='function'&&Object.prototype.hasOwnProperty.call(positions,key))return function(...args){args[positions[key]]=wrapView(args[positions[key]]);return original.apply(target,args);};
      return typeof original==='function'?original.bind(target):original;
    }});
  }
  const window=facade(vscode.window,{get(target,key){
    if(key==='registerWebviewViewProvider')return function(id,provider,...rest){return target[key](id,wrapProvider(provider,{resolveWebviewView:0}),...rest);};
    if(key==='registerCustomEditorProvider')return function(id,provider,...rest){return target[key](id,wrapProvider(provider,{resolveCustomEditor:1,resolveCustomTextEditor:1}),...rest);};
    if(key==='registerWebviewPanelSerializer')return function(id,provider,...rest){return target[key](id,wrapProvider(provider,{deserializeWebviewPanel:0}),...rest);};
    if(key==='createWebviewPanel')return function(...args){return wrapView(target[key](...args));};
    return method(target,key);
  }});
  return facade(vscode,{get(target,key){return key==='window'?window:Reflect.get(target,key,target);}});
}

module.exports = {getProxyUrl,createCcsEmbedProxy,getTheiaWebviewOrigin,adaptAgyMainJs,inspectAgyMainJs,discoverOriginGuard,checkBackend,wrapVsCodeApi};
if(require.main===module) {
  if(process.argv[2]!=='--check-backend'||!process.argv[3]) {console.error('Usage: node adapter.cjs --check-backend http://127.0.0.1:PORT');process.exitCode=2;}
  else checkBackend(process.argv[3]).then(profile=>console.log(JSON.stringify(profile))).catch(error=>{console.error(error.message);process.exitCode=1;});
}
