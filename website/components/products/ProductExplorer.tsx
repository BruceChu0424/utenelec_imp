'use client';

import { Search, SlidersHorizontal, X } from 'lucide-react';
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { usePathname, useRouter } from '@/i18n/navigation';
import { PRODUCT_FUNCTION_TYPES, type ProductFunctionType } from '@/lib/product-taxonomy';
import { ProductMatrixCard, type ProductMatrixCardLabels } from './ProductMatrixCard';

export type CatalogVariant = {
  id: string;
  name: string;
  image: string;
  swatchHex?: string | null;
};

export type CatalogProduct = {
  id: string;
  name: string;
  model?: string | null;
  category?: string | null;
  description?: string;
  href: string;
  seriesCode?: string;
  seriesName?: string;
  collectionName?: string;
  image?: string | null;
  variants: CatalogVariant[];
  functionType: ProductFunctionType;
  gangCount: number | null;
  controlMode?: string | null;
  configuration?: string | null;
  classificationStatus?: string;
};

export type ProductExplorerLabels = ProductMatrixCardLabels & {
  search: string;
  resultCount: string;
  empty: string;
  clear: string;
  filter: string;
  filterFunction: string;
  filterGang: string;
  allFunctions: string;
  allGangs: string;
  closeFilter: string;
  unspecified: string;
};

function normalizeSearch(value: string): string {
  return value.normalize('NFKC').toLocaleLowerCase().trim();
}

