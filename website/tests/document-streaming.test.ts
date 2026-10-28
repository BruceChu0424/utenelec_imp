import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { after, before, test, mock } from 'node:test';
import fsPromises from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { openVerifiedDocument, DocumentDownloadBusy, MAX_DOCUMENT_BYTES } from '../lib/document-storage';

let root: string;
const key = 'b1' + '0'.repeat(30) + '.pdf';
const bytes = Buffer.alloc(MAX_DOCUMENT_BYTES, 0x35);
const hash = createHash('sha256').update(bytes).digest('hex');
before(async () => {
  root = await mkdtemp(path.join(os.tmpdir(), 'uten-b1-document-'));
  process.env.DOCUMENTS_DIR = root;
  await writeFile(path.join(root, key), bytes);
});
after(async () => {
  delete process.env.DOCUMENTS_DIR;
  assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
  assert.ok(path.basename(root).startsWith('uten-b1-document-'));
  await rm(root, { recursive: true, force: true });
});
test('the maximum public original is verified and delivered in bounded exact chunks', async () => {
  let checks = 0;
  const document = await openVerifiedDocument(key, hash, bytes.length, { verifyPublication: async () => { checks++; } });
  const reader = document.stream.getReader(); const received = createHash('sha256');
  let count = 0; let maximum = 0;
  for (;;) {
    const next = await reader.read(); if (next.done) break;
    assert.ok(next.value.length > 0 && next.value.length <= 65_536);
    count += next.value.length; maximum = Math.max(maximum, next.value.length); received.update(next.value);
  }
  assert.equal(count, MAX_DOCUMENT_BYTES); assert.equal(maximum, 65_536); assert.equal(received.digest('hex'), hash);
  assert.ok(checks >= 2); await document.close();
});
test('slots survive no-consumer backpressure and are released by cancel, not by returning headers', async () => {
  const first = await openVerifiedDocument(key, hash, bytes.length);
  const second = await openVerifiedDocument(key, hash, bytes.length);
  await assert.rejects(openVerifiedDocument(key, hash, bytes.length), DocumentDownloadBusy);
  const reader = first.stream.getReader(); assert.equal((await reader.read()).value?.length, 65_536);
  await reader.cancel();
  const replacement = await openVerifiedDocument(key, hash, bytes.length);
  await replacement.stream.cancel(); await second.stream.cancel();
});
test('bad identity, hash and pre-publication withdrawal produce no body and release their slot', async () => {
  await assert.rejects(openVerifiedDocument('../outside.pdf', hash, bytes.length), /identity/);
  await assert.rejects(openVerifiedDocument(key, hash, MAX_DOCUMENT_BYTES + 1), /identity/);
  await assert.rejects(openVerifiedDocument(key, 'a'.repeat(64), bytes.length), /integrity/);
  await assert.rejects(openVerifiedDocument(key, hash, bytes.length, { verifyPublication: async () => { throw new Error('withdrawn'); } }), /withdrawn/);
  const valid = await openVerifiedDocument(key, hash, bytes.length); await valid.stream.cancel();
  assert.equal(createHash('sha256').update(await readFile(path.join(root, key))).digest('hex'), hash);
});
test('a withdrawal at completion prevents the declared full response from being published', async () => {
  let checks = 0;
  const document = await openVerifiedDocument(key, hash, bytes.length, { verifyPublication: async () => {
    if (++checks >= 2) throw new Error('withdrawn');
  } });
  await assert.rejects(new Response(document.stream).arrayBuffer(), /withdrawn/);
  const next = await openVerifiedDocument(key, hash, bytes.length); await next.stream.cancel();
});
test('abort and abandoned-reader timeout release descriptors and physical slots', async () => {
  const controller = new AbortController();
  const aborted = await openVerifiedDocument(key, hash, bytes.length, { signal: controller.signal });
  controller.abort();
  await assert.rejects(new Response(aborted.stream).arrayBuffer(), /interrupted/);
  const timed = await openVerifiedDocument(key, hash, bytes.length, { timeoutMs: 1_000 });
  await new Promise(resolve => setTimeout(resolve, 1_050));
  await assert.rejects(new Response(timed.stream).arrayBuffer(), /interrupted/);
  const next = await openVerifiedDocument(key, hash, bytes.length); await next.stream.cancel();
});

async function smallOriginal(tag: string) {
  const storageKey = tag + '0'.repeat(32 - tag.length) + '.pdf';
  // Keep a second chunk unread: a one-chunk body already reaches EOF during prefetch.
  const data = Buffer.alloc(128 * 1024, 0x31);
  await writeFile(path.join(root, storageKey), data);
  return { storageKey, sha256: createHash('sha256').update(data).digest('hex'), size: data.length };
}
async function exactPhysicalCapacity(original: Awaited<ReturnType<typeof smallOriginal>>) {
  const first = await openVerifiedDocument(original.storageKey, original.sha256, original.size);
  const second = await openVerifiedDocument(original.storageKey, original.sha256, original.size);
  try { await assert.rejects(openVerifiedDocument(original.storageKey, original.sha256, original.size), DocumentDownloadBusy); }
  finally { await first.stream.cancel(); await second.stream.cancel(); }
}

