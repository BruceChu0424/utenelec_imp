import { notFound, redirect } from 'next/navigation';
import { Link } from '@/i18n/navigation';
import { PublicPageIntro } from '@/components/layout/PublicPageIntro';
import type { Metadata } from 'next';
import { ImageIcon, Layers3, Move } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { SceneStudio } from '@/components/studio/SceneStudio';
import { toStudioScene, toStudioVariants } from '@/lib/catalog';
import { getScenePresets, queryStudioProducts } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Studio' });
  return buildPageMetadata({
    locale,
    path: '/studio',
    title: t('title').replace(/\s*\n\s*/g, ' '),
    description: t('subtitle'),
  });
}

export default async function StudioPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ variant?: string; q?: string; page?: string }>;
}) {
  const { locale } = await params;
  const resolvedSearchParams = await searchParams;
  setRequestLocale(locale);
  const [t, common, productT] = await Promise.all([getTranslations({ locale, namespace: 'Studio' }), getTranslations({ locale, namespace: 'Common' }), getTranslations({ locale, namespace: 'Products' })]);
  const query = typeof resolvedSearchParams.q === 'string' ? resolvedSearchParams.q.trim().slice(0, 80) : '';
  const pageValue = Number(resolvedSearchParams.page);
  const page = Number.isInteger(pageValue) ? Math.max(1, Math.min(4167, pageValue)) : 1;
  const variantId = typeof resolvedSearchParams.variant === 'string' ? resolvedSearchParams.variant.trim().slice(0, 120) : '';
  const [sceneRecords, result] = await Promise.all([getScenePresets(), queryStudioProducts({ query, offset: (page - 1) * 24, variantId })]);
  if (variantId && !result.selected) notFound();
  const pages = Math.max(1, Math.ceil(result.total / 24));
  const pageHref = (target: number) => { const params = new URLSearchParams(); if (query) params.set('q', query); if (target > 1) params.set('page', String(target)); return `/studio${params.size ? '?' + params : ''}#studio`; };
  if (page > pages) redirect(`/${locale}${pageHref(pages)}`);
  const enabledProducts = result.products;
  const scenes = sceneRecords.map((scene) => toStudioScene(scene, locale));
  const variants = toStudioVariants(enabledProducts, locale, t('standardVariant')).filter((variant) => variant.image);
  const titleLines = t('title').split(/\n+/).map((line) => line.trim()).filter(Boolean);

  return (
    <>
      <PublicPageIntro locale={locale} title={titleLines.join(' ')} description={t('subtitle')} />

      <section id="studio" className="section-tight">
        <div className="container-uten">
          <form action={`/${locale}/studio#studio`} method="get" className="studio-catalog-search"><label><span>{t('search')}</span><input type="search" name="q" defaultValue={query} maxLength={80} className="input-uten" /></label><button type="submit" className="btn-primary">{common('search')}</button><p>{productT('resultCount', { count: result.total })}</p></form>
          <SceneStudio
            key={`${query}:${page}:${variantId}`}
            searchable={false}
            scenes={scenes}
            variants={variants}
            initialVariantId={variantId}
            labels={{
              scenes: t('scenes'), products: t('products'), search: t('search'), scale: t('scale'), reset: t('reset'),
              dragHint: t('dragHint'), keyboardHint: t('keyboardHint'), selected: t('selected'), dimensions: t('dimensions'), finish: t('finish'),
              viewProduct: t('viewProduct'), askAdvice: t('askAdvice'), disclaimer: t('disclaimer'), noProducts: t('noProducts'), noScenes: common('noData'),
            }}
          />
          <nav className="catalog-pagination" aria-label={productT('pagination')}>
            {page > 1 ? <Link locale={locale} href={pageHref(page - 1)} className="btn-outline">{productT('previousPage')}</Link> : <span className="pagination-disabled">{productT('previousPage')}</span>}<span>{page} / {pages}</span>{page < pages ? <Link locale={locale} href={pageHref(page + 1)} className="btn-outline">{productT('nextPage')}</Link> : <span className="pagination-disabled">{productT('nextPage')}</span>}
          </nav>
        </div>
      </section>

      <section className="section-tight border-y border-border bg-background-elevated/55">
        <div className="container-uten grid gap-10 lg:grid-cols-[.8fr_1.2fr]">
          <div>
            <p className="eyebrow">WORKFLOW</p>
            <h2 className="mt-5 text-balance text-3xl font-semibold leading-tight md:text-5xl">{t('workflowTitle')}</h2>
            <p className="mt-5 max-w-xl text-pretty leading-7 text-muted-foreground">{t('workflowBody')}</p>
          </div>
          <div className="grid gap-4 sm:grid-cols-3">
            {[
              [ImageIcon, t('chooseRoomTitle'), t('chooseRoomBody')],
              [Layers3, t('chooseFinishTitle'), t('chooseFinishBody')],
              [Move, t('placeTitle'), t('placeBody')],
            ].map(([Icon, title, body], index) => {
              const IconComponent = Icon as typeof ImageIcon;
              return <div key={String(title)} className="card-uten p-5"><span className="grid h-11 w-11 place-items-center rounded-full bg-accent-soft text-accent"><IconComponent className="h-5 w-5" /></span><p className="mt-5 text-xs font-bold uppercase tracking-[.14em] text-muted-foreground">0{index + 1}</p><h3 className="mt-2 text-lg font-semibold">{String(title)}</h3><p className="mt-2 text-sm leading-6 text-muted-foreground">{String(body)}</p></div>;
            })}
          </div>
        </div>
      </section>
    </>
  );
}
