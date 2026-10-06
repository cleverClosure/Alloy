// Author: Timur Isaev
// Independent Node/OpenSSL oracle. Generates public-only vectors; no keys saved.
import { generateKeyPairSync, createHash, sign, verify, createPublicKey } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const path = fileURLToPath(new URL('Vectors/envelope.json', import.meta.url));
const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
};
const pae = (type, payload) => Buffer.concat([
  Buffer.from(`DSSEv1 ${Buffer.byteLength(type)} ${type} ${payload.length} `), payload,
]);
if (process.argv.includes('--generate')) {
  const source = '{"z":-0,"😀":[1e-7,1e21,"é"],"a":{"b":2,"a":1}}';
  const payload = Buffer.from(canonical(JSON.parse(source)));
  const payloadType = 'application/vnd.alloy.test-vector+json;version=1';
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  const keyId = 'sha256:' + createHash('sha256').update(raw).digest('hex');
  const preamble = pae(payloadType, payload);
  const envelope = { payloadType, payload: payload.toString('base64'), signatures: [
    { keyId, signature: sign(null, preamble, privateKey).toString('base64') },
  ] };
  writeFileSync(path, JSON.stringify({ label: 'TEST-ONLY public vector', source,
    canonical: payload.toString(), pae: preamble.toString('base64'),
    publicKey: raw.toString('base64'), envelope }, null, 2) + '\n');
}
const vector = JSON.parse(readFileSync(path));
const payload = Buffer.from(vector.envelope.payload, 'base64');
const message = pae(vector.envelope.payloadType, payload);
const publicKey = createPublicKey({ key: Buffer.concat([
  Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(vector.publicKey, 'base64'),
]), type: 'spki', format: 'der' });
if (canonical(JSON.parse(vector.source)) !== vector.canonical || message.toString('base64') !== vector.pae ||
    !verify(null, message, publicKey, Buffer.from(vector.envelope.signatures[0].signature, 'base64')) ||
    verify(null, Buffer.concat([message, Buffer.from('!')]), publicKey,
      Buffer.from(vector.envelope.signatures[0].signature, 'base64'))) throw Error('vector mismatch');
console.log('Independent Node/OpenSSL canonical + PAE + Ed25519 vector and tamper control PASS');
