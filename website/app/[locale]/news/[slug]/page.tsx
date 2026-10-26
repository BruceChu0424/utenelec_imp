import { setRequestLocale, getTranslations } from 'next-intl/server';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { Link } from '@/i18n/navigation';
import Image from 'next/image';
import { ArrowLeft, ArrowUpRight, CalendarDays } from 'lucide-react';
import { prisma } from '@/lib/db';
import { articleExcerpt, pickLocale, tr, formatDate } from '@/lib/content';
import { getDirectNewsContent } from '@/lib/news-content';
import { ArticleContent } from '@/components/content/ArticleContent';
import { publicNewsWhere } from '@/lib/publication';
import { getNewsBySlug } from '@/lib/queries';
import { buildPageMetadata, directContentLocales, hasText } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string; slug: string }> }): Promise<Metadata> {
  const { locale, slug } = await params;
  const n = await getNewsBySlug(slug);
  if (!n) return { robots: { index: false, follow: false } };
  const direct = pickLocale<{ title?: string; summary?: string; content?: string }>(n.i18n, locale);
  const fallback = tr<{ title?: string; summary?: string; content?: string }>(n.i18n, locale);
  const availableLocales = directContentLocales<{ title?: string; content?: string }>(
    n.i18n,
    (content) => hasText(content.title) && hasText(content.content),
  );
  const isLocalized = availableLocales.includes(locale);
  const title = direct?.title || fallback.title || n.slug;
  return buildPageMetadata({
    locale,
    path: `/news/${slug}`,
    title,
    description: isLocalized ? articleExcerpt(direct?.summary, direct?.content, title) : undefined,
    availableLocales,
    index: isLocalized,
    image: n.coverImage,
  });
}

export default async function NewsDetailPage({ params }: { params: Promise<{ locale: string; slug: string }> }) {
  const { locale, slug } = await params;
  setRequestLocale(locale);
  const tc = await getTranslations({ locale, namespace: 'Common' });
  const news = await getNewsBySlug(slug);
  if (!news) notFound();
  const nd = tr<{ title: string; summary?: string; content?: string }>(news.i18n, locale);
  const hasCleanSummary = Boolean(nd.summary && !/中文\s*\|\s*ENGLISH|联系我们\s*人才招聘|COMPANY NEWS/i.test(nd.summary));
  const more = (await prisma.news.findMany({
    where: publicNewsWhere({ NOT: { id: news.id } }),
    orderBy: { publishedAt: 'desc' },
    take: 24,
  }))
    .filter((item) => locale === 'zh' || getDirectNewsContent(item.i18n, locale))
    .slice(0, 4);

  return (
    <article className="public-article">
      <header className="page-hero">
        <div className="container-uten relative">
          <Link locale={locale} href="/news" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-muted-foreground transition hover:text-accent">
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" />{tc('back')}
          </Link>
          <p className="mt-7 flex items-center gap-2 text-xs font-semibold uppercase tracking-[.14em] text-muted-foreground">
            <CalendarDays className="h-4 w-4 text-accent" />{formatDate(news.publishedAt, locale)}
          </p>
          <h1 className="page-title mt-5 max-w-5xl text-balance max-sm:!text-[2.25rem]">{nd.title}</h1>
          {hasCleanSummary && articleExcerpt(nd.summary, nd.content, nd.title) && (
            <p className="prose-intro mt-6">{articleExcerpt(nd.summary, nd.content, nd.title)}</p>
          )}
        </div>
      </header>

      <div className="container-uten section-tight">
        {news.coverImage && (
          <div className="media-stage relative mx-auto mb-10 aspect-[16/8] max-w-5xl md:mb-14">
            <Image src={news.coverImage} alt={nd.title} fill priority sizes="(max-width: 1100px) 100vw, 1100px" className="object-cover" />
          </div>
        )}
        <div className="mx-auto max-w-3xl">
          <ArticleContent text={nd.content} title={nd.title} emptyLabel={tc('noData')} />
        </div>
      </div>

      {more.length > 0 && (
        <section className="border-t border-border bg-background-elevated/55">
          <div className="container-uten section-tight">
          <div className="mb-7 flex items-end justify-between gap-4">
            <h2 className="text-2xl font-semibold tracking-[-.03em] md:text-3xl">{tc('learnMore')}</h2>
            <Link locale={locale} href="/news" className="btn-ghost">{tc('viewAll')}<ArrowUpRight className="h-4 w-4" /></Link>
          </div>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {more.map((n) => {
              const localized = getDirectNewsContent(n.i18n, locale) ?? tr<{ title: string }>(n.i18n, locale);
              return (
                <Link locale={locale} key={n.slug} href={`/news/${n.slug}`} className="card-uten group block p-5 transition hover:border-foreground/25">
                  <p className="text-xs text-muted-foreground">{formatDate(n.publishedAt, locale)}</p>
                  <h3 className="mt-3 line-clamp-3 font-semibold leading-6 transition group-hover:text-accent">{localized.title}</h3>
                </Link>
              );
            })}
          </div>
          </div>
        </section>
      )}
    </article>
  );
}
