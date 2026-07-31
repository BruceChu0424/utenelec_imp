import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { ArrowRight, Phone } from 'lucide-react';
import { getSetting, getNewsList, getCases, getLatestProducts } from '@/lib/queries';
import { pick, trArr, tr } from '@/lib/content';
import { SectionHeading } from '@/components/SectionHeading';
import { NewsCard } from '@/components/NewsCard';
import { Hero } from '@/components/home/Hero';
import { Reveal } from '@/components/motion/Reveal';
import { CountUp } from '@/components/motion/CountUp';

const ABOUT_IMGS = ['/images/raw/images_in1.jpg', '/images/raw/images_in2.jpg', '/images/raw/images_in3.jpg', '/images/raw/images_in4.jpg'];

export default async function HomePage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Home');
  const tc = await getTranslations('Common');
  const tn = await getTranslations('Nav');

  const [latest, heroR, statsR, aboutR, craftR, cases, news] = await Promise.all([
    getLatestProducts(4), getSetting('hero'), getSetting('stats'), getSetting('about'), getSetting('craft'), getCases(), getNewsList(3),
  ]);
  const hero = pick<{ title: string; subtitle: string; cta1: string; cta2: string }>(heroR, locale)!;
  const stats = trArr<{ value: string; label: string }>(statsR, locale);
  const about = pick<{ title: string; subtitle: string; body: string; cta: string }>(aboutR, locale)!;
  const craft = trArr<{ title: string; desc: string }>(craftR, locale);

  return (
    <>
      <Hero hero={hero} locale={locale} />

      {/* ===== Stats ===== */}
      <section className="relative border-y border-border/40 bg-background-elevated/40">
        <div className="container-uten grid grid-cols-2 gap-8 py-14 md:grid-cols-4">
          {stats.map((s, i) => (
            <Reveal key={s.label} delay={i * 100} className="text-center">
              <p className="font-heading text-4xl font-bold text-gradient-accent md:text-5xl">
                <CountUp value={s.value} />
              </p>
              <p className="mt-2 text-sm text-muted-foreground">{s.label}</p>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ===== Featured Products (苹果风精选 · 少量大卡) ===== */}
      <section className="section">
        <div className="container-uten">
          <Reveal className="mb-12 flex flex-wrap items-end justify-between gap-4">
            <SectionHeading
              eyebrow={locale === 'zh' ? '精选产品' : 'Featured'}
              title={locale === 'zh' ? '最新产品' : 'Latest Products'}
            />
            <Link href="/products" className="btn-ghost">{tc('viewAll')}<ArrowRight className="h-4 w-4" /></Link>
          </Reveal>
          {latest.length === 0 ? (
            <p className="py-20 text-center text-muted-foreground">{tc('noData')}</p>
          ) : (
            <div className="grid gap-5 sm:grid-cols-2">
              {latest.map((p, i) => {
                const pd = tr<{ name: string; description?: string }>(p.i18n, locale);
                const seriesName = p.series ? tr<{ name: string }>(p.series.i18n, locale).name : '';
                const href = p.series ? `/products/${p.series.code}/${p.slug}` : '/products';
                return (
                  <Reveal key={p.id} delay={(i % 2) * 120}>
                    <Link href={href} className="card-uten group block overflow-hidden transition-all duration-500 ease-expo hover:-translate-y-1.5 hover:border-accent/40">
                      <div className="relative aspect-[4/3] overflow-hidden bg-gradient-to-br from-background-elevated to-background">
                        <div className="absolute inset-0 bg-dots opacity-30" />
                        {p.image && (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={p.image} alt={pd.name} loading="lazy" className="relative h-full w-full object-contain p-10 transition-transform duration-700 ease-expo group-hover:scale-105" />
                        )}
                      </div>
                      <div className="p-7">
                        {seriesName && <p className="text-xs font-semibold uppercase tracking-[0.2em] text-accent">{seriesName}</p>}
                        <h3 className="mt-2 font-heading text-2xl font-bold">{pd.name}</h3>
                        {pd.description && <p className="mt-2 line-clamp-2 text-sm leading-relaxed text-muted-foreground">{pd.description}</p>}
                        <span className="mt-5 inline-flex items-center gap-1 text-sm font-medium text-accent">
                          {tc('learnMore')} <ArrowRight className="h-4 w-4 transition group-hover:translate-x-1" />
                        </span>
                      </div>
                    </Link>
                  </Reveal>
                );
              })}
            </div>
          )}
        </div>
      </section>

      {/* ===== Craft ===== */}
      <section className="section relative overflow-hidden bg-background-elevated/30">
        <div className="absolute inset-0 bg-dots opacity-40 mask-fade-b" />
        <div className="container-uten relative">
          <Reveal className="mx-auto max-w-2xl">
            <SectionHeading center eyebrow={t('craftSubtitle')} title={t('craftTitle')} />
          </Reveal>
          <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
            {craft.map((c, i) => (
              <Reveal key={c.title} delay={(i % 4) * 80}>
                <div className="card-uten h-full p-6 transition hover:-translate-y-1 hover:border-accent/30">
                  <div className="grid h-12 w-12 place-items-center rounded-xl bg-accent/10 font-heading text-lg font-bold text-accent">
                    {String(i + 1).padStart(2, '0')}
                  </div>
                  <h3 className="mt-4 font-semibold">{c.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{c.desc}</p>
                </div>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ===== About ===== */}
      <section className="section">
        <div className="container-uten grid items-center gap-14 lg:grid-cols-2">
          <Reveal>
            <SectionHeading eyebrow={about.subtitle} title={about.title} />
            <p className="mt-5 leading-relaxed text-muted-foreground">{about.body}</p>
            <Link href="/about" className="btn-outline mt-7">{about.cta}<ArrowRight className="h-4 w-4" /></Link>
          </Reveal>
          <Reveal delay={150} className="grid grid-cols-2 gap-4">
            {ABOUT_IMGS.map((src, i) => (
              <div key={src} className={`overflow-hidden rounded-2xl border border-border/40 ${i % 3 === 1 ? 'translate-y-6' : ''}`}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={src} alt="Uten" className="aspect-[4/3] w-full object-cover saturate-[.9]" loading="lazy" />
              </div>
            ))}
          </Reveal>
        </div>
      </section>

      {/* ===== Cases ===== */}
      {cases.length > 0 && (
        <section className="section bg-background-elevated/30">
          <div className="container-uten">
            <div className="flex flex-wrap items-end justify-between gap-4">
              <Reveal><SectionHeading eyebrow={t('casesSubtitle')} title={t('casesTitle')} /></Reveal>
              <Reveal delay={120}><Link href="/cases" className="btn-ghost">{tc('viewAll')}<ArrowRight className="h-4 w-4" /></Link></Reveal>
            </div>
            <div className="mt-12 grid gap-5 md:grid-cols-3">
              {cases.slice(0, 3).map((c, i) => {
                const ct = tr<{ title: string; location?: string }>(c.i18n, locale);
                return (
                  <Reveal key={c.slug} delay={i * 100}>
                    <Link href="/cases" className="card-uten group block overflow-hidden p-6 transition hover:-translate-y-1 hover:border-accent/30">
                      <div className="mb-5 grid h-32 place-items-center rounded-xl border border-border/40 bg-gradient-to-br from-background to-background-elevated">
                        <span className="font-heading text-5xl font-bold text-foreground/15">{(ct.title || 'U')[0]}</span>
                      </div>
                      {ct.location && <p className="text-xs uppercase tracking-wider text-accent">{ct.location}</p>}
                      <h3 className="mt-1 font-semibold transition group-hover:text-accent">{ct.title}</h3>
                    </Link>
                  </Reveal>
                );
              })}
            </div>
          </div>
        </section>
      )}

      {/* ===== News ===== */}
      {news.length > 0 && (
        <section className="section">
          <div className="container-uten">
            <div className="flex flex-wrap items-end justify-between gap-4">
              <Reveal><SectionHeading eyebrow={t('newsSubtitle')} title={t('newsTitle')} /></Reveal>
              <Reveal delay={120}><Link href="/news" className="btn-ghost">{tc('viewAll')}<ArrowRight className="h-4 w-4" /></Link></Reveal>
            </div>
            <div className="mt-12 grid gap-5 md:grid-cols-3">
              {news.map((n, i) => (
                <Reveal key={n.slug} delay={i * 100}>
                  <div className="card-uten h-full p-5 transition hover:-translate-y-1 hover:border-accent/30">
                    <NewsCard news={n} locale={locale} />
                  </div>
                </Reveal>
              ))}
            </div>
          </div>
        </section>
      )}

      {/* ===== CTA ===== */}
      <section className="section">
        <div className="container-uten">
          <Reveal>
            <div className="relative overflow-hidden rounded-3xl border border-accent/20 bg-gradient-to-br from-background-elevated to-background p-12 text-center md:p-20">
              <div className="ambient-blob animate-blob" style={{ width: 420, height: 420, background: 'hsl(174 100% 40%)', top: '-25%', left: '35%' }} />
              <div className="relative">
                <h2 className="mx-auto max-w-3xl text-balance font-heading text-3xl font-bold md:text-4xl">{t('ctaTitle')}</h2>
                <p className="mx-auto mt-4 max-w-2xl text-muted-foreground">{t('ctaSubtitle')}</p>
                <div className="mt-9 flex flex-wrap justify-center gap-3">
                  <Link href="/contact" className="btn-accent"><Phone className="h-4 w-4" />{tc('contactUs')}</Link>
                  <Link href="/join" className="btn-outline">{tn('join')}</Link>
                </div>
              </div>
            </div>
          </Reveal>
        </div>
      </section>
    </>
  );
}
