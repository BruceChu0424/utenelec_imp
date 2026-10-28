import { createHash, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { access, mkdir, lstat, open, readFile, unlink } from 'node:fs/promises';
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
  if (!keyPattern.test(storageKey) || expectedSize > MAX_DOCUMENT_BYTES || expectedSize <= 0) throw new Error('Invalid document identity');
  const file = path.join(await documentDirectory(), storageKey);
  const stat = await lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== expectedSize) throw new Error('Document integrity failure');
  const bytes = await readFile(file);
  if (createHash('sha256').update(bytes).digest('hex') !== expectedHash) throw new Error('Document integrity failure');
  return bytes;
}
/** Only used to remove a newly created, uncommitted file after DB failure. */
export async function discardUncommittedDocument(storageKey: string) {
  if (!keyPattern.test(storageKey)) throw new Error('Invalid document key');
  await unlink(path.join(await documentDirectory(), storageKey));
}
