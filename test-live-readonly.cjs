'use strict';
const assert=require('node:assert/strict');
const http=require('node:http');
const adapter=require('./ccs21-antigravity-proxy.cjs');
function get(url){return new Promise((resolve,reject)=>{const r=http.get(url,{headers:{'accept-encoding':'identity'}},res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));res.on('error',reject);});r.setTimeout(10000,()=>r.destroy(new Error('timeout')));r.on('error',reject);});}
async function main(){
 const backend=process.argv[2];if(!backend)throw new Error('Specify a current local backend URL');
 const origin='http://test-view.webview.localhost:62181';
 const profile=await adapter.checkBackend(backend);
 const proxy=await adapter.createCcsEmbedProxy({backendUrl:backend,allowedOrigin:origin});
 try{
  const page=await get(proxy.url+'/');assert.equal(page.status,200);
  const policy=String(page.headers['content-security-policy']||'');assert(policy.includes(origin),'Exact test webview origin not present in CSP');
  const [raw,patched]=await Promise.all([get(backend+profile.scriptPath),get(proxy.url+profile.scriptPath)]);
  assert.equal(raw.status,200);assert.equal(patched.status,200);
  assert.deepEqual(patched.body,adapter.adaptAgyMainJs(raw.body,origin));
  console.log(JSON.stringify({mode:profile.mode,sha256:profile.sha256,scriptPath:profile.scriptPath,rootStatus:page.status,adaptedStatus:patched.status,cspExactOrigin:true}));
 }finally{await proxy.dispose();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
