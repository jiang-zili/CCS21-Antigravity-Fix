'use strict';
const assert=require('node:assert/strict');
const http=require('node:http');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const vm=require('node:vm');
const Module=require('node:module');
const zlib=require('node:zlib');
const adapter=require('./ccs21-antigravity-proxy.cjs');
const origin='http://test-view.webview.localhost:62181';
function samplePredicate(value,expected=window.location.origin) {
  if(!value||value==='null')return false;
  if(value===expected||value.startsWith('vscode-webview://')||value.startsWith('vscode-file://'))return true;
  try {
    let parsed=new URL(value);
    if(parsed.protocol!=='http:'&&parsed.protocol!=='https:')return false;
    const host=parsed.hostname;
    return host==='localhost'||host==='127.0.0.1'||host==='[::1]'||host==='::1'?true:
      parsed.protocol==='https:'?(host.endsWith('.google.com')||host.endsWith('.googleplex.com')):false;
  } catch{return false;}
}
const fixture=samplePredicate.toString();
function evaluatePredicate(source) {
  return vm.runInNewContext('('+source+')',{window:{location:{origin:'http://127.0.0.1:123'}},URL},{timeout:100});
}
function request(url,options={},body) {
  return new Promise((resolve,reject)=>{
    const req=http.request(url,options,res=>{
      const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('error',reject);
      res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));
    });
    req.on('error',reject);req.end(body);
  });
}
async function eventually(check) {
  for(let attempt=0;attempt<100;attempt++){if(check())return;await new Promise(resolve=>setTimeout(resolve,20));}
  assert.fail('Asynchronous Webview did not update.');
}
async function main() {
  const variants=[fixture,
    fixture.replace(/samplePredicate/g,'newName_2027').replace(/\bvalue\b/g,'callerOrigin').replace(/\bexpected\b/g,'otherOrigin').replace(/\bparsed\b/g,'serverAddress').replace(/\bhost\b/g,'hostName'),
    fixture.replace(/^function samplePredicate/,'').replace(') {',') => {'),
    fixture.replace(/return false/g,'return !1').replace(/return true/g,'return !0').replace(/const host/g,'var host'),
  ];
  const cases=[origin,'http://other.webview.localhost:62181','https://evil.example','https://evil.google.com.evil.example','null',null,'http://127.0.0.1:9','vscode-webview://abc','https://docs.google.com'];
  for(const source of variants) {
    const before=evaluatePredicate(source);
    const result=adapter.adaptAgyMainJs(Buffer.from(source),origin).toString();
    const after=evaluatePredicate(result);
    for(const value of cases)assert.equal(after(value),value===origin?true:before(value));
  }
  assert.throws(()=>adapter.inspectAgyMainJs(Buffer.from(fixture+';'+fixture.replace('samplePredicate','secondGuard'))),/found 2/);
  assert.throws(()=>adapter.inspectAgyMainJs(Buffer.from(fixture.replace('return false','return true'))),/found 0/);
  assert.throws(()=>adapter.inspectAgyMainJs(Buffer.from('/* '+fixture+' */')),/found 0/);
  assert.equal(adapter.inspectAgyMainJs(Buffer.from('/* '+fixture+' */\n'+fixture)).mode,'ast-verified');
  assert.throws(()=>adapter.inspectAgyMainJs(Buffer.from('const data=`'+fixture+'`;')),/found 0/);
  for(const bad of ['https://evil.example','http://*.webview.localhost:8000','http://127.0.0.1:8','http://user@test.webview.localhost:8']) {
    assert.throws(()=>adapter.getTheiaWebviewOrigin({asWebviewUri:()=>({toString:()=>bad})},{}));
  }
  for(const allowed of [origin,'http://test.webview.localhost','https://test.webview.localhost:443']) {
    assert.equal(adapter.getTheiaWebviewOrigin({asWebviewUri:()=>new URL(allowed+'/asset')},{}),new URL(allowed).origin);
  }
  let rootMode='hashed';
  const backend=http.createServer((req,res)=>{
    const pathname=new URL(req.url,'http://localhost').pathname;
    if(pathname==='/') {
      res.setHeader('Content-Type','text/html');res.setHeader('Content-Security-Policy',"default-src 'self'; frame-ancestors 'self' http://localhost:*; script-src 'self'");
      res.end('<script type="module" src="'+(rootMode==='import'?'/assets/bootstrap.js':'/assets/client-abcdef.mjs?build=2027')+'"></script>');
    } else if(pathname==='/assets/bootstrap.js') {res.setHeader('Content-Type','text/javascript');res.end('import "./client-abcdef.mjs";');}
    else if(pathname==='/assets/client-abcdef.mjs') {res.setHeader('Content-Type','text/javascript');res.end(fixture);}
    else if(pathname==='/compressed.js') {res.setHeader('Content-Type','application/javascript');res.setHeader('Content-Encoding','gzip');res.end(zlib.gzipSync(fixture));}
    else if(pathname==='/unrelated.js') {res.setHeader('Content-Type','application/javascript');res.end('console.log("unrelated asset")');}
    else if(pathname==='/bad.js') {res.setHeader('Content-Type','application/javascript');res.end(fixture.replace('return false','return true'));}
    else if(pathname==='/echo') {res.setHeader('X-Auth-Echo',req.headers.authorization||'');res.setHeader('X-CSRF-Echo',req.headers['x-codeium-csrf-token']||'');req.pipe(res);}
    else {res.statusCode=404;res.end('missing');}
  });
  backend.on('upgrade',(req,socket)=>{
    assert.equal(req.headers['x-codeium-csrf-token'],'test-token');
    if(req.url==='/reject'){socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\n\r\ndenied');return;}
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');socket.pipe(socket);
  });
  await new Promise(resolve=>backend.listen(0,'127.0.0.1',resolve));
  const backendUrl='http://127.0.0.1:'+backend.address().port;
  const proxy=await adapter.createCcsEmbedProxy({backendUrl,allowedOrigin:origin});
  const context={extensionUri:{},subscriptions:[]};
  try {
    assert.equal((await adapter.checkBackend(backendUrl)).scriptPath,'/assets/client-abcdef.mjs?build=2027');
    rootMode='import';assert.equal((await adapter.checkBackend(backendUrl)).scriptPath,'/assets/client-abcdef.mjs');rootMode='hashed';
    const html=await request(proxy.url+'/');
    assert.equal(html.status,200);assert.equal(html.headers['content-security-policy'],"default-src 'self'; frame-ancestors 'self' http://localhost:* "+origin+" file:; script-src 'self'");
    const liveScript=await request(proxy.url+'/assets/client-abcdef.mjs?build=2027');
    assert.deepEqual(liveScript.body,adapter.adaptAgyMainJs(Buffer.from(fixture),origin));
    assert.equal(liveScript.headers['cache-control'],'no-store');
    const compressed=await request(proxy.url+'/compressed.js');assert.equal(compressed.status,200);assert.equal(compressed.headers['content-encoding'],undefined);assert.deepEqual(compressed.body,liveScript.body);
    assert.equal((await request(proxy.url+'/unrelated.js')).body.toString(),'console.log("unrelated asset")');
    assert.equal((await request(proxy.url+'/bad.js')).status,502);
    const echo=await request(proxy.url+'/echo',{method:'POST',headers:{authorization:'Bearer test-value','x-codeium-csrf-token':'test-token'}},'unchanged-body');
    assert.equal(echo.headers['x-auth-echo'],'Bearer test-value');assert.equal(echo.headers['x-csrf-echo'],'test-token');assert.equal(echo.body.toString(),'unchanged-body');
    await new Promise((resolve,reject)=>{
      const req=http.get(proxy.url+'/ws',{headers:{Upgrade:'websocket',Connection:'Upgrade','x-codeium-csrf-token':'test-token'}});
      req.on('upgrade',(res,socket)=>{socket.write('test-payload');socket.once('data',data=>{try{assert.equal(data.toString(),'test-payload');socket.destroy();resolve();}catch(error){reject(error);}});});req.on('error',reject);
    });
    assert.equal((await request(proxy.url+'/reject',{headers:{Upgrade:'websocket',Connection:'Upgrade','x-codeium-csrf-token':'test-token'}})).status,403);
    let sidebar,custom,serializer;
    const rawViews=[];
    function rawView(theia=true) {
      let html='';let disposed;
      const webview=Object.freeze({get html(){return html;},set html(value){html=value;},asWebviewUri(){assert.equal(this,webview);return new URL(theia?origin+'/resource':'https://normal.vscode-cdn.example/resource');},postMessage(){assert.equal(this,webview);return true;}});
      const view=Object.freeze({webview,onDidDispose(callback){disposed=callback;return {dispose(){}};},dispose(){if(disposed)disposed();}});
      rawViews.push(view);return view;
    }
    class Uri {static joinPath(){return 'kept-static';}}
    const realWindow=Object.freeze({registerWebviewViewProvider(id,provider){assert.equal(this,realWindow);sidebar=provider;return {dispose(){}};},registerCustomEditorProvider(id,provider){custom=provider;return {dispose(){}};},registerWebviewPanelSerializer(id,provider){serializer=provider;return {dispose(){}};},createWebviewPanel(){return rawView();}});
    const api=Object.freeze({window:realWindow,Uri});
    const wrapped=adapter.wrapVsCodeApi(api,()=>context);
    assert.equal(wrapped.Uri,Uri);assert.equal(wrapped.Uri.joinPath(),'kept-static');
    const provider={tag:7,resolveWebviewView(view){assert.equal(this.tag,7);view.webview.html='<iframe src="'+backendUrl+'/?extensionView=true"></iframe><script>const IFRAME_URL="'+backendUrl+'";</script>';view.webview.postMessage({});}};
    wrapped.window.registerWebviewViewProvider('any-renamed-view',provider);
    const raw=rawView();sidebar.resolveWebviewView(raw);
    await eventually(()=>raw.webview.html.includes('iframe')&&!raw.webview.html.includes(backendUrl));
    wrapped.window.registerCustomEditorProvider('settings',{resolveCustomTextEditor(document,panel){provider.resolveWebviewView.call(provider,panel);}});
    const settings=rawView();custom.resolveCustomTextEditor({},settings);await eventually(()=>settings.webview.html.includes('iframe'));
    wrapped.window.registerWebviewPanelSerializer('restored',{deserializeWebviewPanel(panel){provider.resolveWebviewView.call(provider,panel);}});
    const restored=rawView();serializer.deserializeWebviewPanel(restored);await eventually(()=>restored.webview.html.includes('iframe'));
    const native=rawView(false);sidebar.resolveWebviewView(native);assert(native.webview.html.includes(backendUrl));
    const quick=wrapped.window.createWebviewPanel();quick.webview.html='<iframe src="'+backendUrl+'"></iframe>';quick.webview.html='<p>newer render</p>';await new Promise(resolve=>setTimeout(resolve,100));assert.equal(rawViews[rawViews.length-1].webview.html,'<p>newer render</p>');
    const disposed=wrapped.window.createWebviewPanel();disposed.webview.html='<iframe src="'+backendUrl+'"></iframe>';disposed.dispose();await new Promise(resolve=>setTimeout(resolve,100));assert.equal(rawViews[rawViews.length-1].webview.html,'');
    const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'ccs-entry-test-'));
    try {
      const installed=path.join(temporary,'portable extension');fs.mkdirSync(path.join(installed,'dist'),{recursive:true});fs.mkdirSync(path.join(temporary,'node_modules/vscode'),{recursive:true});
      global.__ccsMockApi=api;
      fs.writeFileSync(path.join(temporary,'node_modules/vscode/index.js'),'module.exports=global.__ccsMockApi;');
      fs.copyFileSync(path.join(__dirname,'ccs-antigravity-entry.cjs'),path.join(installed,'wrapper.cjs'));
      fs.writeFileSync(path.join(installed,'ccs-antigravity-adapter.cjs'),'module.exports=require('+JSON.stringify(path.join(__dirname,'ccs21-antigravity-proxy.cjs'))+');');
      fs.writeFileSync(path.join(installed,'.ccs-antigravity-state.json'),JSON.stringify({originalMain:'./dist/renamed-loader.cjs'}));
      fs.writeFileSync(path.join(installed,'dist/renamed-loader.cjs'),'const api=require("vscode");exports.activate=ctx=>({api,ctx});exports.deactivate=()=>42;');
      const previous=Module._load;
      const entry=require(path.join(installed,'wrapper.cjs'));
      const activeContext={extensionUri:{},subscriptions:[]};const activation=entry.activate(activeContext);
      assert.equal(activation.ctx,activeContext);assert.notEqual(activation.api.window,realWindow);assert.equal(activation.api.Uri,Uri);
      const outside=Module.createRequire(path.join(temporary,'unrelated-extension.cjs'));assert.equal(outside('vscode'),api);
      assert.equal(entry.deactivate(),42);assert.equal(Module._load,previous);
      entry.activate(activeContext);entry.deactivate();assert.equal(Module._load,previous);
    } finally {delete global.__ccsMockApi;fs.rmSync(temporary,{recursive:true,force:true});}
    if(process.argv[2]) {const live=await adapter.checkBackend(process.argv[2]);assert.equal(live.mode,'ast-verified');console.log('Live backend:',live.sha256);}
  } finally {
    for(const disposable of context.subscriptions)await disposable.dispose();
    await proxy.dispose();await new Promise(resolve=>backend.close(resolve));
  }
  if(fs.existsSync('.local/agy-1.4.2-main.js'))assert.equal(adapter.inspectAgyMainJs(fs.readFileSync('.local/agy-1.4.2-main.js')).mode,'ast-verified');
  console.log('PASS: version-independent AST checks; hashed/module paths; CSP/auth/HTTP/WebSocket; frozen APIs; sidebar/custom editor/serializer/panel hooks; render races/disposal; scoped entry loader.');
}
main().catch(error=>{console.error(error);process.exitCode=1;});

