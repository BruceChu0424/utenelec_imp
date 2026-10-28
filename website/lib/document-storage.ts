import { createHash, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { access, mkdir, lstat, open, unlink, type FileHandle } from 'node:fs/promises';
import path from 'node:path';
import { PDFDocument, PDFDict, PDFName, PDFArray, PDFStream, PDFRef, type PDFObject } from 'pdf-lib';

export const MAX_DOCUMENT_BYTES = 20 * 1024 * 1024;
const keyPattern = /^[a-f0-9]{32}\.pdf$/;
export async function validatePublicPdf(bytes: Uint8Array) {
  if (!bytes.length || bytes.length > MAX_DOCUMENT_BYTES || Buffer.from(bytes.subarray(0, 5)).toString('ascii') !== '%PDF-') {
    throw new Error('请上传有效的 PDF，大小不超过 20 MB');
  }
  let document: PDFDocument; let pages: number;
  try { document = await PDFDocument.load(bytes, { ignoreEncryption: false, updateMetadata: false, throwOnInvalidObject: true }); pages = document.getPageCount(); }
  catch { throw new Error('PDF 无法读取或已加密，请上传可正常打开的文件'); }
  if (!pages || pages > 300) throw new Error('PDF 页数须在 1 至 300 页之间');
  const forbiddenKeys = new Set(['JS', 'JavaScript', 'AA', 'OpenAction', 'EmbeddedFiles', 'EF', 'XFA', 'RichMediaContent']);
  const visited = new Set<PDFObject>(); let count = 0;
  function inspect(object: PDFObject | undefined, depth: number) {
    if (!object || visited.has(object)) return;
    if (depth > 64 || ++count > 200_000) throw new Error('PDF 结构过于复杂，请导出静态版本后上传');
    visited.add(object);
    if (object instanceof PDFRef) { inspect(document.context.lookup(object), depth + 1); return; }
    if (object instanceof PDFArray) { for (const child of object.asArray()) inspect(child, depth + 1); return; }
    if (object instanceof PDFStream) { inspect(object.dict, depth + 1); return; }
    if (!(object instanceof PDFDict)) return;
    for (const key of object.keys()) if (forbiddenKeys.has(key.decodeText())) throw new Error('请移除 PDF 中的脚本、自动动作和嵌入附件后再上传');
    for (const key of ['S', 'Type', 'Subtype']) {
      const value = document.context.lookup(object.get(PDFName.of(key)));
      if (value instanceof PDFName && ['JavaScript', 'Launch', 'GoToE', 'SubmitForm', 'ImportData', 'EmbeddedFile', 'FileAttachment', 'RichMedia', 'Screen'].includes(value.decodeText())) {
        throw new Error('PDF 含交互动作或嵌入附件，不能作为公开产品资料上传');
      }
    }
    for (const [, child] of object.entries()) inspect(child, depth + 1);
  }
  for (const [, object] of document.context.enumerateIndirectObjects()) inspect(object, 0);
  return { pages, sha256: createHash('sha256').update(bytes).digest('hex') };
}
export async function documentDirectory(): Promise<string> {
  const configured = process.env.DOCUMENTS_DIR;
  const directory = configured || path.resolve(process.cwd(), '.local-state/documents');
  if (!path.isAbsolute(directory)) throw new Error('DOCUMENTS_DIR must be absolute');
  if (process.env.NODE_ENV === 'production') {
    if (directory !== '/var/lib/uten-website/runtime/documents') throw new Error('Production documents directory must use the approved durable mount');
  } else await mkdir(directory, { recursive: true, mode: 0o750 });
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Documents directory must be a real directory');
  return directory;
}
/** Readiness uses the same directory authority as upload and download. It
 * never creates a missing production mount or exposes a private file path. */
export async function assertDocumentsDirectoryReady(): Promise<void> {
  await access(await documentDirectory(), constants.R_OK | constants.W_OK | constants.X_OK);
}
export async function storeDocument(bytes: Uint8Array) {
  const validation = await validatePublicPdf(bytes);
  const directory = await documentDirectory();
  const storageKey = randomBytes(16).toString('hex') + '.pdf';
  const file = await open(path.join(directory, storageKey), 'wx', 0o640);
  try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
  return { storageKey, sha256: validation.sha256, sizeBytes: bytes.length, mimeType: 'application/pdf' };
}
export async function readDocument(storageKey: string, expectedHash: string, expectedSize: number) {
  const verified = await openVerifiedDocument(storageKey, expectedHash, expectedSize);
  try { return Buffer.from(await new Response(verified.stream).arrayBuffer()); }
  finally { await verified.close(); }
}

const DOCUMENT_READ_CHUNK = 64 * 1024;
const DOCUMENT_READ_DEADLINE_MS = 120_000;
let activeDocumentReads = 0;
export class DocumentDownloadBusy extends Error { }

/** Verify before headers, then retain one descriptor and at most one 64 KiB queued chunk.
 * Both passes hash the exact immutable object; cancellation releases the physical slot. */
export async function openVerifiedDocument(storageKey: string, expectedHash: string, expectedSize: number,
  options: { signal?: AbortSignal; verifyPublication?: (signal: AbortSignal) => Promise<void>; timeoutMs?: number } = {}) {
  if (!keyPattern.test(storageKey) || !/^[a-f0-9]{64}$/.test(expectedHash)
      || !Number.isSafeInteger(expectedSize) || expectedSize > MAX_DOCUMENT_BYTES || expectedSize <= 0) throw new Error('Invalid document identity');
  if (activeDocumentReads >= 2) throw new DocumentDownloadBusy('Document download capacity reached');
  activeDocumentReads++;

  const cancellation = new AbortController();
  const timeout = Math.min(DOCUMENT_READ_DEADLINE_MS, Math.max(1, options.timeoutMs ?? DOCUMENT_READ_DEADLINE_MS));
  const deadline = Date.now() + timeout;
  let file: FileHandle | undefined;
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  let streamEnded = false;
  const activePulls = new Set<Promise<void>>();
  let resolveReady!: (value: { stream: ReadableStream<Uint8Array>; close: () => Promise<void> }) => void;
  let rejectReady!: (failure: unknown) => void;
  const ready = new Promise<{ stream: ReadableStream<Uint8Array>; close: () => Promise<void> }>((resolve, reject) => {
    resolveReady = resolve; rejectReady = reject;
  });
  let finishStream!: () => void;
  const streamFinished = new Promise<void>(resolve => { finishStream = resolve; });
  const fail = (failure: unknown) => {
    rejectReady(failure);
    if (!streamEnded) { streamEnded = true; controller?.error(failure); }
    finishStream();
  };
  const interrupted = () => fail(new Error('Document download interrupted'));
  cancellation.signal.addEventListener('abort', interrupted, { once: true });
  const externalAbort = () => cancellation.abort();
  options.signal?.addEventListener('abort', externalAbort, { once: true });
  if (options.signal?.aborted) cancellation.abort();
  // Admission, metadata/open, both hash passes and publication waits share this
  // deadline. Caller cancellation never releases a still-running physical task.
  const timer = setTimeout(() => cancellation.abort(), timeout); timer.unref();
  const current = () => {
    if (Date.now() >= deadline && !cancellation.signal.aborted) cancellation.abort();
    if (cancellation.signal.aborted) throw new Error('Document download interrupted');
  };

  const lifetime: Promise<void> = (async () => {
    try {
      current();
      const name = path.join(await documentDirectory(), storageKey); current();
      const before = await lstat(name); current();
      if (!before.isFile() || before.isSymbolicLink() || before.size !== expectedSize) throw new Error('Document integrity failure');
      // Assign a late descriptor before observing cancellation, so the finally
      // block closes it exactly once even when open completed after the deadline.
      file = await open(name, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)); current();
      const identity = await file.stat(); current();
      if (!identity.isFile() || identity.size !== before.size || identity.ino !== before.ino || identity.dev !== before.dev)
        throw new Error('Document integrity failure');
      const unchanged = async () => {
        current();
        const stat = await file!.stat(); current();
        if (stat.size !== expectedSize || stat.ino !== identity.ino || stat.dev !== identity.dev
            || stat.mtimeMs !== identity.mtimeMs || stat.ctimeMs !== identity.ctimeMs) throw new Error('Document integrity failure');
      };
      const hash = createHash('sha256'); const buffer = Buffer.alloc(DOCUMENT_READ_CHUNK);
      let checked = 0;
      while (checked < expectedSize) {
        current();
        const { bytesRead } = await file.read(buffer, 0, Math.min(buffer.length, expectedSize - checked), checked); current();
        if (!bytesRead) throw new Error('Document integrity failure');
        hash.update(buffer.subarray(0, bytesRead)); checked += bytesRead;
      }
      if (hash.digest('hex') !== expectedHash) throw new Error('Document integrity failure');
      await unchanged(); await options.verifyPublication?.(cancellation.signal); current();
      let position = 0; let nextPublicationCheck = Date.now() + 1_000;
      const deliveredHash = createHash('sha256');
      const stream = new ReadableStream<Uint8Array>({
        start(value) { controller = value; },
        async pull(value) {
          const work = (async () => {
            await unchanged();
            if (Date.now() >= nextPublicationCheck) {
              await options.verifyPublication?.(cancellation.signal); current(); nextPublicationCheck = Date.now() + 1_000;
            }
            const chunk = Buffer.alloc(Math.min(DOCUMENT_READ_CHUNK, expectedSize - position));
            const { bytesRead } = await file!.read(chunk, 0, chunk.length, position); current();
            if (!bytesRead) throw new Error('Document integrity failure');
            position += bytesRead; deliveredHash.update(chunk.subarray(0, bytesRead));
            if (position === expectedSize) {
              await unchanged(); await options.verifyPublication?.(cancellation.signal); current();
              if (deliveredHash.digest('hex') !== expectedHash) throw new Error('Document integrity failure');
            }
            value.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, bytesRead));
            if (position === expectedSize) { streamEnded = true; value.close(); finishStream(); }
          })();
          activePulls.add(work);
          try { await work; } catch (failure) { fail(failure); }
          finally { activePulls.delete(work); }
        },
        async cancel() {
          streamEnded = true; cancellation.abort(); finishStream(); await lifetime;
        },
      }, { highWaterMark: 1 });
      current();
      resolveReady({ stream, close: () => { cancellation.abort(); finishStream(); return lifetime; } });
      await streamFinished;
    } catch (failure) { fail(failure); throw failure; }
    finally {
      // A publication promise or read cannot be abandoned and then replaced by
      // unlimited new work. Real publication queries have their own DB timeout.
      await Promise.allSettled([...activePulls]);
      try { await file?.close(); }
      finally {
        clearTimeout(timer); options.signal?.removeEventListener('abort', externalAbort);
        cancellation.signal.removeEventListener('abort', interrupted); activeDocumentReads--;
      }
    }
  })();
  // A canceled caller has already observed its rejection. Still observe late
  // failures from physical work and forward them to any live stream consumer.
  void lifetime.catch(fail);
  return ready;
}
/** Only used to remove a newly created, uncommitted file after DB failure. */
export async function discardUncommittedDocument(storageKey: string) {
  if (!keyPattern.test(storageKey)) throw new Error('Invalid document key');
  await unlink(path.join(await documentDirectory(), storageKey));
}
