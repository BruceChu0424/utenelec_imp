import { resolveLegacyDestination } from '@/lib/legacy-routes';

export const dynamic = 'force-dynamic';

export async function GET(request: Request, { params }: { params: Promise<{ legacyLocale: string; legacyFile: string }> }) {
  const { legacyLocale, legacyFile } = await params;
  const target = await resolveLegacyDestination(legacyLocale, legacyFile, new URL(request.url).searchParams);
  if (!target) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' } });
  return new Response(null, { status: 308, headers: { Location: target, 'Cache-Control': 'no-store' } });
}