// Regression: configured-domain guard, including rejection of altered domain validation.
{const guard="function NTc(a,b=window.location.origin){if(!a||a===\"null\")return!1;if(a===b||a.startsWith(\"vscode-webview://\")||a.startsWith(\"vscode-file://\"))return!0;try{let k=new URL(a);if(k.protocol!==\"http:\"&&k.protocol!==\"https:\")return!1;let l=k.hostname;if(l===\"localhost\"||l===\"127.0.0.1\"||l===\"[::1]\"||l===\"::1\")var c=!0;else{if(k.protocol===\"https:\"){var d;if(!(d=l.endsWith(\".google.com\")||l.endsWith(\".googleplex.com\")||l.endsWith(\".googlers.com\")||l.endsWith(\".googleprod.com\")||l.endsWith(\".cloudworkstations.dev\")||l.endsWith(\".cloudworkstations.googleusercontent.com\")||\nl.endsWith(\".cloudshell.dev\")||l.endsWith(\".cloudshell.googleusercontent.com\")))a:{var f=typeof window!==\"undefined\"?window.__APP_CONFIG__?.allowedDomains:void 0;if(f?.length){var g=l.toLowerCase();for(let m of f){let n=m.trim().toLowerCase().replace(/^\\*\\./,\"\").replace(/^\\.+|\\.+$/g,\"\");if(n&&n.includes(\".\")&&!n.includes(\"*\")&&(g===n||g.endsWith(`.${n}`))){d=!0;break a}}}d=!1}var h=d}else h=!1;c=h}return c}catch{return!1}}";const a=require("./ccs21-antigravity-proxy.cjs");assert.equal(a.inspectAgyMainJs(guard).mode,"ast-verified");assert.throws(()=>a.inspectAgyMainJs(guard.replace('n.includes(".")','true')));}
