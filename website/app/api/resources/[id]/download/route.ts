import type { Prisma } from '@prisma/client';
import { prisma } from '@/lib/db';
import { publicResourceWhere } from '@/lib/resources';
import { openVerifiedDocument, DocumentDownloadBusy } from '@/lib/document-storage';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const PUBLIC_DOCUMENT_SQL_TIMEOUT_MS = 2_000;
const PUBLIC_DOCUMENT_TRANSACTION_MS = 3_000;
const PUBLIC_DOCUMENT_POOL_WAIT_MS = 1_000;

/** The storage permit remains owned until publication work physically settles.
 * Bound both queued transactions and PostgreSQL statements, so canceling an HTTP
 * caller cannot accumulate unbounded queries or permanently strand its slot. */
async function publicationRead<T>(read: (tx: Prisma.TransactionClient) => Promise<T>, signal?: AbortSignal): Promise<T> {
  const current = () => { if (signal?.aborted) throw new Error('Document download interrupted'); };
  current();
  return prisma.$transaction(async tx => {
    current();
    if (process.env.DATABASE_URL?.startsWith('postgres')) {
      await tx.$queryRaw`SELECT set_config('statement_timeout', ${String(PUBLIC_DOCUMENT_SQL_TIMEOUT_MS) + 'ms'}, true)`;
      current();
    }
    const result = await read(tx); current(); return result;
  }, { maxWait: PUBLIC_DOCUMENT_POOL_WAIT_MS, timeout: PUBLIC_DOCUMENT_TRANSACTION_MS });
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(id)) return new Response('Not found', { status: 404 });
  let verified: Awaited<ReturnType<typeof openVerifiedDocument>> | undefined;
  try {
    const resource = await publicationRead(tx => tx.resourceDocument.findFirst({
      where: { id, ...publicResourceWhere() }, include: { asset: true },
    }), request.signal);
    if (!resource) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
    verified = await openVerifiedDocument(resource.asset.storageKey, resource.asset.sha256, resource.asset.sizeBytes, {
      signal: request.signal,
      verifyPublication: async signal => {
        const current = await publicationRead(tx => tx.resourceDocument.findFirst({
          where: { id, ...publicResourceWhere() }, select: { assetId: true },
        }), signal);
        if (!current || current.assetId !== resource.assetId) throw new Error('Document publication changed');
      },
    });
    const name = resource.asset.originalName.replace(/[\r\n/\\]/g, '_');
    return new Response(verified.stream, { headers: {
      'Content-Type': 'application/pdf', 'X-Content-Type-Options': 'nosniff',
      'Content-Disposition': `attachment; filename="product-document.pdf"; filename*=UTF-8''${encodeURIComponent(name)}`,
      'Content-Length': String(resource.asset.sizeBytes), 'Cache-Control': 'public, max-age=0, must-revalidate',
    } });
  } catch (failure) { await verified?.close(); return new Response('Document temporarily unavailable', { status: 503,
    headers: { 'Cache-Control': 'no-store', ...(failure instanceof DocumentDownloadBusy ? { 'Retry-After': '2' } : {}) } }); }
}
