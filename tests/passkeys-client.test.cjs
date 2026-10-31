const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function client(credentials, secure = true) {
  const context = vm.createContext({window: {isSecureContext: secure}, PublicKeyCredential: function(){}, navigator: {credentials}, Uint8Array, atob, btoa});
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../Web/passkeys.js'), 'utf8') + ';globalThis.client = Passkeys;', context);
  return context.client;
}
const buffer = (...bytes) => Uint8Array.from(bytes).buffer;

test('registration decodes options and serializes only public credential data', async () => {
  let options, finished;
  const auth = client({create: async value => {
    options = value.publicKey;
    return {id: 'AQID', rawId: buffer(1,2,3), type: 'public-key', response: {clientDataJSON: buffer(0,255), attestationObject: buffer(4,5,6)}};
  }});
  const api = async (route, body) => {
    if (route.endsWith('/options')) return {requestID: 'ticket', publicKey: {challenge:'AAH_', user:{id:'AAEC'}, excludeCredentials:[{type:'public-key',id:'AQID'}], authenticatorSelection:{residentKey:'required',userVerification:'required'}}};
    assert.equal(route, 'passkeys/register/finish'); finished = body; return {ok:true};
  };
  await auth.register(api, 'My key');
  assert.deepEqual(Array.from(options.challenge), [0,1,255]);
  assert.deepEqual(Array.from(options.user.id), [0,1,2]);
  assert.deepEqual(Array.from(options.excludeCredentials[0].id), [1,2,3]);
  assert.equal(options.authenticatorSelection.userVerification, 'required');
  assert.equal(finished.requestID, 'ticket');
  assert.equal(finished.credential.response.clientDataJSON, 'AP8');
  assert.equal(finished.credential.response.attestationObject, 'BAUG');
  assert.equal(Object.hasOwn(finished.credential, 'privateKey'), false);
});

test('authentication serializes signature, authenticator data and user handle', async () => {
  let finished;
  const auth = client({get: async ({publicKey}) => {
    assert.deepEqual(Array.from(publicKey.challenge), [0,1,255]);
    return {id:'AQID',rawId:buffer(1,2,3),type:'public-key',response:{clientDataJSON:buffer(1),authenticatorData:buffer(2),signature:buffer(3),userHandle:buffer(4)}};
  }});
  await auth.login(async (route, body) => {
    if (route.endsWith('/options')) return {requestID:'ticket',publicKey:{challenge:'AAH_',rpId:'desktop.example.net',userVerification:'required'}};
    finished = body; return {ok:true};
  });
  assert.equal(finished.credential.response.signature, 'Aw');
  assert.equal(finished.credential.response.authenticatorData, 'Ag');
  assert.equal(finished.credential.response.userHandle, 'BA');
});

test('insecure context cannot start a WebAuthn ceremony', async () => {
  let called = false;
  const auth = client({}, false);
  await assert.rejects(auth.login(async () => {called = true;}), /HTTPS/);
  assert.equal(called, false);
});

test('cancellation and duplicate credentials produce actionable messages', () => {
  const auth = client({});
  assert.match(auth.message({name:'NotAllowedError'}), /cancelled/);
  assert.match(auth.message({name:'InvalidStateError'}), /already has/);
});
