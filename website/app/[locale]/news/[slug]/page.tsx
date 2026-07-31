import { setRequestLocale, getTranslations } from 'next-intl/server';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { Link } from '@/i18n/navigation';
import { ArrowLeft, Calendar } from 'lucide-react';
import { prisma } from '@/lib/db';
import { tr, formatDate } from '@/lib/content';

export async function generateStaticParams() {
  const news = await prisma.news.findMany({ select: { slug: true } });
  return news.map((n) => ({ slug: n.slug }));
}

export async function generateMetadata({ params }: { params: { locale: string; slug: string } }): Promise<Metadata> {
  const n = await prisma.news.findUnique({ where: { slug: params.slug } });
  if (!n) return {};
  return { title: tr<{ title: string }>(n.i18n, params.locale).title };
}

export default async function NewsDetailPage({ params }: { params: { locale: string; slug: string } }) {
  const { locale, slug } = params;
  setRequestLocale(locale);
  const tc = await getTranslations('Common');
  const news = await prisma.news.findUnique({ where: { slug } });
  if (!news) notFound();
  const nd = tr<{ title: string; content?: string }>(news.i18n, locale);
  const more = await prisma.news.findMany({ where: { published: true, NOT: { id: news.id } }, orderBy: { publishedAt: 'desc' }, take: 4 });

  return (
    <article className="container-uten py-12">
      <div className="mx-auto max-w-3xl">
        <Link href="/news" className="mb-6 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-accent">
          <ArrowLeft className="h-4 w-4" />{tc('back')}
        </Link>
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          <Calendar className="h-4 w-4 text-accent" />{formatDate(news.publishedAt, locale)}
        </p>
        <h1 className="mt-3 font-heading text-3xl font-bold leading-tight md:text-4xl">{nd.title}</h1>
        {nd.content ? (
          <div className="mt-8 whitespace-pre-line leading-loose text-foreground/90">{nd.content}</div>
        ) : (
          <p className="mt-8 text-muted-foreground">{tc('noData')}</p>
        )}
      </div>

      {more.length > 0 && (
        <section className="mx-auto mt-16 max-w-3xl border-t border-border pt-10">
          <h2 className="mb-5 text-lg font-bold">{tc('learnMore')}</h2>
          <div className="grid gap-4 sm:grid-cols-2">
            {more.map((n) => (
              <Link key={n.slug} href={`/news/${n.slug}`} className="card-uten block p-4 transition hover:shadow-md">
                <p className="text-xs text-muted-foreground">{formatDate(n.publishedAt, locale)}</p>
                <h3 className="mt-1 line-clamp-2 font-medium hover:text-accent">{tr<{ title: string }>(n.i18n, locale).title}</h3>
              </Link>
            ))}
          </div>
        </section>
      )}
    </article>
  );
}
