import type { Metadata } from 'next';
import Image from 'next/image';
import { ArrowUpRight, CalendarDays } from 'lucide-react';
import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { getNewsList } from '@/lib/queries';
import { articleExcerpt, tr, formatDate } from '@/lib/content';
import { getDirectNewsContent } from '@/lib/news-content';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'News' });
  return buildPageMetadata({ locale, path: '/news', title: t('title'), description: t('subtitle') });
}

export default async function NewsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations('News');
  const allNews = await getNewsList();
  const news = allNews.filter((item) => locale === 'zh' || getDirectNewsContent(item.i18n, locale));
  const localizedContent = (i18n: string) =>
    getDirectNewsContent(i18n, locale) ?? tr<{ title: string; summary?: string; content?: string }>(i18n, locale);
  const [feat, ...rest] = news;
  const featContent = feat ? localizedContent(feat.i18n) : null;
  const categoryLabel = (category: string) => {
    if (category === 'guide') return t('guide');
    if (category === 'industry') return t('industry');
    return t('company');
  };

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative">
          <span className="eyebrow">UTEN NEWSROOM</span>
          <h1 className="page-title mt-7">{t('title')}</h1>
          <p className="prose-intro mt-5">{t('subtitle')}</p>
        </div>
      </section>

      <div className="container-uten section-tight">
        {news.length === 0 ? (
          <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-20 text-center text-muted-foreground">{t('empty')}</div>
        ) : (
          <div className="grid gap-6 lg:grid-cols-[1.35fr_.65fr] lg:gap-8">
            {feat && featContent && (
              <Link href={`/news/${feat.slug}`} className="card-uten group block overflow-hidden">
                {feat.coverImage ? (
                  <div className="relative aspect-[16/8] overflow-hidden">
                    <Image src={feat.coverImage} alt={featContent.title} fill priority sizes="(max-width: 1024px) 100vw, 66vw" className="object-cover transition duration-500 group-hover:scale-[1.02]" />
                    <div className="absolute inset-0 bg-gradient-to-t from-foreground/50 via-transparent to-transparent" />
                  </div>
                ) : (
                  <div className="panel-dark relative min-h-[280px] overflow-hidden p-7 md:min-h-[340px] md:p-10">
                    <div className="absolute inset-0 bg-grid opacity-10" />
                    <div className="absolute -end-20 -top-20 h-72 w-72 rounded-full border border-primary-foreground/15" />
                    <div className="relative flex min-h-[224px] flex-col justify-between md:min-h-[260px]">
                      <p className="text-xs font-bold uppercase tracking-[.18em] text-accent-soft">{categoryLabel(feat.category)}</p>
                      <h2 className="max-w-3xl text-balance text-3xl font-semibold leading-[1.15] tracking-[-.035em] md:text-5xl">{featContent.title}</h2>
                    </div>
                  </div>
                )}
                <div className="p-6 md:p-8">
                  <div className="flex flex-wrap items-center gap-4 text-xs font-semibold text-muted-foreground">
                    <span className="text-accent">{categoryLabel(feat.category)}</span>
                    <span className="inline-flex items-center gap-1.5"><CalendarDays className="h-3.5 w-3.5" />{formatDate(feat.publishedAt, locale)}</span>
                  </div>
                  {feat.coverImage && <h2 className="mt-4 text-2xl font-semibold leading-snug tracking-[-.025em] transition group-hover:text-accent md:text-3xl">{featContent.title}</h2>}
                  {articleExcerpt(featContent.summary, featContent.content, featContent.title) && (
                    <p className="mt-3 line-clamp-3 text-sm leading-7 text-muted-foreground md:text-base">
                      {articleExcerpt(featContent.summary, featContent.content, featContent.title)}
                    </p>
                  )}
                  <span className="mt-5 inline-flex min-h-11 items-center gap-2 text-sm font-semibold">{t('latest')}<ArrowUpRight className="h-4 w-4 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5" /></span>
                </div>
              </Link>
            )}
            <div className="flex flex-col gap-3">
              {rest.slice(0, 8).map((n, index) => {
                const content = localizedContent(n.i18n);
                return (
                  <Link key={n.slug} href={`/news/${n.slug}`} className="card-uten group flex flex-1 flex-col justify-between p-5">
                    <div>
                      <div className="flex items-center justify-between gap-3 text-[11px] font-semibold uppercase tracking-[.1em] text-muted-foreground">
                        <span>{categoryLabel(n.category)}</span><span>{String(index + 2).padStart(2, '0')}</span>
                      </div>
                      <h3 className="mt-4 line-clamp-3 font-semibold leading-6 transition group-hover:text-accent">{content.title}</h3>
                    </div>
                    <p className="mt-5 text-xs text-muted-foreground">{formatDate(n.publishedAt, locale)}</p>
                  </Link>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </>
  );
}
