import { permanentRedirect } from 'next/navigation';

/** Preserve the legacy partnership URL while keeping one international
 * cooperation experience and one structured project brief. */
export default async function LegacyJoinPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  permanentRedirect(`/${locale}/partners`);
}