export function ProductExplorer({
  products,
  labels,
  locale,
  initialQuery = '',
  initialFunction = null,
  initialGang = null,
}: {
  products: CatalogProduct[];
  labels: ProductExplorerLabels;
  locale: string;
  initialQuery?: string;
  initialFunction?: ProductFunctionType | null;
  initialGang?: number | null;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const [query, setQuery] = useState(initialQuery);
  const [functionType, setFunctionType] = useState<ProductFunctionType | null>(initialFunction);
  const [gangCount, setGangCount] = useState<number | null>(initialGang);
  const [mobileFilters, setMobileFilters] = useState(false);
  const firstUrlSync = useRef(true);
  const filterTriggerRef = useRef<HTMLButtonElement>(null);
  const filterDialogRef = useRef<HTMLDivElement>(null);
  const filterCloseRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const filterDialogTitleId = useId();
  const filterDialogId = `${filterDialogTitleId}-dialog`;

  const functionOptions = useMemo(() => {
    const counts = new Map<ProductFunctionType, number>();
    for (const product of products) counts.set(product.functionType, (counts.get(product.functionType) || 0) + 1);
    return PRODUCT_FUNCTION_TYPES
      .map((value) => ({ value, count: counts.get(value) || 0 }))
      .filter((item) => item.count > 0);
  }, [products]);
  const gangOptions = useMemo(() => {
    const counts = new Map<number, number>();
    for (const product of products) {
      if (product.gangCount) counts.set(product.gangCount, (counts.get(product.gangCount) || 0) + 1);
    }
    return Array.from(counts, ([value, count]) => ({ value, count })).sort((a, b) => a.value - b.value);
  }, [products]);

  const filtered = useMemo(() => {
    const normalizedQuery = normalizeSearch(query);
    return products
      .filter((product) => !functionType || product.functionType === functionType)
      .filter((product) => !gangCount || product.gangCount === gangCount)
      .filter((product) => {
        if (!normalizedQuery) return true;
        return normalizeSearch([
          product.name,
          product.model,
          product.description,
          product.seriesName,
          product.collectionName,
          ...product.variants.map((variant) => variant.name),
        ].filter(Boolean).join(' ')).includes(normalizedQuery);
      })
      .sort((left, right) => {
        const functionOrder = PRODUCT_FUNCTION_TYPES.indexOf(left.functionType) - PRODUCT_FUNCTION_TYPES.indexOf(right.functionType);
        if (functionOrder) return functionOrder;
        const leftGang = left.gangCount ?? Number.MAX_SAFE_INTEGER;
        const rightGang = right.gangCount ?? Number.MAX_SAFE_INTEGER;
        if (leftGang !== rightGang) return leftGang - rightGang;
        return (left.model || left.name).localeCompare(right.model || right.name, locale, { numeric: true });
      });
  }, [functionType, gangCount, locale, products, query]);

  const grouped = useMemo(() => {
    const groups = new Map<ProductFunctionType, CatalogProduct[]>();
    for (const product of filtered) {
      const current = groups.get(product.functionType) || [];
      current.push(product);
      groups.set(product.functionType, current);
    }
    return PRODUCT_FUNCTION_TYPES.flatMap((value) => {
      const items = groups.get(value);
      return items?.length ? [{ value, items }] : [];
    });
  }, [filtered]);

  useEffect(() => {
    if (firstUrlSync.current) {
      firstUrlSync.current = false;
      return;
    }
    const timer = window.setTimeout(() => {
      const params = new URLSearchParams(window.location.search);
      if (query.trim()) params.set('q', query.trim()); else params.delete('q');
      if (functionType) params.set('function', functionType); else params.delete('function');
      if (gangCount) params.set('gang', String(gangCount)); else params.delete('gang');
      const suffix = params.toString();
      router.replace(`${pathname}${suffix ? `?${suffix}` : ''}`, { scroll: false });
    }, 220);
    return () => window.clearTimeout(timer);
  }, [functionType, gangCount, pathname, query, router]);

  useEffect(() => {
    if (!mobileFilters) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const focusFrame = window.requestAnimationFrame(() => filterCloseRef.current?.focus());
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        setMobileFilters(false);
        return;
      }
      if (event.key !== 'Tab') return;
      const focusable = Array.from(
        filterDialogRef.current?.querySelectorAll<HTMLElement>(
          'button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ) || [],
      ).filter((element) => element.getClientRects().length > 0);
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.removeEventListener('keydown', handleKeyDown);
      document.body.style.overflow = previousOverflow;
      window.requestAnimationFrame(() => returnFocusRef.current?.focus());
    };
  }, [mobileFilters]);

  const clearFilters = () => {
    setFunctionType(null);
    setGangCount(null);
  };
  const openFilters = () => {
    returnFocusRef.current = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : filterTriggerRef.current;
    setMobileFilters(true);
  };

  const filterControls = (
    <div className="grid gap-6">
      <fieldset>
        <legend className="text-xs font-bold uppercase tracking-[.15em] text-muted-foreground">{labels.filterFunction}</legend>
        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" aria-pressed={!functionType} onClick={() => setFunctionType(null)} className={`min-h-11 rounded-full border px-4 text-sm font-semibold transition ${!functionType ? 'border-primary bg-primary text-primary-foreground' : 'border-border bg-card hover:border-foreground/35'}`}>{labels.allFunctions}</button>
          {functionOptions.map((option) => (
            <button key={option.value} type="button" aria-pressed={functionType === option.value} onClick={() => setFunctionType(option.value)} className={`min-h-11 rounded-full border px-4 text-sm font-semibold transition ${functionType === option.value ? 'border-primary bg-primary text-primary-foreground' : 'border-border bg-card hover:border-foreground/35'}`}>
              {labels.functionTypes[option.value] || option.value}<span className="ms-2 text-xs opacity-60">{option.count}</span>
            </button>
          ))}
        </div>
      </fieldset>
      {gangOptions.length > 0 && (
        <fieldset>
          <legend className="text-xs font-bold uppercase tracking-[.15em] text-muted-foreground">{labels.filterGang}</legend>
          <div className="mt-3 flex flex-wrap gap-2">
            <button type="button" aria-pressed={!gangCount} onClick={() => setGangCount(null)} className={`min-h-11 rounded-full border px-4 text-sm font-semibold transition ${!gangCount ? 'border-primary bg-primary text-primary-foreground' : 'border-border bg-card hover:border-foreground/35'}`}>{labels.allGangs}</button>
            {gangOptions.map((option) => (
              <button key={option.value} type="button" aria-pressed={gangCount === option.value} onClick={() => setGangCount(option.value)} className={`min-h-11 rounded-full border px-4 text-sm font-semibold transition ${gangCount === option.value ? 'border-primary bg-primary text-primary-foreground' : 'border-border bg-card hover:border-foreground/35'}`}>
                {labels.gang.replace('{count}', String(option.value))}<span className="ms-2 text-xs opacity-60">{option.count}</span>
              </button>
            ))}
          </div>
        </fieldset>
      )}
    </div>
  );

  return (
    <div>
      <div className="sticky top-16 z-30 -mx-4 border-y border-border bg-background/95 px-4 py-4 backdrop-blur sm:mx-0 sm:rounded-2xl sm:border lg:top-20 lg:px-5">
        <div className="flex gap-3">
          <label className="relative block min-w-0 flex-1">
            <span className="sr-only">{labels.search}</span>
            <Search className="pointer-events-none absolute start-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={labels.search} className="input-uten ps-11 pe-11" />
            {query && <button type="button" onClick={() => setQuery('')} aria-label={labels.clear} className="absolute end-1.5 top-1/2 grid h-9 w-9 -translate-y-1/2 cursor-pointer place-items-center rounded-full hover:bg-muted"><X className="h-4 w-4" /></button>}
          </label>
          <button ref={filterTriggerRef} type="button" onClick={openFilters} aria-haspopup="dialog" aria-expanded={mobileFilters} aria-controls={filterDialogId} className="btn-outline lg:hidden">
            <SlidersHorizontal className="h-4 w-4" />{labels.filter}
          </button>
        </div>
        <div className="mt-4 hidden lg:block">{filterControls}</div>
      </div>

      <div className="mb-7 mt-6 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm font-semibold text-muted-foreground" aria-live="polite">{labels.resultCount.replace('{count}', String(filtered.length))}</p>
        {(functionType || gangCount) && <button type="button" onClick={clearFilters} className="min-h-11 cursor-pointer text-sm font-semibold text-accent hover:underline">{labels.clear}</button>}
      </div>

      {grouped.length ? (
        <div className="space-y-14 md:space-y-20">
          {grouped.map((group) => (
            <section key={group.value} aria-labelledby={`function-${group.value}`}>
              <div className="mb-6 flex items-end justify-between gap-4 border-b border-border pb-4">
                <h2 id={`function-${group.value}`} className="text-2xl font-semibold tracking-[-.035em] md:text-3xl">
                  {labels.functionTypes[group.value] || group.value}
                </h2>
                <span className="text-sm font-semibold text-muted-foreground">{group.items.length}</span>
              </div>
              <div className="grid grid-cols-2 gap-3 sm:gap-5 lg:grid-cols-3 xl:grid-cols-4">
                {group.items.map((product) => <ProductMatrixCard key={product.id} product={product} labels={labels} locale={locale} />)}
              </div>
            </section>
          ))}
        </div>
      ) : (
        <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-24 text-center text-muted-foreground">{labels.empty}</div>
      )}

      {mobileFilters && createPortal(
        <div className="fixed inset-0 z-[120] flex items-end bg-foreground/50 p-3 backdrop-blur-sm lg:hidden" onClick={() => setMobileFilters(false)}>
          <div ref={filterDialogRef} id={filterDialogId} tabIndex={-1} className="max-h-[82dvh] w-full overflow-y-auto rounded-[1.5rem] bg-background p-4 shadow-lg" role="dialog" aria-modal="true" aria-labelledby={filterDialogTitleId} onClick={(event) => event.stopPropagation()}>
            <div className="mb-5 flex items-center justify-between">
              <h2 id={filterDialogTitleId} className="text-lg font-semibold">{labels.filter}</h2>
              <button ref={filterCloseRef} type="button" onClick={() => setMobileFilters(false)} aria-label={labels.closeFilter} className="grid h-11 w-11 cursor-pointer place-items-center rounded-full hover:bg-muted"><X className="h-5 w-5" /></button>
            </div>
            {filterControls}
            <button type="button" onClick={() => setMobileFilters(false)} className="btn-accent mt-7 w-full">
              {labels.resultCount.replace('{count}', String(filtered.length))}
            </button>
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
