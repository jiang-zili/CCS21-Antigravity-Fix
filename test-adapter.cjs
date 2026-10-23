'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { createCcsEmbedProxy, adaptAgyMainJs, getTheiaWebviewOrigin, inspectAgyMainJs, checkBackend, getProxyUrl } = require('./ccs21-antigravity-proxy.cjs');
const origin = 'http://test-view.webview.localhost:62181';
function get(url, headers = {}) {
  return new Promise((resolve,reject) => {
    http.get(url,{headers},res=>{
      const chunks=[];
      res.on('data',c=>chunks.push(c));
      res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));
      res.on('error',reject);
    }).on('error',reject);
  });
}
async function main() {
  assert.equal(getTheiaWebviewOrigin({asWebviewUri:()=>new URL(origin+'/asset')},{}),origin);
  for (const bad of ['https://evil.example','http://*.webview.localhost:8000','http://test-view.webview.localhost:80/path','http://127.0.0.1:8000']) {
    assert.throws(()=>getTheiaWebviewOrigin({asWebviewUri:()=>({toString:()=>bad})},{}));
  }
  const fixture = Buffer.from('function UNc(a,b=window.location.origin){if(!a||a==="null")return!1;return a===b}');
  const fixtureHash = crypto.createHash('sha256').update(fixture).digest('hex');
  assert.throws(()=>adaptAgyMainJs(fixture,origin),/Unsupported agy origin-check structure/);
  const profiles = { [fixtureHash]: { version:'fixture-1.4.2', guard:'function UNc(a,b=window.location.origin){if(!a||a==="null")return!1;' } };
  const adapted = adaptAgyMainJs(fixture,origin,profiles).toString();
  const sandbox = {window:{location:{origin:'http://127.0.0.1:8'}}};
  vm.runInNewContext(adapted,sandbox);
  assert.equal(sandbox.UNc(origin),true);
  assert.equal(sandbox.UNc('http://other.webview.localhost:62181'),false);
  assert.equal(sandbox.UNc('https://evil.example'),false);
  assert.equal(sandbox.UNc('null'),false);
  const fixture143 = Buffer.from(fixture.toString().replace('UNc','PQc'));
  const hash143 = crypto.createHash('sha256').update(fixture143).digest('hex');
  const profiles143 = { [hash143]: { version:'fixture-1.4.3', guard:'function PQc(a,b=window.location.origin){if(!a||a==="null")return!1;' } };
  const sandbox143 = {window:{location:{origin:'http://127.0.0.1:8'}}};
  vm.runInNewContext(adaptAgyMainJs(fixture143,origin,profiles143).toString(),sandbox143);
  assert.equal(sandbox143.PQc(origin),true);
  assert.equal(sandbox143.PQc('http://other.webview.localhost:62181'),false);
  assert.equal(inspectAgyMainJs(fixture143,profiles143).version,'fixture-1.4.3');
  assert.throws(()=>inspectAgyMainJs(Buffer.concat([fixture143,Buffer.from(' ')]),profiles143),/Unsupported agy origin-check structure/);
  const future = Buffer.from('function renamedGuard(x,y=window.location.origin){if(!x||x==="null")return!1;' +
    'if(x===y||x.startsWith("vscode-webview://")||x.startsWith("vscode-file://"))return!0;' +
    'try{let z=new URL(x);if(z.protocol!=="http:"&&z.protocol!=="https:")return!1;let h=z.hostname;' +
    'return h==="localhost"||h==="127.0.0.1"||h==="[::1]"||h==="::1"?!0:z.protocol==="https:"?' +
    'h.endsWith(".google.com")||h.endsWith(".future-google.example"):!1}catch{return!1}}');
  assert.equal(inspectAgyMainJs(future).mode,'structure-verified');
  const futureSandbox={window:{location:{origin:'http://127.0.0.1:8'}},URL};
  vm.runInNewContext(adaptAgyMainJs(future,origin).toString(),futureSandbox);
  assert.equal(futureSandbox.renamedGuard(origin),true);
  for (const denied of ['http://other.webview.localhost:62181','https://evil.example','null','']) {
    assert.equal(futureSandbox.renamedGuard(denied),false);
  }
  assert.equal(futureSandbox.renamedGuard('https://www.google.com'),true);
  const formatted = Buffer.from(future.toString().replace('function renamedGuard(x,y=window.location.origin){',
    'function renamedGuard ( x , y = window.location.origin ) {\n')
    .replace(/"([^"\\]*)"/g,"'$1'").replace(/!1/g,'false').replace(/!0/g,'true')
    .replace(/let /g,'const ').replace('}catch{returnfalse}}','} catch { return false; } }')
    .replace(/returnfalse/g,'return false').replace(/returntrue/g,'return true'));
  assert.equal(inspectAgyMainJs(formatted).mode,'structure-verified');
  const formattedSandbox={window:{location:{origin:'http://127.0.0.1:8'}},URL};
  vm.runInNewContext(adaptAgyMainJs(formatted,origin).toString(),formattedSandbox);
  assert.equal(formattedSandbox.renamedGuard(origin),true);
  assert.equal(formattedSandbox.renamedGuard('https://evil.example'),false);
  assert.equal(formattedSandbox.renamedGuard('null'),false);
  assert.throws(()=>inspectAgyMainJs(Buffer.concat([future,future])),/found 2/);
  assert.throws(()=>inspectAgyMainJs(Buffer.from(future.toString().replace('if(!x||x==="null")return!1;','if(!x||x==="null")return!0;'))),/found 0/);
  let servedMain = fixture;
  const backend=http.createServer((req,res)=>{
    if(req.url==='/') {
      res.setHeader('Content-Type','text/html');
      res.setHeader('Content-Security-Policy',"default-src 'self'; frame-ancestors 'self' http://localhost:*; script-src 'self'");
      res.end('<html>ok</html>');
    } else if(req.url==='/main.js') {
      res.setHeader('Content-Type','application/javascript');res.end(servedMain);
    } else { res.setHeader('X-Auth-Echo',req.headers['x-codeium-csrf-token']||''); req.pipe(res); }
  });
  backend.on('upgrade',(req,socket)=>{
    assert.equal(req.headers['x-codeium-csrf-token'],'test-token');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
    socket.pipe(socket);
  });
  await new Promise(r=>backend.listen(0,'127.0.0.1',r));
  const backendUrl='http://127.0.0.1:'+backend.address().port;
  const proxy=await createCcsEmbedProxy({backendUrl,allowedOrigin:origin});
  try {
    await assert.rejects(checkBackend(backendUrl),/Unsupported agy origin-check structure/);
    const context={subscriptions:[]};
    await assert.rejects(getProxyUrl(backendUrl,origin,context),/Unsupported agy origin-check structure/);
    assert.equal(context.subscriptions.length,0);
    const root=await get(proxy.url+'/');
    assert.equal(root.status,200);
    assert.equal(root.headers['content-security-policy'],"default-src 'self'; frame-ancestors 'self' http://localhost:* "+origin+" file:; script-src 'self'");
    const echo=await get(proxy.url+'/echo',{'x-codeium-csrf-token':'test-token'});
    assert.equal(echo.headers['x-auth-echo'],'test-token');
    assert.equal((await get(proxy.url+'/main.js')).status,502);
    servedMain = future;
    assert.equal((await checkBackend(backendUrl)).mode,'structure-verified');
    const futureResponse=await get(proxy.url+'/main.js');
    assert.equal(futureResponse.status,200);
    assert.deepEqual(futureResponse.body,adaptAgyMainJs(future,origin));
    await new Promise((resolve,reject)=>{
      const req=http.get(proxy.url+'/ws',{headers:{Upgrade:'websocket',Connection:'Upgrade','x-codeium-csrf-token':'test-token'}});
      req.on('upgrade',(res,socket)=>{
        socket.write('test-payload');
        socket.once('data',data=>{try {assert.equal(data.toString(),'test-payload');socket.destroy();resolve();}catch(e){reject(e);}});
      });
      req.on('error',reject);req.setTimeout(3000,()=>req.destroy(new Error('Upgrade timeout')));
    });
  } finally { await proxy.dispose(); await new Promise(r=>backend.close(r)); }
  if(process.argv[2]) {
    const profile=await checkBackend(process.argv[2]);
    assert.ok(['hash-pinned','structure-verified'].includes(profile.mode));
    const live=await createCcsEmbedProxy({backendUrl:process.argv[2],allowedOrigin:origin});
    try {
      const [plain,result]=await Promise.all([get(process.argv[2]+'/main.js'),get(live.url+'/main.js')]);
      const updatedBuild=Buffer.concat([plain.body,Buffer.from('\n// simulated backend build update\n')]);
      assert.equal(inspectAgyMainJs(updatedBuild).mode,'structure-verified');
      assert.ok(adaptAgyMainJs(updatedBuild,origin).includes(Buffer.from(JSON.stringify(origin))));
      assert.equal(result.status,200);
      assert.deepEqual(result.body,adaptAgyMainJs(plain.body,origin));
      assert.equal(Number(result.headers['content-length']),result.body.length);
      assert.equal(result.headers['cache-control'],'no-store');
      assert.equal(result.headers.etag,undefined);
      assert.equal((await get(live.url+'/')).status,200);
    } finally {await live.dispose();}
  }
  console.log('PASS: known versions, simulated future update, renamed guard, CSP, auth, WebSocket, incompatible-structure rejection'+(process.argv[2]?', live agy':'')+'.');
}
main().catch(e=>{console.error(e);process.exitCode=1;});

