import type { Metadata } from 'next';
import { Database, Eye, FileText, Mail, ShieldCheck, TimerReset } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { pick } from '@/lib/content';
import { getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Privacy' });
  return buildPageMetadata({ locale, path: '/privacy', title: t('title'), description: t('intro') });
}

export default async function PrivacyPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, contactRaw] = await Promise.all([
    getTranslations({ locale, namespace: 'Privacy' }),
    getSetting('contact'),
  ]);
  const contact = pick<{ company?: string; email?: string }>(contactRaw, locale) || {};
  const sections = [
    { icon: Mail, title: t('controllerTitle'), body: t('controllerBody') },
    { icon: Database, title: t('dataTitle'), body: t('dataBody') },
    { icon: FileText, title: t('purposeTitle'), body: t('purposeBody') },
    { icon: Eye, title: t('sharingTitle'), body: t('sharingBody') },
    { icon: TimerReset, title: t('retentionTitle'), body: t('retentionBody') },
    { icon: ShieldCheck, title: t('rightsTitle'), body: t('rightsBody') },
  ];

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative max-w-5xl">
          <p className="eyebrow">{t('eyebrow')}</p>
          <h1 className="page-title mt-7">{t('title')}</h1>
          <p className="prose-intro mt-6">{t('intro')}</p>
        </div>
      </section>
      <section className="section-tight">
        <div className="container-uten max-w-5xl">
          <div className="grid gap-px overflow-hidden rounded-[1.5rem] border border-border bg-border md:grid-cols-2">
            {sections.map((section) => <article key={section.title} className="bg-card p-6 md:p-8"><section.icon className="h-5 w-5 text-accent" /><h2 className="mt-8 text-xl font-semibold">{section.title}</h2><p className="mt-4 text-sm leading-7 text-muted-foreground md:text-base md:leading-8">{section.body}</p></article>)}
          </div>
          {(contact.company || contact.email) && <p className="mt-8 rounded-2xl border border-border bg-background-elevated p-5 text-sm leading-7"><strong>{contact.company}</strong>{contact.email && <> · <a href={`mailto:${contact.email}`} className="font-semibold text-accent underline-offset-4 hover:underline">{contact.email}</a></>}</p>}
          <p className="mt-5 text-xs leading-6 text-muted-foreground">{t('reviewNote')}</p>
        </div>
      </section>
    </>
  );
}
