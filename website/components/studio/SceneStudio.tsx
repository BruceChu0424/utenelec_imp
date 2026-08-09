'use client';

import Image from 'next/image';
import { ArrowUpRight, Check, Grip, Minus, Plus, RotateCcw, Search } from 'lucide-react';
import { useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react';
import { Link } from '@/i18n/navigation';
import {
  STUDIO_PLACEMENT_LIMITS,
  clampStudioValue,
  normalizeStudioPlacement,
} from '@/lib/studio-config';

export type StudioScene = {
  id: string;
  slug: string;
  name: string;
  description?: string;
  image: string;
  placement: { x: number; y: number; scale: number; rotation: number };
  defaultVariantId?: string | null;
};

export type StudioVariant = {
  id: string;
  name: string;
  productName: string;
  model?: string | null;
  image: string;
  swatchHex?: string | null;
  finish?: string | null;
  widthMm?: number | null;
  heightMm?: number | null;
  seriesName?: string;
  legacySynthetic?: boolean;
  productHref: string;
};

type Labels = {
  scenes: string;
  products: string;
  search: string;
  scale: string;
  reset: string;
  dragHint: string;
  keyboardHint: string;
  selected: string;
  dimensions: string;
  finish: string;
  viewProduct: string;
  askAdvice: string;
  disclaimer: string;
  noProducts: string;
  noScenes?: string;
};

function hasConcreteVariantPresentation(variant: StudioVariant): boolean {
  return !variant.legacySynthetic && Boolean(
    variant.swatchHex
    || variant.finish
    || (variant.widthMm && variant.heightMm),
  );
}

function studioVariantTitle(variant: StudioVariant): string {
  return hasConcreteVariantPresentation(variant) && variant.name && variant.name !== variant.productName
    ? `${variant.productName} · ${variant.name}`
    : variant.productName;
}

function studioVariantDetails(variant: StudioVariant): string[] {
  if (variant.legacySynthetic) return [];
  const details: string[] = [];
  if (hasConcreteVariantPresentation(variant) && variant.name !== variant.productName) details.push(variant.name);
  if (variant.model && variant.model !== variant.productName && variant.model !== variant.name) details.push(variant.model);
  return details;
}

export function SceneStudio({
  scenes,
  variants,
  labels,
  initialVariantId,
}: {
  scenes: StudioScene[];
  variants: StudioVariant[];
  labels: Labels;
  initialVariantId?: string;
}) {
  const stageRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<{ pointerId: number; offsetX: number; offsetY: number } | null>(null);
  const initialScene = scenes[0];
  const initialPlacement = normalizeStudioPlacement(initialScene?.placement);
  const [sceneId, setSceneId] = useState(scenes[0]?.id || '');
  const [variantId, setVariantId] = useState(
    variants.some((item) => item.id === initialVariantId)
      ? initialVariantId!
      : variants.some((item) => item.id === initialScene?.defaultVariantId)
        ? initialScene!.defaultVariantId!
        : variants[0]?.id || '',
  );
  const [position, setPosition] = useState({
    x: initialPlacement.x,
    y: initialPlacement.y,
  });
  const [scale, setScale] = useState(initialPlacement.scale);
  const [rotation, setRotation] = useState(initialPlacement.rotation);
  const [query, setQuery] = useState('');

  const scene = scenes.find((item) => item.id === sceneId) || scenes[0];
  const variant = variants.find((item) => item.id === variantId) || variants[0];
  const variantGroups = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    const matches = normalized
      ? variants.filter((item) => `${item.productName} ${item.name} ${item.model || ''} ${item.seriesName || ''}`.toLocaleLowerCase().includes(normalized))
      : variants;
    const groups = new Map<string, StudioVariant[]>();
    for (const item of matches) {
      const groupName = item.seriesName?.trim() || '';
      groups.set(groupName, [...(groups.get(groupName) || []), item]);
    }
    return Array.from(groups, ([name, items]) => ({ name, items }));
  }, [query, variants]);

  const reset = () => {
    const next = normalizeStudioPlacement(scene?.placement);
    setPosition({ x: next.x, y: next.y });
    setScale(next.scale);
    setRotation(next.rotation);
  };

  const activateScene = (nextScene: StudioScene) => {
    const nextPlacement = normalizeStudioPlacement(nextScene.placement);
    setSceneId(nextScene.id);
    setPosition({ x: nextPlacement.x, y: nextPlacement.y });
    setScale(nextPlacement.scale);
    setRotation(nextPlacement.rotation);
    if (nextScene.defaultVariantId && variants.some((item) => item.id === nextScene.defaultVariantId)) {
      setVariantId(nextScene.defaultVariantId);
    }
  };

  const updatePosition = (clientX: number, clientY: number, offsetX = 0, offsetY = 0) => {
    const stage = stageRef.current;
    if (!stage) return;
    const box = stage.getBoundingClientRect();
    const x = ((clientX - box.left - offsetX) / box.width) * 100;
    const y = ((clientY - box.top - offsetY) / box.height) * 100;
    setPosition({ x: clampStudioValue('x', x), y: clampStudioValue('y', y) });
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const target = event.currentTarget;
    const box = target.getBoundingClientRect();
    dragRef.current = {
      pointerId: event.pointerId,
      offsetX: event.clientX - (box.left + box.width / 2),
      offsetY: event.clientY - (box.top + box.height / 2),
    };
    target.setPointerCapture(event.pointerId);
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (!dragRef.current || dragRef.current.pointerId !== event.pointerId) return;
    updatePosition(event.clientX, event.clientY, dragRef.current.offsetX, dragRef.current.offsetY);
  };

  const onPointerEnd = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (dragRef.current?.pointerId === event.pointerId) dragRef.current = null;
  };

  if (!scene) {
    return (
      <div role="status" className="rounded-[1.75rem] border border-dashed border-border bg-card px-6 py-20 text-center">
        <p className="text-xs font-bold uppercase tracking-[.18em] text-accent">{labels.scenes}</p>
        <p className="mt-3 text-sm text-muted-foreground">{labels.noScenes || `${labels.scenes}: ${labels.noProducts}`}</p>
      </div>
    );
  }

  const overlaySize = `clamp(${Math.max(48, 56 * scale)}px, ${16 * scale}vw, ${96 * scale}px)`;

  return (
    <div className="grid overflow-hidden rounded-[1.75rem] border border-border bg-card shadow-lg xl:grid-cols-[minmax(0,1fr)_390px]">
      <div className="relative min-w-0 bg-foreground">
        <div ref={stageRef} className="relative aspect-[4/3] w-full overflow-hidden sm:aspect-[16/10] xl:aspect-auto xl:h-full xl:min-h-[720px]">
          <Image key={scene.id} src={scene.image} alt={scene.name} fill priority sizes="(max-width: 1280px) 100vw, 72vw" className="animate-scene-in select-none object-cover" draggable={false} />
          <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/20 via-transparent to-black/5" />

          {variant?.image && (
            <button
              type="button"
              aria-label={`${labels.dragHint}: ${studioVariantTitle(variant)}`}
              title={labels.keyboardHint}
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerEnd}
              onPointerCancel={onPointerEnd}
              onKeyDown={(event) => {
                if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
                event.preventDefault();
                const step = event.shiftKey ? 2 : .5;
                if (event.key === 'ArrowLeft') setPosition((p) => ({ ...p, x: clampStudioValue('x', p.x - step) }));
                if (event.key === 'ArrowRight') setPosition((p) => ({ ...p, x: clampStudioValue('x', p.x + step) }));
                if (event.key === 'ArrowUp') setPosition((p) => ({ ...p, y: clampStudioValue('y', p.y - step) }));
                if (event.key === 'ArrowDown') setPosition((p) => ({ ...p, y: clampStudioValue('y', p.y + step) }));
              }}
              className="group absolute z-10 grid touch-none place-items-center rounded-xl focus-visible:outline-white"
              style={{
                left: `${position.x}%`,
                top: `${position.y}%`,
                width: overlaySize,
                height: overlaySize,
                transform: `translate(-50%, -50%) rotate(${rotation}deg)`,
              }}
            >
              <span className="absolute -inset-3 rounded-2xl border border-white/0 transition group-hover:border-white/65 group-focus:border-white/65" />
              <Image src={variant.image} alt="" fill sizes="140px" draggable={false} className="product-cutout pointer-events-none select-none rounded-[10%] object-contain" />
              <span className="pointer-events-none absolute -top-8 left-1/2 hidden -translate-x-1/2 items-center gap-1 rounded-full bg-black/70 px-2.5 py-1 text-[10px] font-semibold text-white backdrop-blur group-hover:inline-flex group-focus:inline-flex">
                <Grip className="h-3 w-3" /> {labels.dragHint}
              </span>
            </button>
          )}

          <div className="glass absolute bottom-4 inset-x-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl px-4 py-3 text-xs sm:end-auto sm:start-5 sm:max-w-lg">
            <span className="font-semibold text-foreground">{scene.name}</span>
            <span className="text-muted-foreground">{labels.disclaimer}</span>
          </div>
        </div>
      </div>

      <aside className="flex min-h-0 flex-col border-t border-border bg-background xl:max-h-[780px] xl:border-s xl:border-t-0">
        <div className="border-b border-border p-5">
          <p className="text-xs font-bold uppercase tracking-[.18em] text-muted-foreground">01 · {labels.scenes}</p>
          <div className="mt-3 grid grid-cols-3 gap-2">
            {scenes.map((item) => (
              <button key={item.id} type="button" aria-pressed={item.id === sceneId} onClick={() => activateScene(item)} className={`group overflow-hidden rounded-xl border text-start transition ${item.id === sceneId ? 'border-accent ring-4 ring-accent/10' : 'border-border hover:border-foreground/30'}`}>
                <span className="relative block aspect-[4/3] overflow-hidden bg-muted">
                  <Image src={item.image} alt="" fill sizes="120px" className="object-cover transition duration-300 group-hover:scale-105" />
                  {item.id === sceneId && <span className="absolute end-1.5 top-1.5 grid h-5 w-5 place-items-center rounded-full bg-accent text-white"><Check className="h-3 w-3" /></span>}
                </span>
                <span className="block truncate px-2 py-1.5 text-[11px] font-semibold">{item.name}</span>
              </button>
            ))}
          </div>
        </div>

        <div className="border-b border-border p-5">
          <div className="flex items-center justify-between gap-4">
            <p className="text-xs font-bold uppercase tracking-[.18em] text-muted-foreground">02 · {labels.scale}</p>
            <button type="button" onClick={reset} className="inline-flex min-h-10 items-center gap-1.5 rounded-full px-3 text-xs font-semibold text-muted-foreground hover:bg-muted hover:text-foreground"><RotateCcw className="h-3.5 w-3.5" />{labels.reset}</button>
          </div>
          <div className="mt-2 flex items-center gap-3">
            <Minus className="h-4 w-4 text-muted-foreground" />
            <input aria-label={labels.scale} type="range" min={STUDIO_PLACEMENT_LIMITS.scale.min} max={STUDIO_PLACEMENT_LIMITS.scale.max} step="0.05" value={scale} onChange={(event) => setScale(clampStudioValue('scale', Number(event.target.value)))} className="h-11 w-full accent-[hsl(var(--accent))]" />
            <Plus className="h-4 w-4 text-muted-foreground" />
          </div>
        </div>

        <div className="flex min-h-0 flex-1 flex-col p-5">
          <p className="text-xs font-bold uppercase tracking-[.18em] text-muted-foreground">03 · {labels.products}</p>
          <label className="relative mt-3 block">
            <Search className="pointer-events-none absolute start-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <span className="sr-only">{labels.search}</span>
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={labels.search} className="input-uten ps-10" />
          </label>

          <div className="mt-3 grid max-h-[270px] gap-5 overflow-y-auto pe-1 xl:max-h-none xl:flex-1">
            {variantGroups.length ? variantGroups.map((group) => (
              <section key={group.name || 'other'} aria-label={group.name || labels.products} className="grid gap-2">
                {group.name && (
                  <p className="sticky top-0 z-10 bg-background/95 py-1 text-[10px] font-bold uppercase tracking-[.15em] text-accent backdrop-blur">
                    {group.name}
                  </p>
                )}
                {group.items.map((item) => {
                  const details = studioVariantDetails(item);
                  return (
                    <button key={item.id} type="button" aria-pressed={item.id === variantId} onClick={() => setVariantId(item.id)} className={`grid min-h-[68px] grid-cols-[54px_1fr_auto] items-center gap-3 rounded-xl border p-2 text-start transition ${item.id === variantId ? 'border-accent bg-accent/5' : 'border-border bg-card hover:border-foreground/25'}`}>
                      <span className="relative block h-[52px] w-[52px] overflow-hidden rounded-lg bg-muted">
                        <Image src={item.image} alt="" fill sizes="52px" className="object-contain p-1" />
                      </span>
                      <span className="min-w-0">
                        <span className="block truncate text-sm font-semibold">{item.productName}</span>
                        {details.length > 0 && <span className="mt-1 block truncate text-xs text-muted-foreground">{details.join(' · ')}</span>}
                      </span>
                      {!item.legacySynthetic && item.swatchHex && <span className="h-5 w-5 rounded-full border border-foreground/15" style={{ backgroundColor: item.swatchHex }} />}
                    </button>
                  );
                })}
              </section>
            )) : <p className="py-8 text-center text-sm text-muted-foreground">{labels.noProducts}</p>}
          </div>
        </div>

        {variant && (
          <div className="border-t border-border bg-card p-5">
            <p className="text-[10px] font-bold uppercase tracking-[.18em] text-accent">{labels.selected}</p>
            <div className="mt-2 flex items-start justify-between gap-4">
              <div>
                <p className="font-semibold">{studioVariantTitle(variant)}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {!variant.legacySynthetic && variant.widthMm && variant.heightMm ? `${labels.dimensions}: ${variant.widthMm} × ${variant.heightMm} mm` : variant.seriesName}
                  {!variant.legacySynthetic && variant.finish ? ` · ${labels.finish}: ${variant.finish}` : ''}
                </p>
              </div>
            </div>
            <div className="mt-4 grid grid-cols-2 gap-2">
              <Link href={variant.productHref} className="btn-outline btn-sm">{labels.viewProduct}</Link>
              <Link href={`/contact?product=${encodeURIComponent(studioVariantTitle(variant))}`} className="btn-primary btn-sm">{labels.askAdvice}<ArrowUpRight className="h-3.5 w-3.5" /></Link>
            </div>
          </div>
        )}
      </aside>
    </div>
  );
}
