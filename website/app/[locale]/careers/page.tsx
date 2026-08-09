import type { Metadata } from 'next';
import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getJobs, getSetting } from '@/lib/queries';
import { tr, pick } from '@/lib/content';
import { Link } from '@/i18n/navigation';
import { ArrowUpRight, BriefcaseBusiness, Building2, Mail, MapPin } from 'lucide-react';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const [t, meta] = await Promise.all([
    getTranslations({ locale, namespace: 'Careers' }),
    getTranslations({ locale, namespace: 'Meta' }),
  ]);
  return buildPageMetadata({ locale, path: '/careers', title: t('title'), description: meta('tagline') });
}

export default async function CareersPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations('Careers');
  const tc = await getTranslations('Common');
  const [metaRaw, contactRaw, jobs] = await Promise.all([getSetting('careers'), getSetting('contact'), getJobs()]);
  const meta = pick<{ title?: string; subtitle?: string; body?: string }>(metaRaw, locale) || {};
  const contact = pick<{ email?: string }>(contactRaw, locale) || {};
  const formatSequence = new Intl.NumberFormat(locale, { minimumIntegerDigits: 2, useGrouping: false });

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_.68fr] lg:gap-16">
          <div>
            <span className="eyebrow">{t('eyebrow')}</span>
            <h1 className="page-title mt-7">{meta.title || t('title')}</h1>
            {meta.subtitle && <p className="prose-intro mt-5">{meta.subtitle}</p>}
          </div>
          {meta.body && (
            <div className="border-s border-border ps-6 lg:ps-8">
              <Building2 className="h-5 w-5 text-accent" />
              <p className="mt-4 text-pretty text-sm leading-7 text-muted-foreground md:text-base md:leading-8">{meta.body}</p>
            </div>
          )}
        </div>
      </section>

      <section className="section-tight">
        <div className="container-uten">
          <div className="mb-9 flex flex-wrap items-end justify-between gap-5 border-b border-border pb-6">
            <div><p className="eyebrow">{t('openPositions')}</p><h2 className="mt-4 text-3xl font-semibold tracking-[-.035em] md:text-4xl">{t('title')}</h2></div>
            <p className="text-sm text-muted-foreground">{jobs.length ? t('positionsCount', { count: formatSequence.format(jobs.length) }) : t('empty')}</p>
          </div>
        {jobs.length === 0 ? (
          <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-20 text-center text-muted-foreground">{t('empty')}</div>
        ) : (
          <div className="grid gap-5 lg:grid-cols-2">
            {jobs.map((j, index) => {
              const jd = tr<{ title: string; requirements?: string; description?: string }>(j.i18n, locale);
              return (
                <article key={j.slug} className="card-uten flex h-full flex-col p-6 md:p-8">
                  <div className="flex flex-wrap items-start justify-between gap-5">
                    <div>
                      <p className="text-xs font-bold tracking-[.16em] text-accent">{t('positionLabel', { number: formatSequence.format(index + 1) })}</p>
                      <h3 className="mt-4 text-2xl font-semibold tracking-[-.025em]">{jd.title}</h3>
                      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-2 text-sm text-muted-foreground">
                        {j.department && <span className="inline-flex items-center gap-1.5"><BriefcaseBusiness className="h-4 w-4" />{j.department}</span>}
                        {j.location && <span className="inline-flex items-center gap-1.5"><MapPin className="h-4 w-4" />{j.location}</span>}
                      </div>
                    </div>
                  </div>
                  {jd.description && <div className="mt-6 border-t border-border pt-5"><p className="text-xs font-semibold uppercase tracking-[.12em] text-muted-foreground">{t('desc')}</p><p className="mt-2 text-sm leading-7 text-muted-foreground">{jd.description}</p></div>}
                  {jd.requirements && (
                    <div className="mt-5">
                      <p className="mb-2 text-xs font-semibold uppercase tracking-wider text-accent">{t('requirements')}</p>
                      <p className="whitespace-pre-line text-sm leading-7 text-muted-foreground">{jd.requirements}</p>
                    </div>
                  )}
                  <Link href="/contact" className="btn-outline mt-7 self-start">{tc('contactUs')}<ArrowUpRight className="h-4 w-4" /></Link>
                </article>
              );
            })}
          </div>
        )}
        </div>
      </section>

      <section className="border-t border-border bg-background-elevated/55">
        <div className="container-uten section-tight">
          <div className="panel-dark relative overflow-hidden rounded-[1.75rem] p-8 md:p-12">
            <div className="absolute inset-0 bg-grid opacity-10" />
            <div className="relative grid items-center gap-8 md:grid-cols-[1fr_auto]">
              <div><Mail className="h-6 w-6 text-accent-soft" /><h2 className="mt-5 max-w-2xl text-balance text-2xl font-semibold leading-tight md:text-4xl">{meta.subtitle || t('title')}</h2>{meta.body && <p className="mt-4 max-w-2xl text-sm leading-7 text-primary-foreground/65">{meta.body}</p>}</div>
              {contact.email ? <a href={`mailto:${contact.email}`} className="btn-accent">{contact.email}<ArrowUpRight className="h-4 w-4" /></a> : <Link href="/contact" className="btn-accent">{tc('contactUs')}<ArrowUpRight className="h-4 w-4" /></Link>}
            </div>
          </div>
        </div>
      </section>
    </>
  );
}
