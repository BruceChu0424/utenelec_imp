import { NextRequest, NextResponse } from 'next/server';
import { routing } from '@/i18n/routing';
import { isProductFunctionType } from '@/lib/product-taxonomy';
import { queryCatalogProducts } from '@/lib/queries';

export const dynamic = 'force-dynamic';

const PAGE_SIZE = 24;

function parseGang(value: string | null): number | null {
  if (!value) return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= 12 ? parsed : null;
}

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const requestedLocale = searchParams.get('locale') || routing.defaultLocale;
  const locale = (routing.locales as readonly string[]).includes(requestedLocale)
    ? requestedLocale
    : routing.defaultLocale;
  const familyIdentifier = (searchParams.get('series') || '').trim().slice(0, 80);
  const query = (searchParams.get('q') || '').trim().slice(0, 80);
  const requestedFunction = searchParams.get('function');
  const functionType = isProductFunctionType(requestedFunction) ? requestedFunction : null;
  const gangCount = parseGang(searchParams.get('gang'));
  const offsetValue = Number.parseInt(searchParams.get('offset') || '0', 10);
  const offset = Number.isFinite(offsetValue) ? Math.min(5000, Math.max(0, offsetValue)) : 0;

  if (!familyIdentifier) {
    return NextResponse.json(
      { products: [], total: 0, facets: { functions: [], gangs: [] }, error: 'series_required' },
      { status: 400 },
    );
  }

  const result = await queryCatalogProducts({
    locale,
    familyIdentifier,
    query,
    functionType,
    gangCount,
    offset,
    take: PAGE_SIZE,
  });
  if (!result) {
    return NextResponse.json(
      { products: [], total: 0, facets: { functions: [], gangs: [] }, error: 'series_not_found' },
      { status: 404 },
    );
  }

  const response = NextResponse.json(result);
  response.headers.set('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=900');
  return response;
}
