const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const tick = () => new Promise(resolve => setImmediate(resolve));
function transport(extra={}) {
  const context=vm.createContext({TextEncoder,AbortController,setTimeout,clearTimeout,URL,...extra});
  vm.runInContext(fs.readFileSync('Web/transport.js','utf8')+'\nthis.InputSender=InputSender;this.FramePlayer=FramePlayer;',context);
  return context;
}

test('input batches preserve button order while replacing stale adjacent moves',async()=>{
  const pending=[], calls=[], errors=[];
  const {InputSender}=transport();
  const sender=new InputSender(value=>{calls.push(JSON.parse(JSON.stringify(value)));return new Promise(resolve=>pending.push(resolve));},()=>true,error=>errors.push(error));
  sender.enqueue({type:'move',x:0,y:0});
  sender.enqueue({type:'move',x:.1,y:.1});
  sender.enqueue({type:'move',x:.2,y:.2});
  sender.enqueue({type:'down',x:.2,y:.2});
  sender.enqueue({type:'move',x:.3,y:.3});
  sender.enqueue({type:'up',x:.3,y:.3});
  assert.equal(calls.length,1);
  pending.shift()();await tick();
  assert.deepEqual(calls[1].events.map(event=>event.type),['move','down','move','up']);
  assert.equal(calls[1].events[0].x,.2);
  pending.shift()();await tick();assert.equal(errors.length,0);
});

test('disconnect drops queued commands and ignores the previous session completion',async()=>{
  const calls=[],pending=[];
  const {InputSender}=transport();
  const sender=new InputSender(value=>{calls.push(value);return new Promise(resolve=>pending.push(resolve));},()=>true,()=>{});
  sender.enqueue({type:'release'});sender.enqueue({type:'key',key:'a'});
  sender.reset();sender.enqueue({type:'key',key:'b'});
  pending[0]();await tick();assert.equal(calls.length,2);
  assert.equal(calls[1].events[0].key,'b');pending[1]();await tick();
});

test('input envelopes stay within the server body limit for Unicode text',async()=>{
  const calls=[],pending=[];
  const {InputSender}=transport();
  const sender=new InputSender(value=>{calls.push(value);return new Promise(resolve=>pending.push(resolve));},()=>true,()=>{});
  sender.enqueue({type:'release'});
  for(let i=0;i<8;i++)sender.enqueue({type:'text',text:'漢'.repeat(4096)});
  while(pending.length){pending.shift()();await tick();}
  assert.equal(calls.reduce((count,batch)=>count+batch.events.length,0),9);
  for(const batch of calls)assert.ok(Buffer.byteLength(JSON.stringify(batch))<=49152);
});

test('video requests the next frame only after download and decode complete',async()=>{
  const calls=[],revoked=[],resolvers=[],decode=[];
  const image={src:'',decode:()=>new Promise(resolve=>decode.push(resolve))};
  const {FramePlayer}=transport({fetch:(url,options)=>{calls.push({url,options});return new Promise(resolve=>resolvers.push(resolve));},URL:{createObjectURL:()=>`blob:${calls.length}`,revokeObjectURL:url=>revoked.push(url)}});
  const player=new FramePlayer(image,()=>{});player.start();
  assert.equal(calls.length,1);
  resolvers.shift()({ok:true,status:200,headers:{get:()=> '7'},blob:async()=>({})});await tick();
  assert.equal(calls.length,1);assert.equal(image.src,'blob:1');
  decode.shift()();await new Promise(resolve=>setTimeout(resolve,40));assert.equal(calls.length,2);
  assert.equal(calls[1].url,'/api/frame?after=7');
  player.stop();assert.equal(calls[1].options.signal.aborted,true);
  resolvers.shift()({ok:true,status:200,headers:{get:()=> '7'},blob:async()=>({})});await tick();
  assert.equal(calls.length,2);assert.deepEqual(revoked,['blob:1']);
});

test('a late frame from a stopped video session cannot replace the image',async()=>{
  let complete;const errors=[];const image={src:'original',decode:async()=>{}};
  const {FramePlayer}=transport({fetch:()=>new Promise(resolve=>complete=resolve),URL:{createObjectURL:()=>{throw Error('stale frame');},revokeObjectURL(){}}});
  const player=new FramePlayer(image,error=>errors.push(error));player.start();player.stop();
  complete({ok:true,status:200,headers:{get:()=> '7'},blob:async()=>({})});await tick();
  assert.equal(image.src,'original');assert.equal(errors.length,0);
});


test('a failed input request releases held buttons before subsequent input',async()=>{
  const calls=[];let fail=true;
  const {InputSender}=transport();
  const sender=new InputSender(async batch=>{calls.push(JSON.parse(JSON.stringify(batch)));if(fail)throw Error('offline');},()=>true,()=>{});
  sender.enqueue({type:'down',x:.5,y:.5});await tick();
  fail=false;sender.enqueue({type:'key',key:'a'});await tick();
  assert.deepEqual(calls[1].events.map(event=>event.type),['release','key']);
});
