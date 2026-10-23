'use strict';
// Local protocol fixture only. It never contacts Google or sends a model request.
const http = require('node:http');
const fs = require('node:fs');
const main = 'function renamedGuard(x,y=window.location.origin){if(!x||x==="null")return!1;'+
  'if(x===y||x.startsWith("vscode-webview://")||x.startsWith("vscode-file://"))return!0;'+
  'try{let z=new URL(x);if(z.protocol!=="http:"&&z.protocol!=="https:")return!1;let h=z.hostname;'+
  'return h==="localhost"||h==="127.0.0.1"||h==="[::1]"||h==="::1"?!0:z.protocol==="https:"?'+
  'h.endsWith(".google.com")||h.endsWith(".future-google.example"):!1}catch{return!1}}';
const server = http.createServer((req,res) => {
  if (req.url === '/main.js') { res.setHeader('Content-Type','application/javascript'); res.end(main); }
  else { res.setHeader('Content-Security-Policy',"default-src 'self'; frame-ancestors 'self'"); res.end('<html>fixture</html>'); }
});
server.listen(0,'127.0.0.1',() => {
  const url='http://127.0.0.1:'+server.address().port;
  if (process.argv[2]) fs.writeFileSync(process.argv[2],url);
  console.log(url);
});
