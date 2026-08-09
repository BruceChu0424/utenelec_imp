import type { Metadata } from 'next';
import { ArrowDownRight, Building2, Check, Handshake, Palette, Store, Wrench } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { InquiryForm } from '@/components/InquiryForm';
import { Reveal } from '@/components/motion/Reveal';
import { pickLocale } from '@/lib/content';
import { getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

type PartnerSetting = { title?: string; subtitle?: string; intro?: string; processBody?: string; cta?: string };

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Partners' });
  const custom = pickLocale<PartnerSetting>(await getSetting('partners'), locale);
  return buildPageMetadata({ locale, path: '/partners', title: custom?.title || t('title'), description: custom?.subtitle || t('subtitle') });
}

export default async function PartnersPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, customRaw] = await Promise.all([
    getTranslations({ locale, namespace: 'Partners' }),
    getSetting('partners'),
  ]);
  const custom = pickLocale<PartnerSetting>(customRaw, locale) || {};
  const models = [
    { icon: Store, title: t('distributionTitle'), body: t('distributionBody') },
    { icon: Building2, title: t('projectTitle'), body: t('projectBody') },
    { icon: Wrench, title: t('oemTitle'), body: t('oemBody') },
    { icon: Palette, title: t('designTitle'), body: t('designBody') },
  ];
  const briefItems = ['briefMarket', 'briefStandard', 'briefProduct', 'briefQuantity', 'briefSchedule', 'briefDocuments'].map((key) => t(key));
  const steps = Array.from({ length: 5 }, (_, index) => t(`step${index + 1}`));

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_.7fr] lg:gap-16">
          <div>
            <p className="eyebrow">{t('eyebrow')}</p>
            <h1 className="page-title mt-7 max-w-5xl">{custom.title || t('title')}</h1>
          </div>
          <div className="border-s border-border ps-6 lg:ps-8">
            <p className="prose-intro">{custom.subtitle || t('subtitle')}</p>
            <a href="#project-brief" className="mt-6 inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-accent">{custom.cta || t('formTitle')}<ArrowDownRight className="h-4 w-4" /></a>
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <Reveal>
            <p className="eyebrow">{t('modelsEyebrow')}</p>
            <h2 className="section-title mt-7 max-w-4xl">{t('modelsTitle')}</h2>
          </Reveal>
          <div className="mt-12 grid gap-4 md:grid-cols-2">
            {models.map((model, index) => (
              <Reveal key={model.title} delay={(index % 2) * 70} className="h-full">
                <article className="card-uten h-full p-6 md:p-8">
                  <div className="flex items-center justify-between"><span className="grid h-12 w-12 place-items-center rounded-2xl bg-accent/10 text-accent"><model.icon className="h-5 w-5" /></span><span className="text-xs font-bold text-muted-foreground">0{index + 1}</span></div>
                  <h3 className="mt-10 text-2xl font-semibold">{model.title}</h3>
                  <p className="mt-4 max-w-xl leading-8 text-muted-foreground">{model.body}</p>
                </article>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      <section className="section border-y border-border bg-background-elevated/55">
        <div className="container-uten grid gap-12 lg:grid-cols-[.78fr_1.22fr] lg:gap-20">
          <Reveal>
            <p className="eyebrow">{t('briefEyebrow')}</p>
            <h2 className="mt-7 text-balance text-3xl font-semibold leading-[1.08] tracking-[-.045em] md:text-5xl">{t('briefTitle')}</h2>
            <p className="mt-6 leading-8 text-muted-foreground">{custom.intro || t('briefBody')}</p>
          </Reveal>
          <Reveal delay={100}>
            <ul className="grid gap-3 sm:grid-cols-2">
              {briefItems.map((item) => <li key={item} className="flex min-h-20 items-start gap-3 rounded-2xl border border-border bg-card p-5 text-sm font-semibold leading-6"><span className="mt-0.5 grid h-6 w-6 shrink-0 place-items-center rounded-full bg-accent/12 text-accent"><Check className="h-3.5 w-3.5" /></span>{item}</li>)}
            </ul>
          </Reveal>
        </div>
      </section>

      <section className="section panel-dark">
        <div className="container-uten">
          <p className="text-[11px] font-bold uppercase tracking-[.22em] text-accent-soft">{t('processEyebrow')}</p>
          <h2 className="section-title mt-7 max-w-4xl">{t('processTitle')}</h2>
          {custom.processBody && <p className="mt-6 max-w-2xl leading-8 text-primary-foreground/62">{custom.processBody}</p>}
          <ol className="mt-12 grid gap-3 md:grid-cols-5">
            {steps.map((step, index) => <li key={step} className="rounded-[1.25rem] border border-primary-foreground/15 p-5"><span className="text-xs font-bold tracking-[.14em] text-accent-soft">{String(index + 1).padStart(2, '0')}</span><p className="mt-10 font-semibold leading-6">{step}</p></li>)}
          </ol>
        </div>
      </section>

      <section id="project-brief" className="section scroll-mt-24">
        <div className="container-uten grid gap-8 lg:grid-cols-[.68fr_1.32fr] lg:gap-14">
          <Reveal className="panel-dark relative overflow-hidden rounded-[1.75rem] p-7 md:p-10">
            <div className="absolute inset-0 bg-grid opacity-10" />
            <div className="relative"><Handshake className="h-7 w-7 text-accent-soft" /><p className="mt-10 text-xs font-bold uppercase tracking-[.18em] text-accent-soft">UTEN · GLOBAL BUSINESS</p><h2 className="mt-5 text-balance text-3xl font-semibold leading-tight md:text-5xl">{t('formTitle')}</h2><p className="mt-5 max-w-md leading-8 text-primary-foreground/65">{t('formBody')}</p></div>
          </Reveal>
          <Reveal delay={100} className="card-uten p-6 md:p-9"><InquiryForm source="partner" projectBrief /></Reveal>
        </div>
      </section>
    </>
  );
}
