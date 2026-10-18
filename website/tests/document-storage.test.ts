import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PDFDocument, PDFName, PDFString } from 'pdf-lib';
import { validatePublicPdf, storeDocument, readDocument, discardUncommittedDocument } from '../lib/document-storage';
let root: string;
before(async () => { root = await mkdtemp(path.join(os.tmpdir(), 'uten-document-test-')); process.env.DOCUMENTS_DIR = root; });
after(async () => {
  delete process.env.DOCUMENTS_DIR;
  assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
  assert.ok(path.basename(root).startsWith('uten-document-test-'));
  await rm(root, { recursive: true, force: true });
});
test('only parseable, unencrypted PDF files enter the immutable document store', async () => {
  const document = await PDFDocument.create(); document.addPage(); const bytes = await document.save();
  const validation = await validatePublicPdf(bytes); assert.equal(validation.pages, 1);
  const stored = await storeDocument(bytes);
  assert.deepEqual(new Uint8Array(await readDocument(stored.storageKey, stored.sha256, bytes.length)), bytes);
  await assert.rejects(readDocument('../outside.pdf', stored.sha256, bytes.length), /Invalid document identity/);
  await writeFile(path.join(root, stored.storageKey), Buffer.from('corrupted'));
  await assert.rejects(readDocument(stored.storageKey, stored.sha256, bytes.length), /integrity/);
  await discardUncommittedDocument(stored.storageKey);
  await assert.rejects(validatePublicPdf(Buffer.from('<html>not a PDF</html>')), /PDF/);
  await assert.rejects(validatePublicPdf(Buffer.from('%PDF-1.7 broken')), /PDF/);
});
test('PDF scripts and embedded automatic actions are rejected before persistence', async () => {
  const document = await PDFDocument.create(); document.addPage();
  document.catalog.set(PDFName.of('OpenAction'), document.context.obj({ S: 'JavaScript', JS: PDFString.of('alert(1)') }));
  await assert.rejects(validatePublicPdf(await document.save()), /脚本|交互/);
});
test('direct nested annotations and array-contained actions cannot bypass the public PDF guard', async () => {
  for (const action of ['Launch', 'JavaScript']) {
    const document = await PDFDocument.create(); const page = document.addPage();
    const annotation = document.context.obj({ Type: 'Annot', Subtype: 'Link', Rect: [0, 0, 10, 10],
      A: { S: action, ...(action === 'JavaScript' ? { JS: PDFString.of('void(0)') } : { F: PDFString.of('test-only.txt') }) } });
    page.node.set(PDFName.of('Annots'), document.context.obj([annotation]));
    await assert.rejects(validatePublicPdf(await document.save()), /脚本|交互/);
  }
});
