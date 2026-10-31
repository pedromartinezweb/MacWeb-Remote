'use strict';
const Passkeys = (() => {
  function decode(value) {
    const text = value.replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(text + '='.repeat((4 - text.length % 4) % 4)), c => c.charCodeAt(0));
  }
  function encode(value) {
    if (value == null) return null;
    return btoa(String.fromCharCode(...new Uint8Array(value))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  }
  function serialize(credential) {
    const response = credential.response;
    const result = {id: credential.id, rawId: encode(credential.rawId), type: credential.type, response: {clientDataJSON: encode(response.clientDataJSON)}};
    if (response.attestationObject) result.response.attestationObject = encode(response.attestationObject);
    if (response.authenticatorData) result.response.authenticatorData = encode(response.authenticatorData);
    if (response.signature) result.response.signature = encode(response.signature);
    if ('userHandle' in response) result.response.userHandle = encode(response.userHandle);
    return result;
  }
  function available() { return window.isSecureContext && typeof PublicKeyCredential !== 'undefined' && !!navigator.credentials; }
  async function register(api, name) {
    if (!available()) throw new Error('Open the configured DNS name over HTTPS with a trusted certificate.');
    const options = await api('passkeys/register/options', {name});
    const publicKey = options.publicKey;
    publicKey.challenge = decode(publicKey.challenge);
    publicKey.user.id = decode(publicKey.user.id);
    publicKey.excludeCredentials = (publicKey.excludeCredentials || []).map(item => ({...item, id: decode(item.id)}));
    const credential = await navigator.credentials.create({publicKey});
    if (!credential) throw new Error('No passkey was created.');
    return api('passkeys/register/finish', {requestID: options.requestID, credential: serialize(credential)});
  }
  async function login(api) {
    if (!available()) throw new Error('This connection requires trusted HTTPS and the configured DNS name.');
    const options = await api('passkeys/login/options', {});
    options.publicKey.challenge = decode(options.publicKey.challenge);
    if (options.publicKey.allowCredentials) options.publicKey.allowCredentials = options.publicKey.allowCredentials.map(item => ({...item, id: decode(item.id)}));
    const credential = await navigator.credentials.get({publicKey: options.publicKey});
    if (!credential) throw new Error('No passkey was selected.');
    return api('passkeys/login/finish', {requestID: options.requestID, credential: serialize(credential)});
  }
  function message(error) {
    return error.name === 'NotAllowedError' ? 'The operation was cancelled or timed out. Please try again.' : error.name === 'InvalidStateError' ? 'Your password manager already has a passkey for this Mac.' : error.message;
  }
  return {available, register, login, message};
})();
