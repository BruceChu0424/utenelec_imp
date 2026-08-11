import type { Metadata } from 'next';
import { ArrowDown, ImageIcon, Layers3, Move } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { SceneStudio } from '@/components/studio/SceneStudio';
import { toStudioScene, toStudioVariants } from '@/lib/catalog';
import { getProducts, getScenePresets, getSceneProducts } from '@/lib/queries';
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
  searchParams: Promise<{ variant?: string }>;
}) {
  const { locale } = await params;
  const resolvedSearchParams = await searchParams;
  setRequestLocale(locale);
  const t = await getTranslations('Studio');
  const [sceneRecords, enabledProducts] = await Promise.all([getScenePresets(), getSceneProducts()]);
  const fallbackProducts = enabledProducts.length ? enabledProducts : await getProducts({ take: 36 });
  const scenes = sceneRecords.map((scene) => toStudioScene(scene, locale));
  const variants = toStudioVariants(fallbackProducts, locale, t('standardVariant')).filter((variant) => variant.image);
  const titleLines = t('title').split(/\n+/).map((line) => line.trim()).filter(Boolean);

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative grid items-end gap-10 lg:grid-cols-[1fr_.7fr]">
          <div>
            <p className="eyebrow">{t('eyebrow')}</p>
            <h1 className="page-title mt-7 max-w-5xl text-balance max-sm:!text-[2.45rem]">
              {titleLines.map((line) => <span key={line} className="block">{line}</span>)}
            </h1>
          </div>
          <div>
            <p className="text-pretty text-base leading-8 text-muted-foreground md:text-lg">{t('subtitle')}</p>
            <a href="#studio" className="mt-6 inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-accent">{t('startPreview')}<ArrowDown className="h-4 w-4" /></a>
          </div>
        </div>
      </section>

      <section id="studio" className="section-tight">
        <div className="container-uten">
          <SceneStudio
            scenes={scenes}
            variants={variants}
            initialVariantId={resolvedSearchParams.variant}
            labels={{
              scenes: t('scenes'), products: t('products'), search: t('search'), scale: t('scale'), reset: t('reset'),
              dragHint: t('dragHint'), keyboardHint: t('keyboardHint'), selected: t('selected'), dimensions: t('dimensions'), finish: t('finish'),
              viewProduct: t('viewProduct'), askAdvice: t('askAdvice'), disclaimer: t('disclaimer'), noProducts: t('noProducts'),
            }}
          />
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
