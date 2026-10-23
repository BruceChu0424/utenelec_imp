'use strict';
// Candidate-only stdin/stdout bridge. Returns ciphertext and booleans, never plaintext or keys.
const crypto = require('node:crypto');
const fs = require('node:fs');
const aad = (issuer, id) => Buffer.from(`uten|${issuer}|ai_providers|secret|${id}|vh1`, 'utf8');
const derive = secret => Buffer.from(crypto.hkdfSync('sha256', Buffer.from(secret, 'utf8'),
  Buffer.from('uten-secret-cipher'), Buffer.from('ai-credentials-v1'), 32));
function open(stored, issuer, id, key) {
  if (!stored.startsWith('gh1:')) throw new Error('UNSUPPORTED_CIPHER');
  const bytes = Buffer.from(stored.slice(4), 'base64url');
  if (bytes.length < 28) throw new Error('INVALID_CIPHER');
  const cipher = crypto.createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
  cipher.setAAD(aad(issuer, id)); cipher.setAuthTag(bytes.subarray(-16));
  return Buffer.concat([cipher.update(bytes.subarray(12, -16)), cipher.final()]);
}
function seal(plain, issuer, id, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(aad(issuer, id));
  const value = Buffer.concat([iv, cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
  return 'gh1:' + value.toString('base64url');
}
function candidate(input) {
  if (!input || typeof input.currentHmac !== 'string' || Buffer.byteLength(input.currentHmac) < 32
      || typeof input.legacyHmac !== 'string' || !input.legacyHmac
      || typeof input.currentIssuer !== 'string' || typeof input.legacyIssuer !== 'string'
      || !Array.isArray(input.rows) || input.rows.length > 100) throw new Error('INVALID_INPUT');
  const current = derive(input.currentHmac), legacy = derive(input.legacyHmac);
  try {
    return input.rows.map(row => {
      if (!/^[a-f0-9-]{36}$/.test(row.id) || typeof row.secret !== 'string' || row.secret.length > 16384)
        throw new Error('INVALID_ROW');
      let plain, old;
      try { plain = open(row.secret, input.currentIssuer, row.id, current); old = false; }
      catch { plain = open(row.secret, input.legacyIssuer, row.id, legacy); old = true; }
      try {
        if (!plain.length) throw new Error('EMPTY_SECRET');
        const text=plain.toString('utf8');
        const normalized=text.toLowerCase().replace(/[-_\s]/g,'');
        const notKnownPlaceholder=!/(replace|changeme|placeholder|yourpassword|yoursecret|yourkey|example|dummy|\$\{)/.test(normalized)
          && !(normalized.includes('<') && normalized.includes('>')) && !/^sk-test(?:-|$)/i.test(text);
        const last4Matches=row.last4===undefined ? null : row.last4===(text.length>=20 ? text.slice(-4) : null);
        const replacement = old ? seal(plain, input.currentIssuer, row.id, current) : row.secret;
        const checked = open(replacement, input.currentIssuer, row.id, current);
        const equal = crypto.timingSafeEqual(plain, checked); checked.fill(0);
        if (!equal) throw new Error('CIPHER_ROUNDTRIP_FAILED');
        return {id: row.id, oldCipherSha256: crypto.createHash('sha256').update(row.secret).digest('hex'),
          newCipher: replacement, changed: old, plaintextPreserved: true,
          currentIssuerVerified: true, version: row.version,notKnownPlaceholder,last4Matches};
      } finally { plain.fill(0); }
    });
  } finally { current.fill(0); legacy.fill(0); }
}
if (require.main === module) {
  try {
    const raw = fs.readFileSync(0);
    if (raw.length > 2 * 1024 * 1024) throw new Error('INPUT_TOO_LARGE');
    const rows = candidate(JSON.parse(raw.toString('utf8')));
    process.stdout.write(JSON.stringify({state: 'CIPHER_CANDIDATE_VERIFIED', rows}));
    raw.fill(0);
  } catch {
    process.stderr.write('{"state":"CIPHER_CANDIDATE_FAILED"}\n');process.exitCode=1;
  }
}
module.exports = {candidate, derive, open, seal};
