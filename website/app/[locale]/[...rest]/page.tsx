import { notFound } from 'next/navigation';
import { setRequestLocale } from 'next-intl/server';

// Keep the localized 404 in the current request context. Caching this shell
// can retain another locale's not-found UI and navigation.
export const dynamic = 'force-dynamic';

export default async function LocaleCatchAll({ params }: { params: Promise<{ locale: string; rest: string[] }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  notFound();
}