test('pre-header abort and deadline reject callers while holding at most two physical publication waits', { timeout: 5_000 }, async () => {
  const original = await smallOriginal('a1');
  const controller = new AbortController();
  const realOpen = fsPromises.open;
  let closes = 0, closeFinished!: () => void;
  const closed = new Promise<void>(resolve => { closeFinished = resolve; });
  const openHook = mock.method(fsPromises, 'open', async (...args: Parameters<typeof fsPromises.open>) => {
    const handle = await realOpen(...args);
    if (String(args[0]).endsWith(original.storageKey)) {
      const close = handle.close.bind(handle);
      mock.method(handle, 'close', async () => {
        try { await close(); } finally { if (++closes === 2) closeFinished(); }
      });
    }
    return handle;
  });
  syncBuiltinESMExports();
  let releaseFirst!: () => void, rejectSecond!: (error: Error) => void;
  let enterFirst!: () => void, enterSecond!: () => void;
  const firstEntered = new Promise<void>(resolve => { enterFirst = resolve; });
  const secondEntered = new Promise<void>(resolve => { enterSecond = resolve; });
  const firstGate = new Promise<void>(resolve => { releaseFirst = resolve; });
  const secondGate = new Promise<void>((_, reject) => { rejectSecond = reject; });
  const first = openVerifiedDocument(original.storageKey, original.sha256, original.size, {
    signal: controller.signal, verifyPublication: async () => { enterFirst(); await firstGate; },
  });
  const second = openVerifiedDocument(original.storageKey, original.sha256, original.size, {
    timeoutMs: 500, verifyPublication: async () => { enterSecond(); await secondGate; },
  });
  const callers = Promise.allSettled([first, second]);
  try {
    await Promise.all([firstEntered, secondEntered]); controller.abort();
    const outcomes = await Promise.race([callers, new Promise<'pending'>(resolve => setTimeout(() => resolve('pending'), 1_500))]);
    assert.notEqual(outcomes, 'pending', 'request cancellation must not await an uncooperative publication callback');
    assert.ok(Array.isArray(outcomes) && outcomes.every(result => result.status === 'rejected'));
    await assert.rejects(openVerifiedDocument(original.storageKey, original.sha256, original.size), DocumentDownloadBusy,
      'physical waits keep their admission reservation until they really drain');
  } finally {
    releaseFirst(); rejectSecond(new Error('late expected publication rejection'));
    await callers; await closed;
    openHook.mock.restore(); syncBuiltinESMExports();
    await new Promise<void>(resolve => setImmediate(resolve));
  }
  assert.equal(closes, 2);
  await exactPhysicalCapacity(original);
});

test('late open handles close exactly once after pre-header cancellation and late rejection is observed', { timeout: 5_000 }, async () => {
  const firstOriginal = await smallOriginal('a2'), secondOriginal = await smallOriginal('a3');
  const controller = new AbortController();
  const realOpen = fsPromises.open;
  let releaseOpen!: () => void, rejectOpen!: (error: Error) => void;
  let firstEntered!: () => void, secondEntered!: () => void, closed!: () => void;
  const enteredFirst = new Promise<void>(resolve => { firstEntered = resolve; });
  const enteredSecond = new Promise<void>(resolve => { secondEntered = resolve; });
  const openGate = new Promise<void>(resolve => { releaseOpen = resolve; });
  const rejectedOpen = new Promise<never>((_, reject) => { rejectOpen = reject; });
  const closeObserved = new Promise<void>(resolve => { closed = resolve; });
  let closes = 0, reads = 0;
  const hook = mock.method(fsPromises, 'open', async (...args: Parameters<typeof fsPromises.open>) => {
    const filename = String(args[0]);
    if (filename.endsWith(secondOriginal.storageKey)) { secondEntered(); await rejectedOpen; }
    if (filename.endsWith(firstOriginal.storageKey)) {
      firstEntered(); await openGate;
      const handle = await realOpen(...args);
      const close = handle.close.bind(handle);
      mock.method(handle, 'read', async () => { reads++; throw new Error('canceled late handle must not be read'); });
      mock.method(handle, 'close', async () => { closes++; try { await close(); } finally { closed(); } });
      return handle;
    }
    return realOpen(...args);
  });
  syncBuiltinESMExports();
  const first = openVerifiedDocument(firstOriginal.storageKey, firstOriginal.sha256, firstOriginal.size, { signal: controller.signal });
  const second = openVerifiedDocument(secondOriginal.storageKey, secondOriginal.sha256, secondOriginal.size, { timeoutMs: 500 });
  const callers = Promise.allSettled([first, second]);
  try {
    await Promise.all([enteredFirst, enteredSecond]); controller.abort();
    const outcomes = await Promise.race([callers, new Promise<'pending'>(resolve => setTimeout(() => resolve('pending'), 1_500))]);
    assert.notEqual(outcomes, 'pending');
    assert.ok(Array.isArray(outcomes) && outcomes.every(result => result.status === 'rejected'));
    await assert.rejects(openVerifiedDocument(key, hash, bytes.length), DocumentDownloadBusy);
  } finally {
    releaseOpen(); rejectOpen(new Error('late expected open rejection'));
    await callers; await closeObserved;
    hook.mock.restore(); syncBuiltinESMExports();
    await new Promise<void>(resolve => setImmediate(resolve));
  }
  assert.equal(closes, 1); assert.equal(reads, 0);
  await exactPhysicalCapacity(firstOriginal);
});
