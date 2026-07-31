import { NextResponse, type NextRequest } from 'next/server';
import createMiddleware from 'next-intl/middleware';
import { routing } from './i18n/routing';
import { jwtVerify } from 'jose';

const intl = createMiddleware(routing);
const COOKIE = 'uten_admin_session';

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  // 后台鉴权: 除登录页外都需要有效 session
  if (pathname === '/admin' || pathname.startsWith('/admin/')) {
    if (pathname === '/admin/login') return NextResponse.next();
    const token = req.cookies.get(COOKIE)?.value;
    const secret = new TextEncoder().encode(process.env.AUTH_SECRET);
    if (token) {
      try { await jwtVerify(token, secret); return NextResponse.next(); } catch { /* expired */ }
    }
    return NextResponse.redirect(new URL('/admin/login', req.url));
  }
  return intl(req);
}

export const config = {
  // 排除静态资源/api; admin 由上方自行鉴权, 其余走 next-intl 多语言
  matcher: ['/((?!api|_next|_vercel|.*\\..*).*)'],
};
