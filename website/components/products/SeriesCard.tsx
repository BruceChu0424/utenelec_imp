import { ArrowUpRight } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import type { CatalogFamilyView } from '@/lib/catalog';
import { SeriesCollage } from './SeriesCollage';

export type SeriesCardLabels = { products: string; explore: string };
export function SeriesCard({ family, labels, locale, priority = false }: { family: CatalogFamilyView; labels: SeriesCardLabels; locale: string; priority?: boolean; featured?: boolean }) {
  return <article className="public-family-card"><Link locale={locale} href={`/products/${family.slug}`} className="public-family-image"><SeriesCollage images={family.images} name={family.name} priority={priority} className="h-full w-full" /></Link><div><p>{labels.products.replace('{count}', String(family.count))}</p><h2><Link locale={locale} href={`/products/${family.slug}`}>{family.name}</Link></h2>{family.subtitle && <p>{family.subtitle}</p>}<Link locale={locale} href={`/products/${family.slug}`} className="public-text-link">{labels.explore}<ArrowUpRight size={18} aria-hidden="true" /></Link></div></article>;
}
