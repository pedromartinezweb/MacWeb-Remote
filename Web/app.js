'use strict';
const $ = id => document.getElementById(id);
let authConfig = null;
let connected = false, state = null, mode = 'trackpad', dragging = false, cursor = {x:.5,y:.5};
let commands = [], sending = false, lastTap = 0, keyboardOpen = false, statusTimer, heartbeatTimer;
const modifiers = new Set(), touches = new Map();
let gesture = null, holdTimer = null;
const desktopInput = window.matchMedia('(pointer: fine) and (hover: hover)');
function setInputProfile(profile) {
  document.documentElement.dataset.inputMode = profile;
  $('pointer').hidden = profile === 'desktop' || mode === 'touch';
  if (profile === 'desktop' && keyboardOpen) {
    keyboardOpen = false;
    $('keybar').classList.toggle('keyboardOpen', false);
    $('keyboardInput').blur();
  }
}
setInputProfile(desktopInput.matches ? 'desktop' : 'touch');
desktopInput.addEventListener('change', event => setInputProfile(event.matches ? 'desktop' : 'touch'));

function notice(text) { $('notice').textContent=text; $('notice').hidden=!text; }
async function api(path, value) {
  const response = await fetch('/api/'+path, value===undefined ? {cache:'no-store'} : {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});
  const result = await response.json();
  if (!response.ok) {
    if(response.status===401 && path!=='login') disconnect();
    throw new Error(result.error || 'Could not complete the request');
  }
  return result;
}
function command(value) {
  value.modifiers=[...modifiers];
  if(value.type==='move' && commands.at(-1)?.type==='move') commands[commands.length-1]=value;
  else if(commands.length<80) commands.push(value);
  pump();
}
async function pump() {
  if(sending || !commands.length || !connected) return;
  sending=true;
  try { while(commands.length && connected) await api('input',commands.shift()); }
  catch(error) { commands=[]; notice(error.message); }
  finally { sending=false; }
}
function key(key) { command({type:'key',key}); }
function point() { return {x:cursor.x,y:cursor.y}; }
function move(x,y) {
  cursor.x=Math.max(0,Math.min(1,x)); cursor.y=Math.max(0,Math.min(1,y));
  $('pointer').style.left=(cursor.x*100)+'%'; $('pointer').style.top=(cursor.y*100)+'%';
  command({type:'move',...point()});
}
function absolute(event) {
  const bounds=$('stage').getBoundingClientRect();
  return {x:(event.clientX-bounds.left)/bounds.width,y:(event.clientY-bounds.top)/bounds.height};
}
function fit() {
  if(!state) return;
  const display=state.displays.find(d=>d.id===state.selectedDisplay);
  if(!display) return;
  const rect=$('viewport').getBoundingClientRect();
  const ratio=Math.min(rect.width/display.width,rect.height/display.height);
  $('stage').style.width=Math.floor(display.width*ratio)+'px';
  $('stage').style.height=Math.floor(display.height*ratio)+'px';
}
function stream() {
  $('screen').src='/api/stream?t='+Date.now();
}
async function refresh() {
  try {
    state=await api('status');
    const permissions = !state.screenPermission ? 'Enable Screen Recording on this Mac.' : !state.inputPermission ? 'Enable Accessibility on this Mac to control the mouse and keyboard.' : '';
    notice(state.error || permissions);
    $('connection').textContent=state.frames ? (state.monitorsOff?'Virtual display · physical displays off':'Connected to Mac') : 'Waiting for Screen Recording access';
    $('waiting').hidden=state.frames>0;
    const options=state.displays.map(d=>({value:String(d.id),text:(d.virtual?'Virtual':'Display '+d.id)+' · '+d.width+' × '+d.height}));
    if(JSON.stringify(options)!==$('display').dataset.options) {
      $('display').replaceChildren(...options.map(o=>new Option(o.text,o.value)));
      $('display').dataset.options=JSON.stringify(options);
    }
    $('display').value=String(state.selectedDisplay);
    $('display').disabled=state.busy || state.monitorsOff;
    $('virtual').disabled=state.busy || !state.screenPermission;
    $('monitors').disabled=state.busy || (!state.monitorsOff && (!state.virtualDisplay || state.selectedDisplay!==state.virtualDisplay));
    $('monitors').textContent=state.monitorsOff?'Turn on Mac displays':'Turn off Mac displays';
    $('details').textContent=state.frames+' frames captured · '+(state.frameBytes/1024).toFixed(0)+' KB per frame · local HTTPS';
    fit();
  } catch(error) { if(connected) { $('connection').textContent='No response'; notice(error.message); } }
}
async function connect() {
  connected=true;
  $('login').hidden=true; $('remote').hidden=false;
  stream(); await refresh();
  clearInterval(statusTimer); clearInterval(heartbeatTimer);
  statusTimer=setInterval(refresh,3000);
  heartbeatTimer=setInterval(()=>{ if(!document.hidden) api('heartbeat',{}).catch(()=>{}); },5000);
  api('heartbeat',{}).catch(()=>{});
}
function disconnect() {
  connected=false; commands=[];
  clearInterval(statusTimer); clearInterval(heartbeatTimer);
  $('screen').removeAttribute('src'); $('login').hidden=false; $('remote').hidden=true;
  $('settings').close();
}
$('loginForm').addEventListener('submit',async event=>{
  event.preventDefault(); $('loginError').textContent='';
  try { await api('login',{token:$('token').value.trim()}); $('token').value=''; await connect(); }
  catch(error) { $('loginError').textContent=error.message; }
});
$('settingsButton').onclick=()=>{ $('settings').showModal(); refreshPasskeys(); };
$('reconnect').onclick=stream;
$('logout').onclick=async()=>{ try {await api('logout',{});} finally {disconnect();} };
async function change(path,value) {
  try { notice(''); await api(path,value); stream(); await refresh(); }
  catch(error) {notice(error.message);}
}
$('display').onchange=()=>change('display',{id:Number($('display').value)});
$('quality').onchange=()=>change('quality',{quality:$('quality').value});
$('virtual').onclick=async()=>{ $('virtual').disabled=true; await change('virtual',{}); };
$('monitors').onclick=()=>change('monitors',{off:!state.monitorsOff});
$('mode').onclick=()=>{
  mode=mode==='trackpad'?'touch':'trackpad';
  $('mode').textContent=mode==='trackpad'?'Trackpad':'Direct touch';
  $('mode').setAttribute('aria-pressed',String(mode==='touch'));
  setInputProfile(document.documentElement.dataset.inputMode);
  $('gestureHelp').textContent=mode==='trackpad'?'One finger to move · tap to click · two fingers to scroll · hold to drag':'Tap the desktop · two fingers to scroll · hold to drag';
};
$('rightClick').onclick=()=>command({type:'click',button:2,...point()});
function setDragging(value) {
  if(value===dragging) return;
  dragging=value; $('drag').setAttribute('aria-pressed',String(value));
  command({type:value?'down':'up',...point()});
}
$('drag').onclick=()=>setDragging(!dragging);
for(const button of document.querySelectorAll('[data-key]')) button.onclick=()=>key(button.dataset.key);
for(const button of document.querySelectorAll('[data-mod]')) button.onclick=()=>{
  const value=button.dataset.mod;
  modifiers.has(value)?modifiers.delete(value):modifiers.add(value);
  button.setAttribute('aria-pressed',String(modifiers.has(value)));
};
$('keyboard').onclick=()=>{
  keyboardOpen=!keyboardOpen;
  $('keybar').classList.toggle('keyboardOpen',keyboardOpen);
  if(keyboardOpen) $('keyboardInput').focus(); else $('keyboardInput').blur();
};
$('keyboardInput').addEventListener('input',event=>{
  if(event.isComposing) return;
  const text=$('keyboardInput').value;
  if(text) command({type:'text',text});
  $('keyboardInput').value='';
});
$('keyboardInput').addEventListener('beforeinput',event=>{
  if(event.inputType==='deleteContentBackward') {event.preventDefault();key('Backspace');}
  if(event.inputType==='insertLineBreak') {event.preventDefault();key('Enter');}
});
window.addEventListener('keydown',event=>{
  if(!connected || $('settings').open || (event.target!==$('keyboardInput') && /INPUT|TEXTAREA|SELECT/.test(event.target.tagName))) return;
  if(event.key==='Meta'||event.key==='Control'||event.key==='Alt'||event.key==='Shift') return;
  const modified=event.metaKey||event.ctrlKey||event.altKey;
  const special=['Enter','Tab','Backspace','Escape','Delete','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'].includes(event.key)||/^F\d+$/.test(event.key);
  if(modified || special) {
    event.preventDefault();
    const list=new Set(modifiers);
    if(event.metaKey)list.add('meta'); if(event.ctrlKey)list.add('ctrl'); if(event.altKey)list.add('alt'); if(event.shiftKey)list.add('shift');
    const value={type:'key',key:event.key.toLowerCase().length===1?event.key.toLowerCase():event.key,modifiers:[...list]};
    commands.push(value); pump();
  } else if(event.target!==$('keyboardInput') && event.key.length===1) {event.preventDefault();command({type:'text',text:event.key});}
});
const viewport=$('viewport');
viewport.addEventListener('contextmenu',event=>event.preventDefault());
viewport.addEventListener('pointerdown',event=>{
  if(!connected)return;
  setInputProfile(event.pointerType === 'mouse' ? 'desktop' : 'touch');
  event.preventDefault(); viewport.setPointerCapture(event.pointerId);
  touches.set(event.pointerId,{x:event.clientX,y:event.clientY});
  if(touches.size===1) {
    gesture={x:event.clientX,y:event.clientY,start:Date.now(),distance:0,multi:false,held:false};
    if(event.pointerType==='mouse' || mode==='touch'){const p=absolute(event);move(p.x,p.y);}
    if(event.pointerType==='mouse') {command({type:'down',button:event.button,...point()});gesture.held=true;}
    else holdTimer=setTimeout(()=>{if(gesture&&!gesture.multi&&gesture.distance<8&&!dragging){setDragging(true);gesture.held=true;}},450);
  } else {clearTimeout(holdTimer);if(gesture)gesture.multi=true;}
});
viewport.addEventListener('pointermove',event=>{
  if(!connected)return;
  if(event.pointerType==='mouse'){setInputProfile('desktop');const p=absolute(event);move(p.x,p.y);return;}
  const previous=touches.get(event.pointerId);
  if(!previous)return;
  event.preventDefault();
  const dx=event.clientX-previous.x,dy=event.clientY-previous.y;
  touches.set(event.pointerId,{x:event.clientX,y:event.clientY});
  if(!gesture)return;
  gesture.distance+=Math.hypot(dx,dy);
  if(gesture.distance>8)clearTimeout(holdTimer);
  if(touches.size>1) command({type:'scroll',dx:-dx,dy:-dy});
  else if(!gesture.multi) {
    if(mode==='touch'){const p=absolute(event);move(p.x,p.y);}
    else {const bounds=viewport.getBoundingClientRect();move(cursor.x+dx/bounds.width*1.3,cursor.y+dy/bounds.height*1.3);}
  }
});
function endPointer(event) {
  if(!touches.has(event.pointerId))return;
  touches.delete(event.pointerId);clearTimeout(holdTimer);
  if(touches.size || !gesture)return;
  if(event.pointerType==='mouse' && event.type!=='pointercancel'){const p=absolute(event);move(p.x,p.y);}
  if(event.type==='pointercancel'){setDragging(false);command({type:'release'});}
  else if(gesture.held) {
    if(event.pointerType==='mouse')command({type:'up',button:event.button,...point()});
    else setDragging(false);
  } else if(!gesture.multi && gesture.distance<10 && Date.now()-gesture.start<450 && !dragging) {
    const now=Date.now(),count=now-lastTap<350?2:1;lastTap=now;
    command({type:'click',...point(),count});
  }
  gesture=null;
}
viewport.addEventListener('pointerup',endPointer);
viewport.addEventListener('pointercancel',endPointer);
viewport.addEventListener('wheel',event=>{event.preventDefault();command({type:'scroll',dx:-event.deltaX,dy:-event.deltaY});},{passive:false});
window.addEventListener('resize',fit);
new ResizeObserver(fit).observe(viewport);
window.addEventListener('blur',()=>{if(connected){setDragging(false);command({type:'release'});}});
document.addEventListener('visibilitychange',()=>{
  if(connected && !document.hidden){api('heartbeat',{}).catch(()=>{});stream();refresh();}
});
async function restoreAuthentication(){
  await configureAuthentication();
  const token=decodeURIComponent(location.hash.slice(1));
  if(token) { $('recovery').open=true; history.replaceState(null,'',location.pathname);$('token').value=token;try{await api('login',{token});$('token').value='';await connect();}catch(error){$('loginError').textContent=error.message;}}
  else try{await api('status');await connect();}catch{}
}

