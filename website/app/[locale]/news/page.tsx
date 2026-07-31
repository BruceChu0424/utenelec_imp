import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { getNewsList } from '@/lib/queries';
import { tr, formatDate } from '@/lib/content';

export default async function NewsPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('News');
  const news = await getNewsList();
  const [feat, ...rest] = news;

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-20">
        <div className="ambient-blob" style={{ width: 380, height: 380, background: 'hsl(174 100% 40%)', top: '-40%', right: '5%' }} />
        <div className="container-uten relative">
          <span className="eyebrow">News</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{t('title')}</span></h1>
          <p className="mt-3 text-muted-foreground">{t('subtitle')}</p>
        </div>
      </section>

      <div className="container-uten py-12">
        {news.length === 0 ? (
          <p className="py-20 text-center text-muted-foreground">{t('empty')}</p>
        ) : (
          <div className="grid gap-10 lg:grid-cols-3">
            {feat && (
              <div className="lg:col-span-2">
                <Link href={`/news/${feat.slug}`} className="card-uten group block overflow-hidden">
                  <div className="grid h-56 place-items-center bg-primary text-primary-foreground">
                    <span className="font-heading text-5xl font-bold opacity-30">{(tr<{ title: string }>(feat.i18n, locale).title || 'U')[0]}</span>
                  </div>
                  <div className="p-6">
                    <p className="text-xs text-accent">{formatDate(feat.publishedAt, locale)}</p>
                    <h2 className="mt-2 font-heading text-2xl font-bold transition group-hover:text-accent">{tr<{ title: string }>(feat.i18n, locale).title}</h2>
                    {tr<{ summary?: string }>(feat.i18n, locale).summary && <p className="mt-2 line-clamp-2 text-muted-foreground">{tr<{ summary?: string }>(feat.i18n, locale).summary}</p>}
                  </div>
                </Link>
              </div>
            )}
            <div className="space-y-5">
              {rest.slice(0, 6).map((n) => (
                <Link key={n.slug} href={`/news/${n.slug}`} className="card-uten block p-4 transition hover:shadow-md">
                  <p className="text-xs text-accent">{formatDate(n.publishedAt, locale)}</p>
                  <h3 className="mt-1 line-clamp-2 font-medium transition hover:text-accent">{tr<{ title: string }>(n.i18n, locale).title}</h3>
                </Link>
              ))}
            </div>
          </div>
        )}
      </div>
    </>
  );
}
