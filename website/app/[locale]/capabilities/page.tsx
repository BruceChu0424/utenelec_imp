import type { Metadata } from 'next';
import Image from 'next/image';
import {
  ArrowUpRight,
  ClipboardCheck,
  Factory,
  FileCheck2,
  FlaskConical,
  Layers3,
  PackageCheck,
} from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { Reveal } from '@/components/motion/Reveal';
import { pickLocale } from '@/lib/content';
import { getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

const ARCHIVE_IMAGES = [
  '/uploads/legacy-v2/b8/b89b1a4acfcd35398326d0c596bbc4912adb53f9c170bc172a3eef1d5f245e3f.jpg',
  '/images/raw/Edt-fuc-hqlf_ce22gl_hqlf_.._.._.._Upload_PicFiles_image_20170911_20170911142510881088.jpg',
  '/images/raw/Edt-fuc-hqlf_ce22gl_hqlf_.._.._.._Upload_PicFiles_image_20170911_20170911142552875287.jpg',
];

type CapabilitySetting = {
  title?: string;
  subtitle?: string;
  intro?: string;
  qualityBody?: string;
  oemBody?: string;
  documentsBody?: string;
};

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Capabilities' });
  const custom = pickLocale<CapabilitySetting>(await getSetting('capabilities'), locale);
  return buildPageMetadata({
    locale,
    path: '/capabilities',
    title: custom?.title || t('title'),
    description: custom?.subtitle || t('subtitle'),
  });
}

