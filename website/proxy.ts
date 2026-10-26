import { NextResponse, NextRequest } from 'next/server';
import createMiddleware from 'next-intl/middleware';
import { routing } from './i18n/routing';
import { jwtVerify } from 'jose';
import { requireStrongAuthSecret } from './lib/auth-secret';
import { caseSlugForPathname, publicLocaleForPathname, PUBLIC_CASE_SLUG_HEADER, PUBLIC_ROUTE_LOCALE_HEADER } from './lib/public-route-context';

const intl = createMiddleware(routing);
const COOKIE = 'uten_admin_session';

export async function proxy(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const requestHeaders = new Headers(req.headers);
  requestHeaders.delete(PUBLIC_CASE_SLUG_HEADER);
  requestHeaders.delete(PUBLIC_ROUTE_LOCALE_HEADER);
  requestHeaders.set(PUBLIC_ROUTE_LOCALE_HEADER, publicLocaleForPathname(pathname));
  const caseSlug = caseSlugForPathname(pathname);
  // 后台鉴权: 除登录页外都需要有效 session
  if (pathname === '/admin' || pathname.startsWith('/admin/')) {
    if (pathname === '/admin/login' || pathname === '/admin/imp-entry') return NextResponse.next({ request: { headers: requestHeaders } });
    const token = req.cookies.get(COOKIE)?.value;
    const secret = new TextEncoder().encode(requireStrongAuthSecret(process.env.AUTH_SECRET));
    if (token) {
      try {
        await jwtVerify(token, secret, {
          algorithms: ['HS256'],
          issuer: 'uten-admin',
          audience: 'uten-admin-cms',
        });
        return NextResponse.next({ request: { headers: requestHeaders } });
      } catch { /* expired, malformed, or legacy token */ }
    }
    return NextResponse.redirect(new URL('/admin/login', req.url));
  }
  if (caseSlug !== null) {
    const { getCaseBySlug } = await import('./lib/queries');
    if (!caseSlug || !await getCaseBySlug(caseSlug)) {
      // With localePrefix=always, '/' has no app/page and is genuinely
      // unmatched after this internal rewrite. The global 404 owns its full
      // document; the original URL stays in the browser. Page rechecks remain.
      return NextResponse.rewrite(new URL('/', req.url), {
        request: { headers: requestHeaders },
        headers: { 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex' },
      });
    }
  }
  return intl(new NextRequest(req, { headers: requestHeaders }));
}

export const config = {
  // 排除静态资源/api; admin 由上方自行鉴权, 其余走 next-intl 多语言
  // Keep locale context for dotted page paths too. Static public assets have no
  // locale prefix; this literal mirrors routing.locales (checked by tests).
  matcher: ['/((?!api|_next|_vercel|.*\\..*).*)', '/:locale(zh|en|es|fr|de|pt|ar|ru|ja|ko)/:path*'],
};
