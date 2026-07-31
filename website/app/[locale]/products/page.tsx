import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { getSeries, getProducts } from '@/lib/queries';
import { tr } from '@/lib/content';
import { ProductCard } from '@/components/ProductCard';

export default async function ProductsPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Products');
  const [series, products] = await Promise.all([getSeries(), getProducts({ take: 60 })]);

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-20">
        <div className="ambient-blob" style={{ width: 380, height: 380, background: 'hsl(174 100% 40%)', top: '-40%', right: '5%' }} />
        <div className="container-uten relative">
          <span className="eyebrow">Products</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{t('title')}</span></h1>
          <p className="mt-3 text-muted-foreground">{t('subtitle')}</p>
        </div>
      </section>

      <div className="container-uten py-10">
        <div className="mb-8 flex flex-wrap gap-2">
          <span className="rounded-full bg-primary px-4 py-2 text-sm font-medium text-primary-foreground">{t('allSeries')}</span>
          {series.map((s) => {
            const name = tr<{ name: string }>(s.i18n, locale).name;
            return (
              <Link key={s.code} href={`/products/${s.code}`}
                className="rounded-full border border-border bg-card px-4 py-2 text-sm transition hover:border-accent hover:text-accent">
                {name}
              </Link>
            );
          })}
        </div>
        {products.length === 0 ? (
          <p className="py-20 text-center text-muted-foreground">{t('empty')}</p>
        ) : (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {products.map((p) => <ProductCard key={p.id} product={p} locale={locale} />)}
          </div>
        )}
      </div>
    </>
  );
}
