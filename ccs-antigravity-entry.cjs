'use strict';
// The original entry keeps its location and relative imports. Only this
// extension receives the wrapped API, including lazily required modules.
const fs=require('node:fs');
const path=require('node:path');
const Module=require('node:module');
const config=JSON.parse(fs.readFileSync(path.join(__dirname,'.ccs-antigravity-state.json'),'utf8').replace(/^\uFEFF/,''));
const originalPath=path.resolve(__dirname,config.originalMain);
const root=path.resolve(__dirname)+path.sep;
function inside(filename){return typeof filename==='string'&&(path.resolve(filename)+path.sep).toLowerCase().startsWith(root.toLowerCase());}
if(!inside(originalPath)||originalPath===__filename)throw new Error('Invalid original Antigravity entry.');
const originalApi=require('vscode');
const adapter=require('./ccs-antigravity-adapter.cjs');
let context;
let enabled=true;
let installed=false;
let previousLoad=Module._load;
const api=adapter.wrapVsCodeApi(originalApi,()=>context);
function scopedLoad(request,parent,isMain){
  if(enabled&&request==='vscode'&&parent&&inside(parent.filename))return api;
  return previousLoad.apply(this,arguments);
}
function attach(){enabled=true;if(!installed){previousLoad=Module._load;Module._load=scopedLoad;installed=true;}}
function cleanup(){enabled=false;if(Module._load===scopedLoad){Module._load=previousLoad;installed=false;}}
attach();
let original;
try{original=require(originalPath);}catch(error){cleanup();throw error;}
const lifecycle=typeof original.activate==='function'?original:(original.default||original);
module.exports={...original,
  activate(...args){
    context=args[0];attach();
    if(context&&Array.isArray(context.subscriptions))context.subscriptions.push({dispose:cleanup});
    if(typeof lifecycle.activate!=='function')return original;
    return lifecycle.activate.apply(lifecycle,args);
  },
  deactivate(...args){try{const result=typeof lifecycle.deactivate==='function'?lifecycle.deactivate.apply(lifecycle,args):undefined;if(result&&typeof result.finally==='function')return result.finally(cleanup);cleanup();return result;}catch(error){cleanup();throw error;}},
};
