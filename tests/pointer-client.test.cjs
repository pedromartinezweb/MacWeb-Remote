const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {test} = require('node:test');

function client(desktop = true) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      style: {}, dataset: {}, listeners: {}, value: '', hidden: false,
      addEventListener(name, handler) { this.listeners[name] = handler; },
      getBoundingClientRect() { return {left:100, top:50, width:1000, height:500}; },
      setPointerCapture() {}, setAttribute() {}, removeAttribute() {},
      classList: {toggle() {}}, close() {}, replaceChildren() {},
    });
    return elements.get(id);
  };
  const context = vm.createContext({
    document: {documentElement:{dataset:{}}, getElementById:element, querySelectorAll:()=>[], addEventListener() {}},
    window: {matchMedia:()=>({matches:desktop,addEventListener() {}}),addEventListener() {}}, ResizeObserver:class {observe() {}},
    setInterval:()=>0, clearInterval() {}, setTimeout:()=>0, clearTimeout() {},
    location: {hash:'', pathname:'/'}, history: {replaceState() {}},
    fetch: async()=>({ok:true, json:async()=>({availableHere:false})}),
    InputSender:class {enqueue() {} reset() {}},FramePlayer:class {start() {} stop() {}},Passkeys: {available:()=>false}, Option:class {}, sent:[],
  });
  vm.runInContext(fs.readFileSync('Web/app.js','utf8'),context);
  vm.runInContext('connected = true; command = value => sent.push(value);',context);
  const dispatch = (name, overrides={}) => element('viewport').listeners[name]({
    pointerId:1, pointerType:'mouse', button:0, clientX:350, clientY:250,
    preventDefault() {}, ...overrides,
  });
  return {context, dispatch, sent:context.sent};
}

test('mouse hover moves directly without holding a button in default mode',()=>{
  const {dispatch,sent}=client();
  dispatch('pointermove');
  assert.equal(sent.length,1);
  assert.equal(sent[0].type,'move');
  assert.equal(sent[0].x,.25); assert.equal(sent[0].y,.4);
});

test('mouse click and drag use the position under the pointer',()=>{
  const {dispatch,sent}=client();
  dispatch('pointerdown',{button:2});
  assert.equal(sent.at(-1).type,'down'); assert.equal(sent.at(-1).button,2);
  assert.equal(sent.at(-1).x,.25); assert.equal(sent.at(-1).y,.4);
  dispatch('pointermove',{clientX:850,clientY:450});
  assert.equal(sent.at(-1).x,.75); assert.equal(sent.at(-1).y,.8);
  dispatch('pointerup',{button:2,clientX:900,clientY:500});
  assert.equal(sent.at(-1).type,'up'); assert.equal(sent.at(-1).button,2);
  assert.equal(sent.at(-1).x,.8); assert.equal(sent.at(-1).y,.9);
});

test('touch trackpad retains relative movement and tap-to-click',()=>{
  const {dispatch,sent}=client();
  dispatch('pointerdown',{pointerType:'touch'});
  assert.equal(sent.length,0);
  dispatch('pointermove',{pointerType:'touch',clientX:450});
  assert.equal(sent[0].type,'move'); assert.equal(sent[0].x,.63);
  dispatch('pointerup',{pointerType:'touch',clientX:450});
  assert.equal(sent.length,1);
});

test('disconnected mouse movement does not queue input',()=>{
  const {context,dispatch,sent}=client();
  vm.runInContext("connected=false; mode='touch';",context);
  dispatch('pointermove');
  assert.equal(sent.length,0);
});


test('desktop capabilities select mouse controls automatically',()=>{
  const {context}=client(true);
  assert.equal(vm.runInContext('document.documentElement.dataset.inputMode',context),'desktop');
});

test('touch capabilities select touch controls and adapt to a real mouse',()=>{
  const {context,dispatch}=client(false);
  assert.equal(vm.runInContext('document.documentElement.dataset.inputMode',context),'touch');
  dispatch('pointermove');
  assert.equal(vm.runInContext('document.documentElement.dataset.inputMode',context),'desktop');
  dispatch('pointerdown',{pointerType:'touch'});
  assert.equal(vm.runInContext('document.documentElement.dataset.inputMode',context),'touch');
});
