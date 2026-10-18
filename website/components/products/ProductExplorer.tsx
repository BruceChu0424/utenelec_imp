import { Search } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import type { ProductFunctionType } from '@/lib/product-taxonomy';
import { ProductMatrixCard, type ProductMatrixCardLabels } from './ProductMatrixCard';

export type CatalogVariant = { id: string; name: string; image: string; swatchHex?: string | null };
export type CatalogProduct = {
  id: string; name: string; model?: string | null; category?: string | null; description?: string;
  href: string; contactHref?: string; seriesCode?: string; seriesName?: string; collectionName?: string;
  image?: string | null; variants: CatalogVariant[]; functionType: ProductFunctionType; gangCount: number | null;
  controlMode?: string | null; configuration?: string | null; classificationStatus?: string;
};
export type ProductExplorerLabels = ProductMatrixCardLabels & {
  search: string; resultCount: string; empty: string; clear: string; filter: string; filterFunction: string;
  filterGang: string; allFunctions: string; allGangs: string; closeFilter: string; unspecified: string;
  previous: string; next: string; page: string; apply: string;
};

/** Native URL forms and links preserve state and work before hydration. */
export function ProductExplorer({ products, total, facets, page, pageSize, familySlug, labels, locale, initialQuery = '', initialFunction = null, initialGang = null }: {
  products: CatalogProduct[]; total: number;
  facets: { functions: Array<{ value: ProductFunctionType; count: number }>; gangs: Array<{ value: number; count: number }> };
  page: number; pageSize: number; familySlug: string; labels: ProductExplorerLabels; locale: string;
  initialQuery?: string; initialFunction?: ProductFunctionType | null; initialGang?: number | null;
}) {
  const path = `/products/${familySlug}`;
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const pageHref = (target: number) => {
    const params = new URLSearchParams();
    if (initialQuery) params.set('q', initialQuery);
    if (initialFunction) params.set('function', initialFunction);
    if (initialGang) params.set('gang', String(initialGang));
    if (target > 1) params.set('page', String(target));
    return `${path}${params.size ? `?${params}` : ''}#product-matrix`;
  };
  return <div className="catalog-workspace">
    <form action={`/${locale}${path}#product-matrix`} method="get" className="catalog-filters">
      <label className="catalog-search"><span>{labels.search}</span><div><Search size={18} aria-hidden="true" /><input name="q" type="search" defaultValue={initialQuery} maxLength={80} placeholder={labels.search} /></div></label>
      <label><span>{labels.filterFunction}</span><select name="function" defaultValue={initialFunction || ''}><option value="">{labels.allFunctions}</option>{facets.functions.map(item => <option key={item.value} value={item.value}>{labels.functionTypes[item.value]} ({item.count})</option>)}</select></label>
      <label><span>{labels.filterGang}</span><select name="gang" defaultValue={initialGang || ''}><option value="">{labels.allGangs}</option>{facets.gangs.map(item => <option key={item.value} value={item.value}>{labels.gang.replace('{count}', String(item.value))} ({item.count})</option>)}</select></label>
      <button type="submit" className="btn-primary">{labels.apply}</button>
      {(initialQuery || initialFunction || initialGang) && <Link locale={locale} href={path + '#product-matrix'} className="public-text-link">{labels.clear}</Link>}
    </form>
    <div><p className="catalog-result" role="status">{labels.resultCount.replace('{count}', String(total))}</p>
      {products.length ? <div className="catalog-product-grid">{products.map(product => <ProductMatrixCard key={product.id} product={product} labels={labels} locale={locale} />)}</div> : <div className="public-empty"><p>{labels.empty}</p><Link locale={locale} href={path} className="public-text-link">{labels.clear}</Link></div>}
      <nav className="catalog-pagination" aria-label={labels.page}>
        {page > 1 ? <Link locale={locale} href={pageHref(page - 1)} className="btn-outline" rel="prev">{labels.previous}</Link> : <span className="pagination-disabled">{labels.previous}</span>}
        <span>{page} / {pages}</span>
        {page < pages ? <Link locale={locale} href={pageHref(page + 1)} className="btn-outline" rel="next">{labels.next}</Link> : <span className="pagination-disabled">{labels.next}</span>}
      </nav>
    </div>
  </div>;
}