export default async function CapabilitiesPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, common, customRaw] = await Promise.all([
    getTranslations({ locale, namespace: 'Capabilities' }),
    getTranslations({ locale, namespace: 'Common' }),
    getSetting('capabilities'),
  ]);
  const custom = pickLocale<CapabilitySetting>(customRaw, locale) || {};
  const formatSequence = new Intl.NumberFormat(locale, { minimumIntegerDigits: 2, useGrouping: false });
  const capabilities = [
    { icon: Layers3, title: t('developmentTitle'), body: t('developmentBody') },
    { icon: Factory, title: t('manufacturingTitle'), body: custom.oemBody || t('manufacturingBody') },
    { icon: FlaskConical, title: t('qualityTitle'), body: custom.qualityBody || t('qualityBody') },
    { icon: FileCheck2, title: t('documentsTitle'), body: custom.documentsBody || t('documentsBody') },
  ];
  const steps = Array.from({ length: 5 }, (_, index) => ({
    title: t(`step${index + 1}Title`),
    body: t(`step${index + 1}Body`),
  }));

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_.7fr] lg:gap-16">
          <div>
            <p className="eyebrow">{t('eyebrow')}</p>
            <h1 className="page-title mt-7 max-w-5xl">{custom.title || t('title')}</h1>
          </div>
          <p className="prose-intro border-s border-border ps-6 lg:ps-8">{custom.subtitle || t('subtitle')}</p>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <div className="grid gap-12 lg:grid-cols-[.72fr_1.28fr] lg:gap-20">
            <Reveal>
              <p className="eyebrow">{t('introEyebrow')}</p>
              <h2 className="mt-6 text-balance text-3xl font-semibold leading-[1.08] tracking-[-.045em] md:text-5xl">{t('introTitle')}</h2>
              <p className="mt-6 text-pretty leading-8 text-muted-foreground">{custom.intro || t('introBody')}</p>
              <Link locale={locale} href="/partners" className="btn-outline mt-8">{common('startProject')}<ArrowUpRight className="h-4 w-4" /></Link>
            </Reveal>
            <div className="grid gap-px overflow-hidden rounded-[1.5rem] border border-border bg-border sm:grid-cols-2">
              {capabilities.map((item, index) => (
                <Reveal key={item.title} delay={index * 60} className="h-full">
                  <article className="h-full bg-card p-6 md:p-8">
                    <div className="flex items-center justify-between">
                      <span className="grid h-12 w-12 place-items-center rounded-2xl bg-accent/10 text-accent"><item.icon className="h-5 w-5" /></span>
                      <span className="text-xs font-bold tracking-[.15em] text-muted-foreground">{formatSequence.format(index + 1)}</span>
                    </div>
                    <h3 className="mt-10 text-xl font-semibold">{item.title}</h3>
                    <p className="mt-4 text-sm leading-7 text-muted-foreground">{item.body}</p>
                  </article>
                </Reveal>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="section border-y border-border bg-background-elevated/55">
        <div className="container-uten">
          <div className="grid gap-10 lg:grid-cols-[1.15fr_.85fr] lg:items-end">
            <Reveal className="grid grid-cols-2 gap-3">
              <div className="media-stage relative col-span-2 aspect-[8/3]">
                <Image src={ARCHIVE_IMAGES[0]} alt={t('archiveCaption')} fill sizes="(max-width:1024px) 100vw, 58vw" className="object-cover" />
              </div>
              {ARCHIVE_IMAGES.slice(1).map((image) => (
                <div key={image} className="media-stage relative aspect-[4/3]">
                  <Image src={image} alt={t('archiveCaption')} fill sizes="(max-width:1024px) 50vw, 29vw" className="object-cover" />
                </div>
              ))}
            </Reveal>
            <Reveal delay={100}>
              <p className="eyebrow">{t('evidenceEyebrow')}</p>
              <h2 className="mt-6 text-balance text-3xl font-semibold leading-[1.08] tracking-[-.04em] md:text-5xl">{t('qualityTitle')}</h2>
              <p className="mt-6 leading-8 text-muted-foreground">{custom.qualityBody || t('qualityBody')}</p>
              <div className="mt-6 rounded-2xl border border-amber-500/30 bg-amber-500/8 p-5 text-sm leading-7 text-foreground/78">
                <ClipboardCheck className="mb-3 h-5 w-5 text-amber-700 dark:text-amber-300" />
                {t('evidenceNote')}
              </div>
            </Reveal>
          </div>
        </div>
      </section>

      <section className="section panel-dark">
        <div className="container-uten">
          <Reveal className="max-w-4xl">
            <p className="text-[11px] font-bold uppercase tracking-[.22em] text-accent-soft">{t('workflowEyebrow')}</p>
            <h2 className="section-title mt-7">{t('workflowTitle')}</h2>
          </Reveal>
          <div className="mt-12 grid gap-3 md:grid-cols-5">
            {steps.map((step, index) => (
              <Reveal key={step.title} delay={index * 55} className="h-full">
                <article className="h-full rounded-[1.25rem] border border-primary-foreground/15 bg-primary-foreground/[.04] p-5">
                  <span className="text-xs font-bold tracking-[.14em] text-accent-soft">{t('stepLabel', { number: formatSequence.format(index + 1) })}</span>
                  <h3 className="mt-10 font-semibold">{step.title}</h3>
                  <p className="mt-3 text-sm leading-6 text-primary-foreground/58">{step.body}</p>
                </article>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <div className="grid gap-8 rounded-[1.75rem] border border-border bg-card p-7 md:p-10 lg:grid-cols-[1fr_auto] lg:items-end">
            <div>
              <PackageCheck className="h-6 w-6 text-accent" />
              <h2 className="mt-6 max-w-4xl text-balance text-3xl font-semibold tracking-[-.045em] md:text-5xl">{t('ctaTitle')}</h2>
              <p className="mt-5 max-w-2xl leading-8 text-muted-foreground">{t('ctaBody')}</p>
            </div>
            <div className="flex flex-wrap gap-3">
              <Link locale={locale} href="/resources" className="btn-outline">{common('requestDocuments')}</Link>
              <Link locale={locale} href="/partners" className="btn-accent">{common('startProject')}<ArrowUpRight className="h-4 w-4" /></Link>
            </div>
          </div>
        </div>
      </section>
    </>
  );
}
