import type { Metadata } from 'next';
import { headers } from 'next/headers';
import { NextIntlClientProvider } from 'next-intl';
import { getMessages, getTranslations, setRequestLocale } from 'next-intl/server';
import PublicNotFound from '@/components/layout/PublicNotFound';
import { routing } from '@/i18n/routing';
import { PUBLIC_ROUTE_LOCALE_HEADER } from '@/lib/public-route-context';
import '@/app/globals.css';

export const dynamic = 'force-dynamic';

async function requestLocale() {
  const candidate = (await headers()).get(PUBLIC_ROUTE_LOCALE_HEADER);
  return candidate && routing.locales.includes(candidate as (typeof routing.locales)[number])
    ? candidate as (typeof routing.locales)[number] : routing.defaultLocale;
}

export async function generateMetadata(): Promise<Metadata> {
  const locale = await requestLocale();
  const t = await getTranslations({ locale, namespace: 'NotFound' });
  return { title: `${t('title')} | UTEN`, robots: { index: false, follow: true } };
}

/** Root-layout rejection has no parent document or Intl provider. Reuse the
 * same branded content while supplying the required request-bound shell. */
export default async function GlobalNotFound() {
  const locale = await requestLocale();
  setRequestLocale(locale);
  const messages = await getMessages({ locale });
  return <html lang={locale} dir={locale === 'ar' ? 'rtl' : 'ltr'}>
    <body className="public-site min-h-screen">
      <NextIntlClientProvider locale={locale} messages={{ NotFound: messages.NotFound, Common: messages.Common, Nav: messages.Nav }}>
        <PublicNotFound />
      </NextIntlClientProvider>
    </body>
  </html>;
}
