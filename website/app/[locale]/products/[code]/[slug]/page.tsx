import { setRequestLocale, getTranslations } from 'next-intl/server';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { Link } from '@/i18n/navigation';
import { ArrowLeft, Check } from 'lucide-react';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { ProductCard } from '@/components/ProductCard';

export async function generateStaticParams() {
  const products = await prisma.product.findMany({ select: { slug: true, series: { select: { code: true } } } });
  return products
    .filter((p) => p.series)
    .map((p) => ({ code: p.series!.code, slug: p.slug }));
}

export async function generateMetadata({ params }: { params: { locale: string; code: string; slug: string } }): Promise<Metadata> {
  const p = await prisma.product.findUnique({ where: { slug: params.slug } });
  if (!p) return {};
  return { title: tr<{ name: string }>(p.i18n, params.locale).name };
}

export default async function ProductDetailPage({ params }: { params: { locale: string; code: string; slug: string } }) {
  const { locale, code, slug } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Products');
  const tc = await getTranslations('Common');
  const product = await prisma.product.findUnique({
    where: { slug },
    include: { series: true },
  });
  if (!product || !product.series || product.series.code !== code) notFound();

  const pd = tr<{ name: string; description?: string }>(product.i18n, locale);
  const series = tr<{ name: string }>(product.series.i18n, locale);
  const related = await prisma.product.findMany({
    where: { seriesId: product.seriesId, published: true, NOT: { id: product.id } },
    take: 4,
    include: { series: true },
  });

  return (
    <div className="container-uten py-10">
      <Link href={`/products/${code}`} className="mb-6 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-accent">
        <ArrowLeft className="h-4 w-4" />{series.name}
      </Link>

      <div className="grid gap-10 lg:grid-cols-2">
        <div className="overflow-hidden rounded-2xl border border-border bg-gradient-to-br from-muted to-background p-10">
          {product.image ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={product.image} alt={pd.name} className="aspect-square w-full object-contain" />
          ) : (
            <div className="grid aspect-square place-items-center text-6xl font-bold text-muted-foreground/30">U</div>
          )}
        </div>
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.2em] text-accent">{series.name}</p>
          <h1 className="mt-2 font-heading text-3xl font-bold md:text-4xl">{pd.name}</h1>
          {pd.description && <p className="mt-5 leading-relaxed text-muted-foreground">{pd.description}</p>}

          <div className="mt-8 space-y-3 rounded-xl border border-border bg-muted/40 p-5">
            {[
              locale === 'zh' ? '优腾精工制造' : 'Precision manufactured by Uten',
              locale === 'zh' ? '安全阻燃材料' : 'Safe flame-retardant materials',
              locale === 'zh' ? '25年行业经验' : '25 years of expertise',
            ].map((f) => (
              <div key={f} className="flex items-center gap-2 text-sm">
                <span className="grid h-5 w-5 place-items-center rounded-full bg-accent/15 text-accent"><Check className="h-3 w-3" /></span>
                {f}
              </div>
            ))}
          </div>

          <div className="mt-6 flex gap-3">
            <Link href="/contact" className="btn-accent">{tc('contactUs')}</Link>
            <Link href={`/products/${code}`} className="btn-outline">{t('relatedProducts')}</Link>
          </div>
        </div>
      </div>

      {related.length > 0 && (
        <section className="mt-16">
          <h2 className="mb-5 text-xl font-bold">{t('relatedProducts')}</h2>
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {related.map((p) => <ProductCard key={p.id} product={p} locale={locale} />)}
          </div>
        </section>
      )}
    </div>
  );
}
