import type { Metadata } from 'next';
import Image from 'next/image';
import { ArrowUpRight, FileCheck2, Globe2, Handshake, Sparkles } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { Hero } from '@/components/home/Hero';
import { StudioTeaser } from '@/components/home/StudioTeaser';
import { Reveal } from '@/components/motion/Reveal';
import { Link } from '@/i18n/navigation';
import { toCatalogFamily, toCatalogProduct, toStudioScene, toStudioVariants } from '@/lib/catalog';
import { pickLocale } from '@/lib/content';
import { getCatalogFamilies, getLatestProducts, getScenePresets, getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const [t, meta] = await Promise.all([
    getTranslations({ locale, namespace: 'Home' }),
    getTranslations({ locale, namespace: 'Meta' }),
  ]);
  return buildPageMetadata({ locale, path: '/', title: meta('company'), description: t('heroSubtitle'), absoluteTitle: true });
}

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, common, productsT] = await Promise.all([
    getTranslations({ locale, namespace: 'Home' }),
    getTranslations({ locale, namespace: 'Common' }),
    getTranslations({ locale, namespace: 'Products' }),
  ]);

  const [latestRecords, heroRaw, familyRecords, sceneRecords] = await Promise.all([
    getLatestProducts(6),
    getSetting('hero'),
    getCatalogFamilies(),
    getScenePresets(),
  ]);

  const localizedHero = pickLocale<Partial<{ title: string; subtitle: string; cta1: string; cta2: string }>>(heroRaw, locale);
  const hero = {
    title: localizedHero?.title || t('heroTitle'),
    subtitle: localizedHero?.subtitle || t('heroSubtitle'),
    cta1: localizedHero?.cta1 || t('heroPrimary'),
    cta2: localizedHero?.cta2 || t('heroSecondary'),
  };
  const families = familyRecords.map((family) => toCatalogFamily(family, locale));
  const standardName = productsT('standardVariant');
  const latest = latestRecords.map((record) => toCatalogProduct(record, locale, standardName));
  const functionLabels = productsT.raw('functionTypes') as Record<string, string>;
  const latestVariants = toStudioVariants(latestRecords, locale, standardName).filter((variant) => variant.image);
  const featuredVariant = latestVariants[0];
  const featured = featuredVariant ? {
    image: featuredVariant.image,
    name: featuredVariant.productName,
    series: featuredVariant.seriesName,
    href: featuredVariant.productHref,
  } : null;
  const latestStories = featured && latest.length > 1 ? latest.slice(1, 6) : latest.slice(0, 5);

  const scenes = sceneRecords.length
    ? sceneRecords.map((scene) => toStudioScene(scene, locale))
    : [
        { id: 'warm', slug: 'warm', name: t('sceneWarm'), image: '/images/scenes/warm-plaster.webp' },
        { id: 'mineral', slug: 'mineral', name: t('sceneMineral'), image: '/images/scenes/mineral-gallery.webp' },
        { id: 'walnut', slug: 'walnut', name: t('sceneWalnut'), image: '/images/scenes/walnut-suite.webp' },
      ];
  // Every product surfaced on the homepage comes from the same curated latest
  // set. The full Studio can still expose the wider scene-enabled catalogue.
  const teaserVariants = toStudioVariants(latestRecords, locale, standardName).filter((variant) => variant.image);
  const teaserItems = teaserVariants.slice(0, 8).map((variant) => ({ id: variant.id, name: variant.name, productName: variant.productName, image: variant.image, swatchHex: variant.swatchHex }));
  const storyBackgrounds = [
    'bg-[linear-gradient(145deg,hsl(var(--muted)),hsl(var(--card)))]',
    'bg-[linear-gradient(145deg,hsl(var(--accent)/.10),hsl(var(--card))_68%)]',
    'bg-[linear-gradient(145deg,hsl(var(--primary)/.08),hsl(var(--muted)))]',
    'bg-[linear-gradient(145deg,hsl(var(--card)),hsl(var(--accent)/.08))]',
  ];

  return (
    <>
      <Hero
        hero={hero}
        featured={featured}
        collectionCount={families.length}
        labels={{ eyebrow: t('heroEyebrow'), experience: t('experience'), collections: t('collections'), global: t('global'), featured: t('featured') }}
      />

      {families.length > 0 && (
        <div className="overflow-hidden border-b border-border bg-primary py-4 text-primary-foreground">
          <div className="animate-marquee flex w-max items-center whitespace-nowrap will-change-transform">
            {[...families, ...families].map((family, index) => (
              <span key={`${family.id}-${index}`} className="inline-flex items-center">
                <Link locale={locale} href={`/products/${family.slug}`} className="mx-3 inline-flex min-h-11 items-center px-4 text-xs font-bold uppercase tracking-[.2em] text-primary-foreground/72 transition hover:text-primary-foreground focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-soft">{family.name}</Link>
                <span className="h-1.5 w-1.5 rounded-full bg-accent" />
              </span>
            ))}
          </div>
        </div>
      )}

      <section id="latest-products" className="section">
        <div className="container-uten">
          <Reveal className="mx-auto max-w-4xl text-center">
            <p className="eyebrow">{t('latestEyebrow')}</p>
            <h2 className="section-title mt-7 text-balance">{t('latestTitle')}</h2>
            <p className="mx-auto mt-6 max-w-2xl text-pretty text-base leading-8 text-muted-foreground md:text-lg">{t('latestBody')}</p>
          </Reveal>

          <div className="mt-14 space-y-6 lg:mt-20 lg:space-y-10">
            {latestStories.map((product, index) => {
              const variant = product.variants[0];
              const image = variant?.image || product.image;
              const href = variant ? `${product.href}?variant=${encodeURIComponent(variant.id)}` : product.href;
              const studioHref = variant ? `/studio?variant=${encodeURIComponent(variant.id)}` : '/studio';
              const story = product.classificationStatus === 'VERIFIED' && product.description
                ? product.description
                : t('latestProductFallback', {
                    product: product.name,
                    series: product.seriesName || 'UTEN',
                  });
              const reverse = index % 2 === 1;
              return (
                <Reveal key={product.id}>
                  <article className="grid overflow-hidden rounded-[1.75rem] border border-border bg-card lg:min-h-[520px] lg:grid-cols-2">
                    <div className={`relative min-h-[340px] overflow-hidden sm:min-h-[430px] lg:min-h-full ${storyBackgrounds[index % storyBackgrounds.length]} ${reverse ? 'lg:order-2' : ''}`}>
                      <div className="absolute inset-0 bg-dots opacity-35" />
                      {image ? <Image src={image} alt={product.name} fill priority={index === 0} sizes="(max-width:1024px) 100vw, 50vw" className="product-cutout object-contain p-[18%] sm:p-[20%] lg:p-[21%]" /> : <span className="absolute inset-0 grid place-items-center text-8xl font-bold text-muted-foreground/15">U</span>}
                      <span className="glass absolute start-5 top-5 rounded-full px-4 py-2 text-[11px] font-bold uppercase tracking-[.14em]">{product.seriesName || t('latestEyebrow')}</span>
                    </div>
                    <div className={`flex flex-col justify-center p-7 sm:p-10 lg:p-14 ${reverse ? 'lg:order-1' : ''}`}>
                      <p className="text-xs font-bold uppercase tracking-[.18em] text-accent">{functionLabels[product.functionType] || functionLabels.other}</p>
                      <h3 className="mt-5 text-balance text-3xl font-semibold leading-[1.04] tracking-[-.055em] sm:text-5xl lg:text-6xl">{product.name}</h3>
                      {product.model && product.model.toLocaleLowerCase() !== product.name.toLocaleLowerCase() && <p className="mt-3 font-mono text-sm text-muted-foreground">{product.model}</p>}
                      <p className="mt-6 max-w-xl text-pretty leading-8 text-muted-foreground">{story}</p>
                      <div className="mt-8 flex flex-wrap gap-3">
                        <Link locale={locale} href={href} className="btn-accent">{t('latestView')}<ArrowUpRight className="h-4 w-4" /></Link>
                        <Link locale={locale} href={studioHref} className="btn-outline">{t('latestStudio')}</Link>
                      </div>
                    </div>
                  </article>
                </Reveal>
              );
            })}
          </div>
          <div className="mt-10 text-center"><Link locale={locale} href="/products" className="btn-outline">{t('viewCollections')}<ArrowUpRight className="h-4 w-4" /></Link></div>
        </div>
      </section>

      {scenes.length > 0 && teaserItems.length > 0 && (
        <section className="section border-y border-border bg-background-elevated/55">
          <div className="container-uten">
            <div className="mb-10 grid items-end gap-8 lg:grid-cols-[1fr_.8fr]">
              <Reveal><p className="eyebrow">{t('studioEyebrow')}</p><h2 className="section-title mt-7 text-balance">{t('studioTitle').replace(/\s*\n\s*/g, ' ')}</h2></Reveal>
              <Reveal delay={100}><p className="max-w-xl text-pretty text-base leading-8 text-muted-foreground md:text-lg">{t('studioBody')}</p></Reveal>
            </div>
            <Reveal delay={140}><StudioTeaser scenes={scenes.map((scene) => ({ id: scene.id, name: scene.name, image: scene.image }))} variants={teaserItems} labels={{ scene: t('studioScene'), product: t('studioProduct'), openStudio: t('studioOpen'), preview: t('studioPreview') }} /></Reveal>
          </div>
        </section>
      )}

      <section className="section panel-dark overflow-hidden">
        <div className="container-uten">
          <Reveal className="max-w-4xl">
            <p className="text-[11px] font-bold uppercase tracking-[.22em] text-accent-soft">{t('globalEyebrow')}</p>
            <h2 className="section-title mt-7">{t('globalTitle')}</h2>
            <p className="mt-6 max-w-2xl text-pretty leading-8 text-primary-foreground/62">{t('globalBody')}</p>
          </Reveal>
          <div className="mt-12 grid gap-px overflow-hidden rounded-[1.5rem] border border-primary-foreground/15 bg-primary-foreground/15 md:grid-cols-3">
            {[
              { icon: Globe2, title: t('marketTitle'), body: t('marketBody') },
              { icon: Handshake, title: t('oemTitle'), body: t('oemBody') },
              { icon: FileCheck2, title: t('documentsTitle'), body: t('documentsBody') },
            ].map((item, index) => (
              <Reveal key={item.title} delay={index * 65} className="h-full"><article className="h-full bg-primary p-7 md:p-8"><item.icon className="h-6 w-6 text-accent-soft" /><p className="mt-12 text-xs font-bold tracking-[.16em] text-primary-foreground/38">0{index + 1}</p><h3 className="mt-3 text-xl font-semibold">{item.title}</h3><p className="mt-4 text-sm leading-7 text-primary-foreground/58">{item.body}</p></article></Reveal>
            ))}
          </div>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link locale={locale} href="/capabilities" className="btn bg-primary-foreground text-primary hover:bg-primary-foreground/88">{t('globalCta')}<Sparkles className="h-4 w-4" /></Link>
            <Link locale={locale} href="/partners#project-brief" className="btn border border-primary-foreground/25 text-primary-foreground hover:bg-primary-foreground/8">{t('partnersCta')}<ArrowUpRight className="h-4 w-4" /></Link>
          </div>
        </div>
      </section>
    </>
  );
}
