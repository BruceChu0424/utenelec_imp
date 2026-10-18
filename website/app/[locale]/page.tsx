import type { Metadata } from 'next';
import Image from 'next/image';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { SeriesCard } from '@/components/products/SeriesCard';
import { ProductMatrixCard } from '@/components/products/ProductMatrixCard';
import { StudioTeaser } from '@/components/home/StudioTeaser';
import { toCatalogFamily, toCatalogProduct, toStudioScene, toStudioVariants } from '@/lib/catalog';
import { pickLocale } from '@/lib/content';
import { getCatalogFamilies, getLatestProducts, getScenePresets, getSetting } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const [t, meta] = await Promise.all([getTranslations({ locale, namespace: 'Home' }), getTranslations({ locale, namespace: 'Meta' })]);
  return buildPageMetadata({ locale, path: '/', title: meta('company'), description: t('heroSubtitle'), absoluteTitle: true });
}

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const [t, common, productsT, nav, records, familyRecords, sceneRecords, rawHero] = await Promise.all([
    getTranslations({ locale, namespace: 'Home' }), getTranslations({ locale, namespace: 'Common' }),
    getTranslations({ locale, namespace: 'Products' }), getTranslations({ locale, namespace: 'Nav' }),
    getLatestProducts(6), getCatalogFamilies(), getScenePresets(), getSetting('hero'),
  ]);
  const custom = pickLocale<Partial<{ title: string; subtitle: string; cta1: string; cta2: string; heroImage: string; heroSeriesId: string }>>(rawHero, locale);
  const sharedHero = pickLocale<Partial<{ heroImage: string; heroSeriesId: string }>>(rawHero, 'zh');
  const families = familyRecords.map(record => toCatalogFamily(record, locale)).filter(family => family.count > 0);
  const selectedFamily = families.find(family => family.id === sharedHero?.heroSeriesId);
  const latest = records.map(record => toCatalogProduct(record, locale, productsT('standardVariant')));
  const familyCandidates = [selectedFamily, ...latest.map(product => families.find(family => family.slug === product.seriesCode)), ...families].filter((family): family is (typeof families)[number] => Boolean(family));
  const featuredFamilies = [...new Map(familyCandidates.map(family => [family.id, family])).values()].slice(0, 4);
  const heroTitleLines = (custom?.title || t('heroTitle')).split(/\r?\n|\s*[·•]\s*/).map(line => line.trim()).filter(Boolean);
  const featured = selectedFamily ? latest.find(product => product.seriesCode === selectedFamily.slug) : latest[0];
  const selectedRecord = familyRecords.find(record => record.id === selectedFamily?.id);
  const selectedProduct = selectedRecord ? [...selectedRecord.products, ...selectedRecord.children.flatMap(child => child.products)].find(product => product.image || product.variants.some(variant => variant.image)) : undefined;
  const heroProductImage = selectedFamily ? (featured?.image || selectedProduct?.variants.find(variant => variant.image)?.image || selectedProduct?.image || selectedFamily.images.find(item => item.kind === 'product')?.src) : featured?.image;
  const scenes = sceneRecords.map(scene => toStudioScene(scene, locale));
  const image = sharedHero?.heroImage?.startsWith('/') && !sharedHero.heroImage.startsWith('//') ? sharedHero.heroImage : scenes[0]?.image || '/images/scenes/mineral-gallery.webp';
  const variants = toStudioVariants(records.filter(record => record.sceneEnabled), locale, productsT('standardVariant')).slice(0, 6);
  const functionTypes = productsT.raw('functionTypes') as Record<string, string>;

  return <>
    <section className="public-home-hero">
      <div className="public-home-copy"><h1>{heroTitleLines.map((line, index) => <span className="block" key={`${index}-${line}`}>{line}</span>)}</h1><p>{custom?.subtitle || t('heroSubtitle')}</p><div className="public-actions"><Link locale={locale} href="/products" className="btn-primary">{custom?.cta1 || t('heroPrimary')}</Link><Link locale={locale} href="/contact" className="public-text-link">{custom?.cta2 || common('contactUs')}</Link></div><p className="public-home-signature">UTEN ELEC</p></div>
      <div className="public-home-scene"><Image src={image} alt={sharedHero?.heroImage ? t('sceneIllustration') : scenes[0]?.name || t('sceneIllustration')} fill priority sizes="(max-width: 760px) 100vw, 58vw" className="object-cover" />
        {heroProductImage && <div className="public-home-product"><Image src={heroProductImage} alt={selectedFamily?.name || featured?.name || productsT('title')} width={140} height={140} className="h-auto w-full object-contain" /></div>}
        <div className="public-home-caption"><span>{t('sceneIllustration')}</span>{(selectedFamily || featured) && <Link locale={locale} href={selectedFamily ? `/products/${selectedFamily.slug}` : featured!.href}><strong>{selectedFamily?.name || featured?.seriesName}</strong><span>{productsT('viewDetail')}</span></Link>}</div>
      </div>
    </section>
    <nav className="public-discovery container-uten" aria-label={productsT('browseSeries')}>
      {[['/products', nav('products'), productsT('browseSeries')], ['/studio', nav('studio'), t('studioOpen')], ['/resources', nav('resources'), common('requestDocuments')], ['/partners', nav('partners'), common('startProject')]].map(([href, title, note]) => <Link locale={locale} key={href} href={href}><strong>{title}</strong><span>{note}</span></Link>)}
    </nav>
    {families.length > 0 && <section className="section container-uten"><div className="public-section-heading"><div><h2>{t('discoverTitle')}</h2><p>{t('discoverBody')}</p></div><Link locale={locale} href="/products" className="public-text-link">{common('viewAll')}</Link></div><div className="public-family-grid">{featuredFamilies.map(family => <SeriesCard key={family.id} family={family} locale={locale} labels={{ products: productsT.raw('seriesProducts') as string, explore: productsT('exploreSeries') }} />)}</div></section>}
    {latest.length > 0 && <section className="section container-uten public-section-rule"><div className="public-section-heading"><div><h2>{t('featuredProducts')}</h2><p>{t('heroSubtitle')}</p></div><Link locale={locale} href="/products" className="public-text-link">{productsT('browseSeries')}</Link></div><div className="public-product-row">{latest.slice(0, 4).map(product => <ProductMatrixCard key={product.id} product={product} locale={locale} labels={{ variants: productsT('variants'), viewDetail: productsT('viewDetail'), gang: productsT.raw('gang') as string, functionTypes }} />)}</div></section>}
    {scenes.length > 0 && variants.length > 0 && <section className="public-studio-feature"><StudioTeaser scenes={scenes} variants={variants.map(variant => ({ id: variant.id, name: variant.name, productName: variant.productName, image: variant.image, swatchHex: variant.swatchHex }))} labels={{ scene: t('studioScene'), product: t('studioProduct'), preview: t('studioPreview'), openStudio: t('studioOpen') }} /><div><h2>{t('studioTitle')}</h2><p>{t('studioBody')}</p><Link locale={locale} href="/studio" className="btn-primary">{t('studioOpen')}</Link></div></section>}
    <section className="section container-uten"><div className="public-section-heading"><h2>{t('globalTitle')}</h2><p>{t('globalBody')}</p></div><div className="public-service-grid">{[['/partners', t('marketTitle'), t('marketBody')], ['/capabilities', t('oemTitle'), t('oemBody')], ['/resources', t('documentsTitle'), t('documentsBody')]].map(([href, title, body]) => <article key={href}><h3>{title}</h3><p>{body}</p><Link locale={locale} href={href} className="public-text-link">{common('learnMore')}</Link></article>)}</div></section>
    <section className="public-brand-band"><div className="container-uten"><h2>{t('ctaTitle')}</h2><div><p>{t('ctaSubtitle')}</p><Link locale={locale} href="/contact" className="btn-outline">{common('contactUs')}</Link></div></div></section>
  </>;
}
