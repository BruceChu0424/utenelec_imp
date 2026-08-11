'use client';

import Image from 'next/image';
import { ArrowUpRight } from 'lucide-react';
import { useState } from 'react';
import { Link } from '@/i18n/navigation';
import type { CatalogProduct } from './ProductExplorer';

export type ProductMatrixCardLabels = {
  variants: string;
  viewDetail: string;
  gang: string;
  functionTypes: Record<string, string>;
};

function withVariant(href: string, variantId?: string): string {
  if (!variantId) return href;
  const separator = href.includes('?') ? '&' : '?';
  return `${href}${separator}variant=${encodeURIComponent(variantId)}`;
}

export function ProductMatrixCard({
  product,
  labels,
  locale,
}: {
  product: CatalogProduct;
  labels: ProductMatrixCardLabels;
  locale: string;
}) {
  const [variantId, setVariantId] = useState(product.variants[0]?.id || '');
  const variant = product.variants.find((item) => item.id === variantId) || product.variants[0];
  const image = variant?.image || product.image;
  const href = withVariant(product.href, variant?.id);
  const showVariantSelector = product.variants.length > 1 || product.variants.some((item) => item.swatchHex);
  const functionLabel = labels.functionTypes[product.functionType] || labels.functionTypes.other || product.functionType;

  return (
    <article className="card-uten group flex min-h-full flex-col overflow-hidden">
      <Link locale={locale} href={href} className="relative block aspect-[4/3] overflow-hidden bg-[linear-gradient(145deg,hsl(var(--muted)),hsl(var(--card)))]">
        <div className="absolute inset-0 bg-dots opacity-35" />
        {image ? (
          <Image
            src={image}
            alt={`${product.name}${variant?.name ? ` — ${variant.name}` : ''}`}
            fill
            sizes="(max-width: 640px) 50vw, (max-width: 1024px) 33vw, 25vw"
            className="product-cutout object-contain p-[16%] transition duration-300 group-hover:scale-[1.025] motion-reduce:transition-none"
          />
        ) : (
          <span className="absolute inset-0 grid place-items-center text-5xl font-bold text-muted-foreground/20" aria-hidden="true">U</span>
        )}
        {product.model && product.model.toLocaleLowerCase() !== product.name.toLocaleLowerCase() && (
          <span className="absolute start-3 top-3 rounded-full bg-card/88 px-2.5 py-1 text-[10px] font-bold uppercase tracking-[.12em] text-foreground backdrop-blur">
            {product.model}
          </span>
        )}
      </Link>

      <div className="flex flex-1 flex-col p-3.5 sm:p-5">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <p className="text-[10px] font-bold uppercase tracking-[.15em] text-accent">{functionLabel}</p>
          {product.gangCount && (
            <span className="rounded-full bg-muted px-2 py-1 text-[10px] font-bold text-muted-foreground">
              {labels.gang.replace('{count}', String(product.gangCount))}
            </span>
          )}
        </div>
        <Link locale={locale} href={href} className="mt-2 text-base font-semibold leading-snug tracking-[-.025em] transition group-hover:text-accent sm:text-lg">
          {product.name}
        </Link>
        {product.collectionName && product.collectionName !== product.seriesName && (
          <p className="mt-1 line-clamp-1 text-xs font-medium text-muted-foreground">{product.collectionName}</p>
        )}
        {product.description && <p className="mt-2 hidden line-clamp-2 text-sm leading-6 text-muted-foreground sm:block">{product.description}</p>}

        <div className="mt-auto pt-5">
          {showVariantSelector && (
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[.12em] text-muted-foreground">
                {product.variants.length} {labels.variants}
              </p>
              <div className="mt-2 flex flex-wrap gap-1.5">
                {product.variants.slice(0, 5).map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => setVariantId(item.id)}
                    aria-label={item.name}
                    aria-pressed={item.id === variant?.id}
                    title={item.name}
                    className={`relative h-11 w-11 cursor-pointer overflow-hidden rounded-full border-2 bg-muted transition ${item.id === variant?.id ? 'border-accent ring-4 ring-accent/10' : 'border-card hover:border-foreground/30'}`}
                  >
                    {item.swatchHex
                      ? <span className="absolute inset-1 rounded-full" style={{ backgroundColor: item.swatchHex }} />
                      : <Image src={item.image} alt="" fill sizes="44px" className="object-cover" />}
                  </button>
                ))}
                {product.variants.length > 5 && (
                  <span className="grid h-11 min-w-11 place-items-center rounded-full border border-border px-2 text-xs font-semibold text-muted-foreground">
                    +{product.variants.length - 5}
                  </span>
                )}
              </div>
            </div>
          )}
          <Link locale={locale} href={href} className="mt-4 inline-flex min-h-11 items-center gap-1.5 text-sm font-semibold text-foreground transition hover:text-accent">
            {labels.viewDetail}<ArrowUpRight className="h-4 w-4" />
          </Link>
        </div>
      </div>
    </article>
  );
}
