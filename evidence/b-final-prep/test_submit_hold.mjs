import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {holdExactPost} from './submit_hold.mjs';
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'uten-b-real-transport-'));
const pathname='/api/production/material-analyses/00000000-0000-0000-0000-000000000001/aggregate-orders/submit';
const input=crypto.randomBytes(256*1024),headers={'x-synthetic-original':'retained','content-type':'application/json'};
const metadata=[];let calls=0;let observed;
const upstream=http.createServer((req,res)=>{calls++;const chunks=[];req.on('data',c=>chunks.push(c));req.on('end',()=>{observed={body:Buffer.concat(chunks),header:req.headers['x-synthetic-original']};res.end('actual-upstream-success');});});
await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
let heldRequest;
const proxy=http.createServer((req,res)=>{
  const forward=()=>{const out=http.request({host:'127.0.0.1',port:upstream.address().port,path:req.url,method:req.method,headers:req.headers},reply=>{res.writeHead(reply.statusCode,reply.headers);reply.pipe(res);});req.pipe(out);};
  if(holdExactPost(req,res,req.url,directory,forward,v=>metadata.push(v))) {heldRequest=req;return;}
  forward();
});
await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
fs.writeFileSync(path.join(directory,'fault.json'),JSON.stringify({holdNextPost:{path:pathname,tag:'legal-service-test'},loseCommittedReplyPaths:['/keep-this']}));
const reply=new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port:proxy.address().port,path:pathname,method:'POST',headers},res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve(Buffer.concat(chunks).toString()));});req.on('error',reject);req.end(input);});
const ready=path.join(directory,'transport-holds/legal-service-test/hold-ready.json');
for(let n=0;n<200&&!fs.existsSync(ready);n++)await new Promise(r=>setTimeout(r,5));
assert.ok(fs.existsSync(ready));await new Promise(r=>setTimeout(r,80));assert.equal(calls,0);
// Node may already have delivered one socket read to the HTTP parser before
// the handler pauses it. Do not equate the high-water threshold to a hard cap.
const pausedBytes=heldRequest.readableLength;
assert.ok(pausedBytes<=128*1024);assert.ok(pausedBytes<input.length);
const signal=JSON.parse(fs.readFileSync(ready));assert.equal(signal.path,pathname);assert.equal(Object.hasOwn(signal,'headers'),false);assert.equal(Object.hasOwn(signal,'body'),false);
assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory,'fault.json'))).loseCommittedReplyPaths,['/keep-this']);
fs.writeFileSync(path.join(directory,'transport-holds/legal-service-test/release'),'synthetic public-service mutation finished');
assert.equal(await reply,'actual-upstream-success');assert.equal(calls,1);assert.deepEqual(observed.body,input);assert.equal(observed.header,headers['x-synthetic-original']);assert.equal(metadata[0].transportHold,'released-unchanged');
proxy.close();upstream.close();
console.log(JSON.stringify({kind:'transport module verification only; not Web business acceptance',status:'PASS',bytesCompared:input.length,upstreamCalls:calls,metadataOnly:true,requestBytesAndSyntheticHeaderUnchanged:true,pausedBytesObserved:pausedBytes,boundedPausedBufferUnder128KiB:true}));
