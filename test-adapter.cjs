'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { createCcsEmbedProxy, adaptAgyMainJs, getTheiaWebviewOrigin } = require('./ccs21-antigravity-proxy.cjs');
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
  assert.throws(()=>adaptAgyMainJs(fixture,origin),/hash changed/);
  const adapted = adaptAgyMainJs(fixture,origin,fixtureHash).toString();
  const sandbox = {window:{location:{origin:'http://127.0.0.1:8'}}};
  vm.runInNewContext(adapted,sandbox);
  assert.equal(sandbox.UNc(origin),true);
  assert.equal(sandbox.UNc('http://other.webview.localhost:62181'),false);
  assert.equal(sandbox.UNc('https://evil.example'),false);
  assert.equal(sandbox.UNc('null'),false);
  const backend=http.createServer((req,res)=>{
    if(req.url==='/') {
      res.setHeader('Content-Type','text/html');
      res.setHeader('Content-Security-Policy',"default-src 'self'; frame-ancestors 'self' http://localhost:*; script-src 'self'");
      res.end('<html>ok</html>');
    } else if(req.url==='/main.js') {
      res.setHeader('Content-Type','application/javascript');res.end(fixture);
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
    const root=await get(proxy.url+'/');
    assert.equal(root.status,200);
    assert.equal(root.headers['content-security-policy'],"default-src 'self'; frame-ancestors 'self' http://localhost:* "+origin+" file:; script-src 'self'");
    const echo=await get(proxy.url+'/echo',{'x-codeium-csrf-token':'test-token'});
    assert.equal(echo.headers['x-auth-echo'],'test-token');
    assert.equal((await get(proxy.url+'/main.js')).status,502);
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
    const live=await createCcsEmbedProxy({backendUrl:process.argv[2],allowedOrigin:origin});
    try {
      const [plain,result]=await Promise.all([get(process.argv[2]+'/main.js'),get(live.url+'/main.js')]);
      assert.equal(result.status,200);
      assert.deepEqual(result.body,adaptAgyMainJs(plain.body,origin));
      assert.equal(Number(result.headers['content-length']),result.body.length);
      assert.equal(result.headers['cache-control'],'no-store');
      assert.equal(result.headers.etag,undefined);
      assert.equal((await get(live.url+'/')).status,200);
    } finally {await live.dispose();}
  }
  console.log('PASS: exact origin, CSP, auth header, WebSocket, version rejection'+(process.argv[2]?', live agy 1.4.2':'')+'.');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
