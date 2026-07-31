import { Link } from '@/i18n/navigation';
import { tr } from '@/lib/content';

type Product = {
  slug: string;
  image: string | null;
  i18n: string | null;
  series: { code: string; i18n: string | null } | null;
};

export function ProductCard({ product, locale }: { product: Product; locale: string }) {
  const t = tr<{ name: string }>(product.i18n, locale);
  const seriesName = product.series ? tr<{ name: string }>(product.series.i18n, locale).name : '';
  const href = product.series ? `/products/${product.series.code}/${product.slug}` : '/products';
  return (
    <Link href={href} className="card-uten group block overflow-hidden transition-all duration-500 ease-expo hover:-translate-y-1.5 hover:border-accent/40">
      <div className="relative aspect-square overflow-hidden bg-gradient-to-br from-muted/40 to-background p-6">
        {product.image ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={product.image}
            alt={t.name}
            loading="lazy"
            className="h-full w-full object-contain transition-transform duration-500 group-hover:scale-105"
          />
        ) : (
          <div className="grid h-full place-items-center text-3xl font-bold text-muted-foreground/40">U</div>
        )}
      </div>
      <div className="border-t border-border/60 p-4">
        {seriesName && <p className="mb-0.5 text-xs uppercase tracking-wider text-accent">{seriesName}</p>}
        <p className="truncate font-medium">{t.name}</p>
      </div>
    </Link>
  );
}
