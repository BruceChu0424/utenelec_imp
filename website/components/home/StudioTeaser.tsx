'use client';

import Image from 'next/image';
import { ArrowUpRight } from 'lucide-react';
import { useState } from 'react';
import { Link } from '@/i18n/navigation';

export type TeaserScene = { id: string; name: string; image: string };
export type TeaserVariant = { id: string; name: string; productName: string; image: string; swatchHex?: string | null };

export function StudioTeaser({
  scenes,
  variants,
  labels,
}: {
  scenes: TeaserScene[];
  variants: TeaserVariant[];
  labels: { scene: string; product: string; openStudio: string; preview: string };
}) {
  const [sceneId, setSceneId] = useState(scenes[0]?.id || '');
  const [variantId, setVariantId] = useState(variants[0]?.id || '');
  const scene = scenes.find((item) => item.id === sceneId) || scenes[0];
  const variant = variants.find((item) => item.id === variantId) || variants[0];

  if (!scene) return null;

  return (
    <div className="overflow-hidden rounded-[1.75rem] border border-border bg-card shadow-lg">
      <div className="relative aspect-[16/10] overflow-hidden bg-muted md:aspect-[16/8]">
        <Image key={scene.id} src={scene.image} alt={scene.name} fill sizes="(max-width: 1024px) 100vw, 70vw" className="animate-scene-in object-cover" />
        <div className="absolute inset-0 bg-gradient-to-t from-foreground/20 via-transparent to-transparent" />
        {variant?.image && (
          <div className="animate-float absolute left-1/2 top-[46%] h-[84px] w-[84px] -translate-x-1/2 -translate-y-1/2 md:h-[112px] md:w-[112px]">
            <Image src={variant.image} alt={`${variant.productName} — ${variant.name}`} fill sizes="112px" className="product-cutout rounded-lg object-contain" />
          </div>
        )}
        <p className="absolute bottom-4 start-5 rounded-full bg-foreground/72 px-3 py-1.5 text-[10px] font-bold uppercase tracking-[.15em] text-background backdrop-blur">{labels.preview}</p>
      </div>

      <div className="grid gap-6 p-5 md:grid-cols-[1fr_1fr_auto] md:items-end md:p-7">
        <fieldset>
          <legend className="text-xs font-bold uppercase tracking-[.16em] text-muted-foreground">{labels.scene}</legend>
          <div className="mt-3 flex flex-wrap gap-2">
            {scenes.map((item) => (
              <button key={item.id} type="button" onClick={() => setSceneId(item.id)} className={`min-h-10 rounded-full border px-4 text-sm font-semibold transition ${item.id === sceneId ? 'border-primary bg-primary text-primary-foreground' : 'border-border bg-card hover:border-foreground/35'}`}>
                {item.name}
              </button>
            ))}
          </div>
        </fieldset>

        <fieldset>
          <legend className="text-xs font-bold uppercase tracking-[.16em] text-muted-foreground">{labels.product}</legend>
          <div className="mt-3 flex gap-2 overflow-x-auto pb-1 no-scrollbar">
            {variants.slice(0, 7).map((item) => (
              <button key={item.id} type="button" onClick={() => setVariantId(item.id)} title={`${item.productName} ${item.name}`} className={`relative h-10 w-10 shrink-0 overflow-hidden rounded-full border-2 bg-muted transition ${item.id === variantId ? 'border-accent ring-4 ring-accent/10' : 'border-card hover:border-foreground/30'}`}>
                {item.swatchHex ? <span className="absolute inset-1 rounded-full" style={{ backgroundColor: item.swatchHex }} /> : <Image src={item.image} alt="" fill sizes="40px" className="object-cover" />}
              </button>
            ))}
          </div>
        </fieldset>

        <Link href="/studio" className="btn-primary whitespace-nowrap">{labels.openStudio}<ArrowUpRight className="h-4 w-4" /></Link>
      </div>
    </div>
  );
}
