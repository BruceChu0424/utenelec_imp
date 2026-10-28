import type { Metadata } from 'next';
import Image from 'next/image';
import { notFound } from 'next/navigation';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { ArrowLeft, ArrowUpRight, MapPin } from 'lucide-react';
import { ArticleContent } from '@/components/content/ArticleContent';
import { Link } from '@/i18n/navigation';
import { articleExcerpt, isLegacyCompanyActivity, pickLocale, tr } from '@/lib/content';
import { getCaseBySlug } from '@/lib/queries';
import { buildPageMetadata, directContentLocales, hasText } from '@/lib/seo';

type CaseContent = { title?: string; location?: string; content?: string };

export async function generateMetadata({ params }: { params: Promise<{ locale: string; slug: string }> }): Promise<Metadata> {
  const { locale, slug } = await params;
  const item = await getCaseBySlug(slug);
  if (!item) notFound();
  const direct = pickLocale<CaseContent>(item.i18n, locale);
  const fallback = tr<CaseContent>(item.i18n, locale);
  const availableLocales = directContentLocales<CaseContent>(item.i18n,
    content => hasText(content.title) && hasText(content.content));
  const localized = availableLocales.includes(locale);
  const title = direct?.title || fallback.title || item.slug;
  return buildPageMetadata({ locale, path: `/cases/${item.slug}`, title,
    description: localized ? articleExcerpt(undefined, direct?.content, title) : undefined,
    availableLocales, index: localized, image: item.coverImage });
}

export default async function CaseDetailPage({ params }: { params: Promise<{ locale: string; slug: string }> }) {
  const { locale, slug } = await params;
  setRequestLocale(locale);
  const [item, common, cases] = await Promise.all([
    getCaseBySlug(slug), getTranslations({ locale, namespace: 'Common' }),
    getTranslations({ locale, namespace: 'Cases' }),
  ]);
  if (!item) notFound();
  const content = tr<CaseContent>(item.i18n, locale);
  const title = content.title || item.slug;
  const historical = isLegacyCompanyActivity(item.slug);
  return <article className="public-article">
    <header className="page-hero"><div className="container-uten relative">
      <Link locale={locale} href="/cases" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-muted-foreground hover:text-accent"><ArrowLeft className="h-4 w-4 rtl:rotate-180" />{cases('title')}</Link>
      <p className="mt-7 text-sm text-muted-foreground">{historical ? cases('archiveEyebrow') : cases('projectsLabel')}</p>
      <h1 className="page-title mt-5 max-w-5xl text-balance max-sm:!text-[2.25rem]">{title}</h1>
      {content.location && <p className="mt-5 flex items-center gap-2 text-sm text-muted-foreground"><MapPin className="h-4 w-4 text-accent" />{content.location}</p>}
    </div></header>
    <div className="container-uten section-tight">
      {item.coverImage && <div className="media-stage relative mx-auto mb-10 aspect-[16/9] max-w-5xl md:mb-14"><Image src={item.coverImage} alt={title} fill priority sizes="(max-width:1100px) 100vw, 1100px" className="object-contain" /></div>}
      <div className="mx-auto max-w-3xl">
        {historical && <aside className="mb-9 border-s-2 border-accent bg-muted p-5 text-sm leading-7 text-muted-foreground">{cases('archiveNote')}</aside>}
        <ArticleContent text={content.content} title={title} emptyLabel={common('noData')} />
        <div className="public-actions mt-12 border-t border-border pt-7">
          <Link locale={locale} href="/contact" className="btn-primary">{common('contactUs')}<ArrowUpRight className="h-4 w-4" /></Link>
          <Link locale={locale} href="/cases" className="public-text-link">{common('back')}<ArrowLeft className="h-4 w-4 rtl:rotate-180" /></Link>
        </div>
      </div>
    </div>
  </article>;
}
