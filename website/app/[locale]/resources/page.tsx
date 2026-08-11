import type { Metadata } from 'next';
import { ArrowUpRight, BookOpen, ChevronDown, FileCheck2 } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { Reveal } from '@/components/motion/Reveal';
import { prisma } from '@/lib/db';
import { articleExcerpt, pickLocale, tr } from '@/lib/content';
import { publicNewsWhere } from '@/lib/publication';
import { getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

type ResourceSetting = Partial<{
  title: string;
  subtitle: string;
  intro: string;
  documentsBody: string;
  faqIntro: string;
}>;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const [t, raw] = await Promise.all([
    getTranslations({ locale, namespace: 'Resources' }),
    getSetting('resources'),
  ]);
  const custom = pickLocale<ResourceSetting>(raw, locale);
  return buildPageMetadata({ locale, path: '/resources', title: custom?.title || t('title'), description: custom?.subtitle || t('subtitle') });
}

export default async function ResourcesPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, common, newsT, rawSetting, guides] = await Promise.all([
    getTranslations({ locale, namespace: 'Resources' }),
    getTranslations({ locale, namespace: 'Common' }),
    getTranslations({ locale, namespace: 'News' }),
    getSetting('resources'),
    prisma.news.findMany({ where: publicNewsWhere({ category: 'guide' }), orderBy: { publishedAt: 'desc' }, take: 12 }),
  ]);
  const custom = pickLocale<ResourceSetting>(rawSetting, locale);
  const faqs = Array.from({ length: 6 }, (_, index) => ({ q: t(`faq${index + 1}q`), a: t(`faq${index + 1}a`) }));

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_.68fr] lg:gap-16">
          <div><p className="eyebrow">{t('eyebrow')}</p><h1 className="page-title mt-7 max-w-5xl">{custom?.title || t('title')}</h1></div>
          <p className="prose-intro border-s border-border ps-6 lg:ps-8">{custom?.subtitle || t('subtitle')}</p>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <Reveal><p className="eyebrow">{t('guidesEyebrow')}</p><h2 className="section-title mt-7 max-w-4xl">{t('guidesTitle')}</h2>{custom?.intro && <p className="mt-6 max-w-2xl text-pretty leading-8 text-muted-foreground">{custom.intro}</p>}</Reveal>
          {guides.length ? (
            <div className="mt-12 grid gap-4 md:grid-cols-2">
              {guides.map((guide, index) => {
                const content = tr<{ title?: string; summary?: string; content?: string }>(guide.i18n, locale);
                const direct = pickLocale<{ title?: string; content?: string }>(guide.i18n, locale);
                return (
                  <Reveal key={guide.id} delay={(index % 2) * 60} className="h-full">
                    <Link locale={locale} href={`/news/${guide.slug}`} className="card-uten group flex h-full min-h-64 flex-col p-6 transition hover:border-foreground/25 md:p-8">
                      <div className="flex items-center justify-between"><span className="grid h-12 w-12 place-items-center rounded-2xl bg-accent/10 text-accent"><BookOpen className="h-5 w-5" /></span><span className="text-xs font-bold uppercase tracking-[.14em] text-muted-foreground">{newsT('guide')}</span></div>
                      <h3 className="mt-10 text-balance text-2xl font-semibold leading-tight transition group-hover:text-accent">{content.title}</h3>
                      <p className="mt-4 line-clamp-3 text-sm leading-7 text-muted-foreground">{articleExcerpt(content.summary, content.content, content.title, 210)}</p>
                      {!direct?.content && locale !== 'en' && <p className="mt-4 text-xs leading-5 text-amber-700 dark:text-amber-300">{newsT('fallbackNote')}</p>}
                      <span className="mt-auto inline-flex min-h-11 items-center gap-2 pt-6 text-sm font-semibold">{common('readGuide')}<ArrowUpRight className="h-4 w-4 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5" /></span>
                    </Link>
                  </Reveal>
                );
              })}
            </div>
          ) : (
            <div className="mt-10 rounded-3xl border border-dashed border-border bg-card px-6 py-16 text-center text-muted-foreground">{newsT('empty')}</div>
          )}
        </div>
      </section>

      <section className="section border-y border-border bg-background-elevated/55">
        <div className="container-uten grid gap-10 lg:grid-cols-[.8fr_1.2fr] lg:items-center lg:gap-20">
          <Reveal><FileCheck2 className="h-7 w-7 text-accent" /><p className="eyebrow mt-8">{t('documentsEyebrow')}</p><h2 className="mt-6 text-balance text-3xl font-semibold tracking-[-.045em] md:text-5xl">{t('documentsTitle')}</h2></Reveal>
          <Reveal delay={100}><p className="text-base leading-8 text-muted-foreground md:text-lg">{custom?.documentsBody || t('documentsBody')}</p><p className="mt-5 rounded-2xl border border-border bg-card p-5 text-sm font-semibold leading-7">{t('documentsList')}</p><Link locale={locale} href="/partners#project-brief" className="btn-accent mt-7">{common('requestDocuments')}<ArrowUpRight className="h-4 w-4" /></Link></Reveal>
        </div>
      </section>

      <section className="section">
        <div className="container-uten grid gap-12 lg:grid-cols-[.65fr_1.35fr] lg:gap-20">
          <Reveal><p className="eyebrow">{t('faqEyebrow')}</p><h2 className="section-title mt-7">{t('faqTitle')}</h2>{custom?.faqIntro && <p className="mt-6 max-w-lg text-pretty leading-8 text-muted-foreground">{custom.faqIntro}</p>}</Reveal>
          <div className="divide-y divide-border border-y border-border">
            {faqs.map((faq, index) => (
              <details key={faq.q} className="group py-2">
                <summary className="flex min-h-16 cursor-pointer list-none items-center justify-between gap-5 py-3 font-semibold marker:hidden"><span><span className="me-4 text-xs tabular-nums text-muted-foreground">{String(index + 1).padStart(2, '0')}</span>{faq.q}</span><ChevronDown className="h-4 w-4 shrink-0 transition group-open:rotate-180" /></summary>
                <p className="max-w-3xl pb-6 ps-10 text-sm leading-7 text-muted-foreground md:text-base md:leading-8">{faq.a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>
    </>
  );
}
