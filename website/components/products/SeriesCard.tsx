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
  featured = false,
}: {
  family: CatalogFamilyView;
  labels: SeriesCardLabels;
  priority?: boolean;
  featured?: boolean;
}) {
  const countLabel = labels.products.replace('{count}', String(family.count));

  if (featured) {
    return (
      <article className="card-uten group overflow-hidden md:col-span-2">
        <Link
          href={`/products/${family.slug}`}
          className="grid h-full focus:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-4 md:grid-cols-[1.18fr_.82fr]"
        >
          <div className="relative min-h-[300px] overflow-hidden sm:min-h-[380px] md:min-h-[440px]">
            <div className="absolute inset-0 transition duration-700 ease-out group-hover:scale-[1.02]">
              <SeriesCollage images={family.images} name={family.name} priority={priority} className="h-full w-full" />
            </div>
          </div>
          <div className="flex flex-col justify-center p-7 sm:p-10 lg:p-12">
            <p className="inline-flex items-center gap-2 text-[11px] font-bold uppercase tracking-[.16em] text-accent">
              <Layers3 className="h-4 w-4" />
              {countLabel}
            </p>
            <h2 className="mt-5 text-balance text-3xl font-semibold leading-[1.06] tracking-[-.04em] sm:text-4xl lg:text-5xl">{family.name}</h2>
            {family.subtitle && <p className="mt-4 max-w-md text-pretty text-base leading-7 text-muted-foreground">{family.subtitle}</p>}
            <span className="mt-8 inline-flex min-h-11 w-fit items-center gap-2 rounded-full border border-foreground/20 px-6 text-sm font-semibold transition group-hover:border-accent group-hover:text-accent">
              {labels.explore}
              <ArrowUpRight className="h-4 w-4 transition duration-200 group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
            </span>
          </div>
        </Link>
      </article>
    );
  }

  return (
    <article className="card-uten group overflow-hidden">
      <Link href={`/products/${family.slug}`} className="block focus:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-4">
        <div className="overflow-hidden">
          <div className="transition duration-700 ease-out group-hover:scale-[1.02]">
            <SeriesCollage images={family.images} name={family.name} priority={priority} className="aspect-[16/10]" />
          </div>
        </div>
        <div className="p-6 sm:p-7">
          <div className="flex items-center justify-between gap-4">
            <p className="inline-flex items-center gap-2 text-[11px] font-bold uppercase tracking-[.16em] text-accent">
              <Layers3 className="h-4 w-4" />
              {countLabel}
            </p>
            <ArrowUpRight className="h-5 w-5 text-muted-foreground transition duration-200 group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-accent" />
          </div>
          <h2 className="mt-4 text-2xl font-semibold leading-tight tracking-[-.035em] sm:text-[1.75rem]">{family.name}</h2>
          {family.subtitle && <p className="mt-3 line-clamp-2 text-sm leading-6 text-muted-foreground">{family.subtitle}</p>}
          <span className="mt-6 inline-flex min-h-11 items-center text-sm font-semibold text-foreground transition group-hover:text-accent">
            {labels.explore}
          </span>
        </div>
      </Link>
    </article>
  );
}
