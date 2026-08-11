'use client';

import Image from 'next/image';
import { ArrowUpRight, Box, Layers3, Ruler } from 'lucide-react';
import { useState } from 'react';
import { Link } from '@/i18n/navigation';

export type ViewerVariant = {
  id: string;
  name: string;
  image: string;
  gallery?: string[];
  swatchHex?: string | null;
  finish?: string | null;
  widthMm?: number | null;
  heightMm?: number | null;
  depthMm?: number | null;
};

export function VariantViewer({
  product,
  variants,
  labels,
  initialVariantId,
  locale,
}: {
  product: { name: string; model?: string | null; seriesName: string; description?: string; studioHref: string };
  variants: ViewerVariant[];
  labels: { variants: string; gallery: string; finish: string; dimensions: string; specsPending: string; tryOnWall: string; askAdvice: string; displayOnly: string };
  initialVariantId?: string;
  locale: string;
}) {
  const initialVariant = variants.find((item) => item.id === initialVariantId) || variants[0];
  const [variantId, setVariantId] = useState(initialVariant?.id || '');
  const [mediaPath, setMediaPath] = useState(initialVariant?.image || '');
  const variant = variants.find((item) => item.id === variantId) || variants[0];
  const mediaItems = variant
    ? Array.from(new Set([variant.image, ...(variant.gallery || [])].filter(Boolean)))
    : [];
  const activeMedia = mediaItems.includes(mediaPath) ? mediaPath : mediaItems[0];

  return (
    <div className="grid gap-9 lg:grid-cols-[minmax(0,1.06fr)_minmax(360px,.94fr)] lg:gap-14">
      <div>
        <div className="media-stage aspect-[4/3]">
          <div className="absolute inset-0 bg-dots opacity-40" />
          {activeMedia ? <Image key={`${variant?.id}-${activeMedia}`} src={activeMedia} alt={`${product.name} — ${variant?.name || ''}`} fill priority sizes="(max-width: 1024px) 100vw, 52vw" className="animate-scene-in product-cutout object-contain p-[19%] sm:p-[22%] lg:p-[24%]" /> : <span className="absolute inset-0 grid place-items-center text-8xl font-bold text-muted-foreground/18">U</span>}
          <span className="absolute bottom-5 start-5 rounded-full border border-border bg-card/85 px-3 py-1.5 text-[10px] font-bold uppercase tracking-[.15em] text-muted-foreground backdrop-blur">{labels.displayOnly}</span>
        </div>
        {mediaItems.length > 1 && (
          <div className="mt-4" aria-label={labels.gallery}>
            <p className="sr-only">{labels.gallery}</p>
            <div className="flex flex-wrap gap-2">
              {mediaItems.map((path, index) => (
                <button
                  key={path}
                  type="button"
                  onClick={() => setMediaPath(path)}
                  aria-label={`${labels.gallery} ${index + 1}`}
                  aria-pressed={path === activeMedia}
                  className={`relative h-16 w-16 overflow-hidden rounded-xl border bg-card transition ${path === activeMedia ? 'border-accent ring-4 ring-accent/10' : 'border-border hover:border-foreground/35'}`}
                >
                  <Image src={path} alt="" fill sizes="64px" className="object-contain p-2" />
                </button>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="lg:py-4">
        <p className="text-xs font-bold uppercase tracking-[.2em] text-accent">{product.seriesName}</p>
        <h1 className="mt-4 text-balance text-4xl font-semibold leading-[1.08] tracking-[-.045em] md:text-6xl">{product.name}</h1>
        {product.model && <p className="mt-4 font-mono text-sm font-semibold tracking-[.1em] text-muted-foreground">MODEL · {product.model}</p>}
        {product.description && <p className="mt-7 max-w-xl text-pretty text-base leading-8 text-muted-foreground">{product.description}</p>}

        {(variants.length > 1 || variants.some((item) => item.swatchHex || item.finish)) && (
          <fieldset className="mt-9 border-t border-border pt-6">
            <legend className="text-xs font-bold uppercase tracking-[.16em] text-muted-foreground">{labels.variants} · {variant?.name}</legend>
            <div className="mt-4 flex flex-wrap gap-2">
              {variants.map((item) => (
                <button key={item.id} type="button" onClick={() => {
                  setVariantId(item.id);
                  setMediaPath(item.image);
                  const url = new URL(window.location.href);
                  url.searchParams.set('variant', item.id);
                  window.history.replaceState(window.history.state, '', url);
                }} title={item.name} aria-label={item.name} aria-pressed={item.id === variant?.id} className={`relative h-12 w-12 cursor-pointer overflow-hidden rounded-full border-2 bg-muted transition ${item.id === variant?.id ? 'border-accent ring-4 ring-accent/10' : 'border-card hover:border-foreground/30'}`}>
                  {item.swatchHex ? <span className="absolute inset-1 rounded-full" style={{ backgroundColor: item.swatchHex }} /> : <Image src={item.image} alt="" fill sizes="48px" className="object-cover" />}
                </button>
              ))}
            </div>
          </fieldset>
        )}

        {(variant?.finish || (variant?.widthMm && variant?.heightMm)) && <dl className="mt-8 grid gap-3 sm:grid-cols-2">
          {variant?.finish && <div className="rounded-2xl border border-border bg-card p-4">
            <dt className="flex items-center gap-2 text-xs font-bold uppercase tracking-[.13em] text-muted-foreground"><Layers3 className="h-4 w-4 text-accent" />{labels.finish}</dt>
            <dd className="mt-2 text-sm font-semibold">{variant.finish}</dd>
          </div>}
          {variant?.widthMm && variant?.heightMm && <div className="rounded-2xl border border-border bg-card p-4">
            <dt className="flex items-center gap-2 text-xs font-bold uppercase tracking-[.13em] text-muted-foreground"><Ruler className="h-4 w-4 text-accent" />{labels.dimensions}</dt>
            <dd className="mt-2 text-sm font-semibold">{`${variant.widthMm} × ${variant.heightMm}${variant.depthMm ? ` × ${variant.depthMm}` : ''} mm`}</dd>
          </div>}
        </dl>}

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <Link locale={locale} href={`${product.studioHref}${variant ? `?variant=${encodeURIComponent(variant.id)}` : ''}`} className="btn-accent"><Box className="h-4 w-4" />{labels.tryOnWall}</Link>
          <Link locale={locale} href={`/contact?product=${encodeURIComponent(`${product.name}${variant ? ` · ${variant.name}` : ''}`)}`} className="btn-outline">{labels.askAdvice}<ArrowUpRight className="h-4 w-4" /></Link>
        </div>
      </div>
    </div>
  );
}
