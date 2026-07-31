import { Link } from '@/i18n/navigation';
import { tr, formatDate } from '@/lib/content';

type News = { slug: string; coverImage: string | null; publishedAt: Date; i18n: string | null };

export function NewsCard({ news, locale, compact = false }: { news: News; locale: string; compact?: boolean }) {
  const t = tr<{ title: string; summary?: string }>(news.i18n, locale);
  return (
    <Link href={`/news/${news.slug}`} className="group flex gap-4">
      {!compact && (
        <div className="aspect-square h-20 w-20 shrink-0 overflow-hidden rounded-lg bg-muted">
          {news.coverImage ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={news.coverImage} alt={t.title} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-105" />
          ) : (
            <div className="grid h-full place-items-center bg-primary text-xs font-bold text-primary-foreground">UTEN</div>
          )}
        </div>
      )}
      <div className="min-w-0 flex-1">
        <p className="mb-1 text-xs text-muted-foreground">{formatDate(news.publishedAt, locale)}</p>
        <h3 className={`font-medium leading-snug transition group-hover:text-accent ${compact ? 'text-sm' : 'line-clamp-2'}`}>{t.title}</h3>
        {!compact && t.summary && <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">{t.summary}</p>}
      </div>
    </Link>
  );
}
