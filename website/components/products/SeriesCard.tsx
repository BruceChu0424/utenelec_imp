import { ArrowUpRight, Layers3 } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import type { CatalogFamilyView } from '@/lib/catalog';
import { SeriesCollage } from './SeriesCollage';

export type SeriesCardLabels = {
  products: string;
  explore: string;
};

export function SeriesCard({
  family,
  labels,
  priority = false,
}: {
  family: CatalogFamilyView;
  labels: SeriesCardLabels;
  priority?: boolean;
}) {
  const countLabel = labels.products.replace('{count}', String(family.count));
  return (
    <article className="card-uten group overflow-hidden">
      <Link href={`/products/${family.slug}`} className="block focus:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-4">
        <SeriesCollage images={family.images} name={family.name} priority={priority} className="aspect-[16/11]" />
        <div className="p-5 sm:p-6">
          <div className="flex items-center justify-between gap-4">
            <p className="inline-flex items-center gap-2 text-[11px] font-bold uppercase tracking-[.16em] text-accent">
              <Layers3 className="h-4 w-4" />
              {countLabel}
            </p>
            <ArrowUpRight className="h-5 w-5 text-muted-foreground transition duration-200 group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-accent" />
          </div>
          <h2 className="mt-4 text-2xl font-semibold leading-tight tracking-[-.035em] sm:text-3xl">{family.name}</h2>
          {family.subtitle && <p className="mt-3 text-sm leading-6 text-muted-foreground">{family.subtitle}</p>}
          {family.collections.length > 0 && (
            <div className="mt-5 flex flex-wrap gap-2" aria-label={family.name}>
              {family.collections.slice(0, 4).map((collection) => (
                <span key={collection.id} className="rounded-full border border-border bg-background-elevated px-3 py-1.5 text-xs font-semibold text-muted-foreground">
                  {collection.name}
                </span>
              ))}
              {family.collections.length > 4 && (
                <span className="rounded-full border border-border px-3 py-1.5 text-xs font-semibold text-muted-foreground">
                  +{family.collections.length - 4}
                </span>
              )}
            </div>
          )}
          <span className="mt-6 inline-flex min-h-11 items-center text-sm font-semibold text-foreground transition group-hover:text-accent">
            {labels.explore}
          </span>
        </div>
      </Link>
    </article>
  );
}
