import Image from 'next/image';
import { ArrowUpRight } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import { catalogFamilyDisplayName, catalogFamilySlug } from '@/lib/catalog';
import { seriesDisplayName, tr } from '@/lib/content';

type Product = {
  slug: string;
  model?: string | null;
  image: string | null;
  i18n: string | null;
  variants?: { id: string; image: string | null; i18n: string | null; swatchHex?: string | null }[];
  series: {
    code: string;
    publicSlug?: string | null;
    catalogRole?: string;
    i18n: string | null;
    sourceIdentity?: string | null;
    parent?: { code: string; publicSlug?: string | null; catalogRole?: string; i18n: string | null } | null;
  } | null;
};

export function ProductCard({ product, locale, label }: { product: Product; locale: string; label?: string }) {
  const content = tr<{ name: string; description?: string }>(product.i18n, locale);
  const seriesName = product.series
    ? catalogFamilyDisplayName(product.series as never, locale) || seriesDisplayName(product.series, locale)
    : '';
  const familySlug = product.series ? catalogFamilySlug(product.series as never) : null;
  const href = familySlug ? `/products/${familySlug}/${product.slug}` : '/products';
  const availableVariants = (product.variants || []).filter((variant) => variant.image);
  const showVariants = availableVariants.length > 1 || availableVariants.some((variant) => variant.swatchHex);
  const image = availableVariants[0]?.image || product.image;

  return (
    <article className="card-uten group flex h-full flex-col overflow-hidden">
      <Link href={href} className="relative block aspect-[16/11] overflow-hidden bg-[linear-gradient(145deg,hsl(var(--muted)),hsl(var(--card)))]">
        <div className="absolute inset-0 bg-dots opacity-35" />
        {image ? (
          <Image src={image} alt={content.name} fill sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw" className="product-cutout object-contain p-[18%] transition duration-300 group-hover:scale-[1.03]" />
        ) : (
          <span className="absolute inset-0 grid place-items-center text-6xl font-bold text-muted-foreground/20">U</span>
        )}
        {product.model && <span className="absolute start-4 top-4 rounded-full bg-card/88 px-2.5 py-1 text-[10px] font-bold uppercase tracking-[.13em] backdrop-blur">{product.model}</span>}
      </Link>
      <div className="flex flex-1 flex-col p-5 md:p-6">
        <p className="text-[10px] font-bold uppercase tracking-[.17em] text-accent">{seriesName || 'UTEN'}</p>
        <Link href={href} className="mt-2 text-xl font-semibold tracking-[-.03em] transition group-hover:text-accent">{content.name}</Link>
        {content.description && <p className="mt-2 line-clamp-2 text-sm leading-6 text-muted-foreground">{content.description}</p>}
        <div className="mt-auto flex items-end justify-between gap-4 pt-5">
          <div className="flex -space-x-1.5">
            {showVariants && availableVariants.slice(0, 4).map((variant) => (
              <span key={variant.id} title={tr<{ name: string }>(variant.i18n, locale).name} className="relative h-6 w-6 overflow-hidden rounded-full border-2 border-card bg-muted">
                {variant.swatchHex ? <span className="absolute inset-0" style={{ backgroundColor: variant.swatchHex }} /> : <Image src={variant.image!} alt="" fill sizes="24px" className="object-cover" />}
              </span>
            ))}
          </div>
          <span className="inline-flex min-h-11 items-center gap-1.5 text-sm font-semibold">{label || 'View'}<ArrowUpRight className="h-4 w-4 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5" /></span>
        </div>
      </div>
    </article>
  );
}
