import { prisma } from '@/lib/db';
import { publicResourceWhere } from '@/lib/resources';
import { readDocument } from '@/lib/document-storage';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(id)) return new Response('Not found', { status: 404 });
  const resource = await prisma.resourceDocument.findFirst({ where: { id, ...publicResourceWhere() }, include: { asset: true } });
  if (!resource) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
  try {
    const bytes = await readDocument(resource.asset.storageKey, resource.asset.sha256, resource.asset.sizeBytes);
    const name = resource.asset.originalName.replace(/[\r\n/\\]/g, '_');
    return new Response(new Uint8Array(bytes), { headers: {
      'Content-Type': 'application/pdf', 'X-Content-Type-Options': 'nosniff',
      'Content-Disposition': `attachment; filename="product-document.pdf"; filename*=UTF-8''${encodeURIComponent(name)}`,
      'Content-Length': String(bytes.length), 'Cache-Control': 'public, max-age=0, must-revalidate',
    } });
  } catch { return new Response('Document temporarily unavailable', { status: 503, headers: { 'Cache-Control': 'no-store' } }); }
}
