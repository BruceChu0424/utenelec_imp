import type { Metadata } from 'next';
import Image from 'next/image';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { PublicPageIntro } from '@/components/layout/PublicPageIntro';
import { Link } from '@/i18n/navigation';
import { getSetting } from '@/lib/queries';
import { pickLocale, trArr } from '@/lib/content';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'About' });
  return buildPageMetadata({ locale, path: '/about', title: t('title'), description: t('teamBody') });
}
export default async function AboutPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, common, nav, rawAbout, rawCraft] = await Promise.all([getTranslations({ locale, namespace: 'About' }), getTranslations({ locale, namespace: 'Common' }), getTranslations({ locale, namespace: 'Nav' }), getSetting('about'), getSetting('craft')]);
  const about = pickLocale<Partial<{ title: string; subtitle: string; body: string; cta: string; image1: string; image2: string; image3: string }>>(rawAbout, locale) || {};
  const craft = trArr<{ title: string; desc: string }>(rawCraft, locale);
  const image = about.image1 || '/uploads/legacy-v2/b8/b89b1a4acfcd35398326d0c596bbc4912adb53f9c170bc172a3eef1d5f245e3f.jpg';
  return <>
    <PublicPageIntro locale={locale} title={about.title || t('title')} description={about.subtitle || t('teamBody')} />
    <section className="container-uten public-company-story"><div><h2>{t('teamTitle')}</h2><p>{about.body || t('teamBody')}</p><Link locale={locale} href="/contact" className="public-text-link">{about.cta || common('contactUs')}</Link></div><figure><div className="relative aspect-[8/3]"><Image src={image} alt={t('archiveLabel')} fill priority sizes="(max-width: 900px) 100vw, 58vw" className="object-contain" /></div><figcaption>{t('archiveLabel')}</figcaption></figure></section>
    {craft.length > 0 && <section className="section container-uten"><div className="public-section-heading"><h2>{t('coreCraftTitle')}</h2><Link locale={locale} href="/capabilities" className="public-text-link">{nav('capabilities')}</Link></div><div className="public-service-grid">{craft.map(item => <article key={item.title}><h3>{item.title}</h3><p>{item.desc}</p></article>)}</div></section>}
    <section className="section container-uten public-section-rule"><div className="public-section-heading"><h2>{nav('products')}</h2><p>{t('teamBody')}</p></div><div className="public-actions"><Link locale={locale} href="/products" className="btn-primary">{nav('products')}</Link><Link locale={locale} href="/resources" className="public-text-link">{nav('resources')}</Link><Link locale={locale} href="/partners" className="public-text-link">{nav('partners')}</Link></div></section>
  </>;
}
