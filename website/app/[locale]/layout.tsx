import { NextIntlClientProvider } from 'next-intl';
import { getMessages, getTranslations, setRequestLocale } from 'next-intl/server';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { routing } from '@/i18n/routing';
import '@/app/globals.css';
import { SiteHeader } from '@/components/layout/SiteHeader';
import { SiteFooter } from '@/components/layout/SiteFooter';
import { getSeries, getSetting } from '@/lib/queries';
import { pick } from '@/lib/content';
import { themeInitScript } from '@/components/ThemeToggle';

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
  params,
}: {
  params: { locale: string };
}): Promise<Metadata> {
  const { locale } = params;
  const t = await getTranslations({ locale, namespace: 'Meta' });
  return {
    title: { default: `${t('company')}`, template: `%s | ${t('company')}` },
    description: t('tagline'),
    keywords: ['墙壁开关', '插座', '优腾', 'wall switch', 'socket', 'Uten', 'electrical'],
    icons: { icon: '/favicon.ico' },
    openGraph: { title: t('company'), description: t('tagline'), type: 'website' },
  };
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: { locale: string };
}) {
  const { locale } = params;
  if (!routing.locales.includes(locale as never)) notFound();
  setRequestLocale(locale);

  const messages = await getMessages();
  const series = await getSeries();
  const seriesLite = series.map((s) => ({
    code: s.code,
    name: pick<{ name: string }>(s.i18n, locale)?.name || s.code,
  }));
  const contact = pick<Record<string, string>>(await getSetting('contact'), locale) || {};

  return (
    <html lang={locale} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Lexend:wght@400;500;600;700&family=Source+Sans+3:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <NextIntlClientProvider messages={messages}>
          <SiteHeader series={seriesLite} />
          <main className="min-h-[60vh]">{children}</main>
          <SiteFooter series={seriesLite} contact={contact} />
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
