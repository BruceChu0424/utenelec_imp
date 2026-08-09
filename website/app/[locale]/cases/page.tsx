import type { Metadata } from 'next';
import Image from 'next/image';
import { Building2, CalendarDays, MapPin } from 'lucide-react';
import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getCases } from '@/lib/queries';
import { isLegacyCompanyActivity, tr } from '@/lib/content';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Cases' });
  return buildPageMetadata({ locale, path: '/cases', title: t('title'), description: t('subtitle') });
}

export default async function CasesPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations('Cases');
  const tn = await getTranslations('News');
  const cases = await getCases();
  const projectCases = cases.filter((item) => !isLegacyCompanyActivity(item.slug));
  const activities = cases.filter((item) => isLegacyCompanyActivity(item.slug));
  const formatSequence = new Intl.NumberFormat(locale, { minimumIntegerDigits: 2, useGrouping: false });

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_auto]">
          <div>
            <span className="eyebrow">{t('eyebrow')}</span>
            <h1 className="page-title mt-7">{t('title')}</h1>
            <p className="prose-intro mt-5">{t('subtitle')}</p>
          </div>
          {projectCases.length > 0 && (
            <div className="flex min-w-40 items-center gap-4 border-y border-border py-4 lg:justify-end">
              <Building2 className="h-5 w-5 text-accent" />
              <div><p className="text-2xl font-bold tracking-[-.04em]">{formatSequence.format(projectCases.length)}</p><p className="text-xs uppercase tracking-[.14em] text-muted-foreground">{t('projectsLabel')}</p></div>
            </div>
          )}
        </div>
      </section>
      <div className="container-uten section-tight">
        {projectCases.length === 0 ? (
          <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-20 text-center text-muted-foreground">{t('empty')}</div>
        ) : (
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {projectCases.map((c, index) => {
              const ct = tr<{ title: string; location?: string; content?: string }>(c.i18n, locale);
              return (
                <article key={c.slug} className="card-uten group overflow-hidden">
                  <div className="relative aspect-[16/10] overflow-hidden bg-primary text-primary-foreground">
                    {c.coverImage ? (
                      <Image src={c.coverImage} alt={ct.title} fill sizes="(max-width: 768px) 100vw, 33vw" className="object-cover transition duration-500 group-hover:scale-[1.025]" />
                    ) : (
                      <>
                        <div className="absolute inset-0 bg-grid opacity-10" />
                        <div className="absolute -end-16 -top-16 h-48 w-48 rounded-full border border-primary-foreground/15" />
                        <div className="relative flex h-full flex-col justify-between p-6">
                          <p className="text-xs font-bold tracking-[.18em] text-accent-soft">{t('projectLabel', { number: formatSequence.format(index + 1) })}</p>
                          <div>
                            <Building2 className="h-7 w-7 text-primary-foreground/45" />
                            {ct.location && <p className="mt-3 text-sm text-primary-foreground/62">{ct.location}</p>}
                          </div>
                        </div>
                      </>
                    )}
                  </div>
                  <div className="p-6">
                    {ct.location && <p className="flex items-center gap-1.5 text-xs font-semibold text-accent"><MapPin className="h-3.5 w-3.5" />{ct.location}</p>}
                    <h2 className="mt-3 text-xl font-semibold leading-snug tracking-[-.025em]">{ct.title}</h2>
                    {ct.content && <p className="mt-3 line-clamp-3 text-sm leading-7 text-muted-foreground">{ct.content}</p>}
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </div>

      {activities.length > 0 && (
        <section className="border-t border-border bg-background-elevated/55">
          <div className="container-uten section-tight">
            <div className="mb-9 grid items-end gap-5 md:grid-cols-[1fr_auto]">
              <div><p className="eyebrow">{t('archiveEyebrow')}</p><h2 className="mt-4 text-3xl font-semibold tracking-[-.035em] md:text-5xl">{tn('company')}</h2></div>
              <p className="max-w-lg text-sm leading-7 text-muted-foreground">{t('archiveNote')}</p>
            </div>
            <div className="grid gap-5 md:grid-cols-2">
              {activities.map((item, index) => {
                const content = tr<{ title: string; location?: string; content?: string }>(item.i18n, locale);
                return (
                  <article key={item.slug} className="card-uten grid gap-6 p-6 sm:grid-cols-[56px_1fr] md:p-8">
                    <span className="grid h-14 w-14 place-items-center rounded-full bg-accent/10 text-accent"><CalendarDays className="h-5 w-5" /></span>
                    <div><p className="text-xs font-bold tracking-[.16em] text-accent">{t('archiveItemLabel', { number: formatSequence.format(index + 1) })}</p><h3 className="mt-3 text-xl font-semibold tracking-[-.02em]">{content.title}</h3>{content.location && <p className="mt-2 text-sm text-muted-foreground">{content.location}</p>}{content.content && <p className="mt-4 text-sm leading-7 text-muted-foreground">{content.content}</p>}</div>
                  </article>
                );
              })}
            </div>
          </div>
        </section>
      )}
    </>
  );
}
