import type { Metadata } from 'next';
import Image from 'next/image';
import { ArrowUpRight, Factory, Globe2, ShieldCheck, UsersRound } from 'lucide-react';
import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { getSetting } from '@/lib/queries';
import { pick, trArr } from '@/lib/content';
import { SectionHeading } from '@/components/SectionHeading';
import { buildPageMetadata } from '@/lib/seo';

const FALLBACK_ABOUT_IMAGES = [
  '/uploads/legacy-v2/b8/b89b1a4acfcd35398326d0c596bbc4912adb53f9c170bc172a3eef1d5f245e3f.jpg',
  '/images/raw/Upload_PicFiles_image_20170911_20170911142456105610.jpg',
  '/images/raw/Edt-fuc-hqlf_ce22gl_hqlf_.._.._.._Upload_PicFiles_image_20170911_20170911142552875287.jpg',
];

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'About' });
  return buildPageMetadata({ locale, path: '/about', title: t('title'), description: t('teamBody') });
}

export default async function AboutPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations('About');
  const tc = await getTranslations('Common');
  const about = pick<{
    title: string;
    subtitle: string;
    body: string;
    cta: string;
    image1?: string;
    image2?: string;
    image3?: string;
  }>(await getSetting('about'), locale)!;
  const stats = trArr<{ value: string; label: string }>(await getSetting('stats'), locale);
  const craft = trArr<{ title: string; desc: string }>(await getSetting('craft'), locale);
  // 公司硬事实（创立积累 / 基地 / 认证 / 全球布局）优先于 CMS 统计条展示。
  const factsRaw = t.raw('facts') as { value: string; label: string }[];
  const facts = factsRaw.length ? factsRaw.slice(0, 4) : stats;
  const aboutImages = [about.image1, about.image2, about.image3].map(
    (image, index) => image || FALLBACK_ABOUT_IMAGES[index],
  );

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-8 lg:grid-cols-[1fr_.72fr] lg:gap-16">
          <div>
            <span className="eyebrow">{about.subtitle}</span>
            <h1 className="page-title mt-7 max-w-4xl">{about.title}</h1>
          </div>
          <div className="border-s border-border ps-6 lg:ps-8">
            <p className="text-sm font-bold uppercase tracking-[.16em] text-accent">{t('manufacturingEyebrow')}</p>
            <p className="mt-4 text-pretty text-base leading-8 text-muted-foreground">{t('teamBody')}</p>
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten grid gap-10 lg:grid-cols-[1.08fr_.92fr] lg:items-center lg:gap-16">
          <div className="grid grid-cols-2 gap-3">
            <div className="media-stage relative col-span-2 aspect-[8/3]">
              <Image src={aboutImages[0]} alt={about.title} fill priority sizes="(max-width: 1024px) 100vw, 55vw" className="object-cover" />
              <div className="absolute inset-0 bg-gradient-to-t from-foreground/25 via-transparent to-transparent" />
              <span className="glass absolute bottom-4 start-4 rounded-full px-4 py-2 text-xs font-semibold">{t('archiveLabel')}</span>
            </div>
            {aboutImages.slice(1).map((src, index) => (
              <div key={src} className="media-stage relative aspect-[4/3]">
                <Image src={src} alt={`${about.title} ${index + 2}`} fill sizes="(max-width: 1024px) 50vw, 28vw" className="object-cover" />
              </div>
            ))}
          </div>
          <div>
            <p className="eyebrow">{t('mission')}</p>
            <h2 className="mt-6 text-balance text-3xl font-semibold leading-[1.12] tracking-[-.04em] md:text-5xl">{t('teamTitle')}</h2>
            <p className="mt-6 text-pretty text-base leading-8 text-muted-foreground md:text-lg md:leading-9">{about.body}</p>
            <Link href="/contact" className="btn-outline mt-8">{about.cta || tc('contactUs')}<ArrowUpRight className="h-4 w-4" /></Link>
          </div>
        </div>
      </section>

      <section className="border-y border-border bg-card">
        <div className="container-uten grid grid-cols-2 md:grid-cols-4">
          {facts.map((s, index) => {
            const Icon = [Factory, ShieldCheck, Globe2, UsersRound][index % 4];
            return (
            <div key={s.label} className="border-b border-border px-4 py-8 text-center even:border-s md:border-b-0 md:border-s md:first:border-s-0 md:px-6 md:py-10">
              <Icon className="mx-auto h-5 w-5 text-accent" />
              <p className="mt-3 font-heading text-3xl font-bold tracking-[-.04em] md:text-4xl">{s.value}</p>
              <p className="mt-1 text-sm text-muted-foreground">{s.label}</p>
            </div>
          ); })}
        </div>
      </section>

      <section className="section bg-background-elevated/55">
        <div className="container-uten">
          <SectionHeading eyebrow={t('craft')} title={t('coreCraftTitle')} className="max-w-3xl" />
          <div className="mt-10 grid gap-px overflow-hidden rounded-[1.5rem] border border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
            {craft.map((c, i) => (
              <div key={c.title} className="bg-card p-6 md:p-8">
                <p className="text-xs font-bold tracking-[.16em] text-accent">{String(i + 1).padStart(2, '0')}</p>
                <h3 className="mt-8 text-xl font-semibold">{c.title}</h3>
                <p className="mt-3 text-sm leading-7 text-muted-foreground">{c.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <div className="panel-dark relative overflow-hidden rounded-[1.75rem] p-8 text-center md:p-14">
            <div className="absolute inset-0 bg-grid opacity-10" />
            <h2 className="relative mx-auto max-w-3xl text-balance font-heading text-3xl font-semibold leading-tight md:text-5xl">
              {t('teamTitle')}
            </h2>
            <p className="relative mx-auto mt-5 max-w-2xl leading-8 text-primary-foreground/70">
              {t('teamBody')}
            </p>
            <Link href="/contact" className="btn-accent relative mt-8">{tc('contactUs')}<ArrowUpRight className="h-4 w-4" /></Link>
          </div>
        </div>
      </section>
    </>
  );
}