async function configureAuthentication() {
  try {
    authConfig = await api('auth/config');
    const supported = authConfig.availableHere && Passkeys.available();
    $('passkeyLogin').disabled = !supported || !authConfig.hasPasskeys;
    $('registerPasskey').disabled = !supported;
    if (!authConfig.availableHere) {
      $('passkeyHint').textContent = 'To use passkeys, open the DNS link configured in the Mac app: ' + authConfig.origin;
    } else if (!Passkeys.available()) {
      $('passkeyHint').textContent = 'This browser requires trusted HTTPS to use passkeys.';
    } else if (!authConfig.hasPasskeys) {
      $('passkeyHint').textContent = 'Sign in once using the QR code or recovery code, then create your passkey in Options.';
      $('recovery').open = true;
    } else $('passkeyHint').textContent = 'Confirm with your fingerprint, face or device unlock.';
  } catch(error) { $('passkeyHint').textContent = error.message; }
}
$('passkeyLogin').onclick = async () => {
  $('passkeyLogin').disabled = true; $('loginError').textContent = '';
  try { await Passkeys.login(api); await connect(); }
  catch(error) { $('loginError').textContent = Passkeys.message(error); }
  finally { $('passkeyLogin').disabled = false; }
};
async function refreshPasskeys() {
  if (!authConfig?.availableHere) {
    $('registrationHint').textContent = 'To create passkeys, open ' + (authConfig?.origin || 'the DNS name configured in the Mac app') + ' over trusted HTTPS.';
    return;
  }
  try {
    const result = await api('passkeys/list');
    $('passkeyList').replaceChildren(...result.keys.map(item => {
      const row = document.createElement('li');
      const text = document.createElement('span'); text.textContent = item.name;
      const button = document.createElement('button'); button.textContent = 'Revoke';
      button.onclick = async () => {
        if (!confirm('Revoke this passkey on this Mac?')) return;
        try { await api('passkeys/revoke', {id:item.id}); await refreshPasskeys(); }
        catch(error) { $('registrationHint').textContent = error.message; }
      };
      row.append(text,button); return row;
    }));
    $('registrationHint').textContent = 'Your password manager may sync this passkey across your devices. The private key stays in your password manager.';
  } catch(error) { $('registrationHint').textContent = error.message; }
}
$('registerPasskey').onclick = async () => {
  $('registerPasskey').disabled = true;
  try {
    await Passkeys.register(api, $('passkeyName').value.trim());
    await configureAuthentication(); await refreshPasskeys();
    $('registrationHint').textContent = 'Passkey created. You can now sign in without entering a code.';
  } catch(error) { $('registrationHint').textContent = Passkeys.message(error); }
  finally { $('registerPasskey').disabled = !authConfig?.availableHere || !Passkeys.available(); }
};

restoreAuthentication();
