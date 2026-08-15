import type { Metadata } from 'next';
import { NextIntlClientProvider } from 'next-intl';
import { getMessages, getTranslations, setRequestLocale } from 'next-intl/server';
import { notFound } from 'next/navigation';
import '@/app/globals.css';
import { SiteFooter } from '@/components/layout/SiteFooter';
import { SiteHeader } from '@/components/layout/SiteHeader';
import { routing } from '@/i18n/routing';
import { toCatalogFamily } from '@/lib/catalog';
import { pick } from '@/lib/content';
import { getCatalogFamilies, getSetting } from '@/lib/queries';
import { getSiteUrl } from '@/lib/seo';

const RTL_LOCALES = new Set(['ar']);

// Public catalogue and CMS content live in the persistent production SQLite
// database and uploaded media is published independently of code releases.
// Render this subtree at request time so a new CMS record/path is never baked
// from CI's disposable database or held until the next code deployment.
export const dynamic = 'force-dynamic';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Meta' });
  return {
    metadataBase: getSiteUrl(),
    title: { default: t('company'), template: `%s | ${t('company')}` },
    description: t('tagline'),
    applicationName: t('company'),
    openGraph: { title: t('company'), description: t('tagline'), type: 'website', locale, siteName: t('company') },
    robots: { index: true, follow: true },
  };
}

export default async function LocaleLayout({ children, params }: { children: React.ReactNode; params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!routing.locales.includes(locale as never)) notFound();
  setRequestLocale(locale);

  const [messages, familyRecords, contactRaw, footerRaw, common] = await Promise.all([
    getMessages({ locale }),
    getCatalogFamilies(),
    getSetting('contact'),
    getSetting('footer'),
    getTranslations({ locale, namespace: 'Common' }),
  ]);
  const seriesLite = familyRecords.map((record) => {
    const family = toCatalogFamily(record, locale);
    return {
      code: family.slug,
      name: family.name,
    };
  });
  const contact = pick<Record<string, string>>(contactRaw, locale) || {};
  const footer = pick<Record<string, string>>(footerRaw, locale) || {};

  return (
    <html lang={locale} dir={RTL_LOCALES.has(locale) ? 'rtl' : 'ltr'}>
      <body>
        <NextIntlClientProvider locale={locale} messages={messages}>
          <a href="#main-content" className="sr-only z-[200] rounded-lg bg-primary px-4 py-3 text-primary-foreground focus:not-sr-only focus:fixed focus:start-4 focus:top-4">{common('skipContent')}</a>
          <SiteHeader locale={locale} series={seriesLite} />
          <main id="main-content" className="min-h-[60vh]">{children}</main>
          <SiteFooter locale={locale} series={seriesLite} contact={contact} content={footer} />
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
