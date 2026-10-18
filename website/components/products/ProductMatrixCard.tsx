import Image from 'next/image';
import { ArrowUpRight } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import type { CatalogProduct } from './ProductExplorer';

export type ProductMatrixCardLabels = { variants: string; viewDetail: string; gang: string; functionTypes: Record<string, string> };

export function ProductMatrixCard({ product, labels, locale }: { product: CatalogProduct; labels: ProductMatrixCardLabels; locale: string }) {
  const image = product.variants[0]?.image || product.image;
  return <article className="catalog-product-card">
    <Link locale={locale} href={product.href} className="catalog-product-image">
      {image ? <Image src={image} alt={product.name} fill sizes="(max-width: 640px) 44vw, (max-width: 1024px) 28vw, 22vw" className="object-contain" /> : <span aria-hidden="true">UTEN</span>}
    </Link>
    <p className="catalog-series-name">{product.seriesName}</p>
    <h3><Link locale={locale} href={product.href}>{product.name}</Link></h3>
    {product.model && product.model !== product.name && <p className="catalog-model">{product.model}</p>}
    <div className="catalog-card-footer"><span>{labels.functionTypes[product.functionType] || labels.functionTypes.other}</span><Link locale={locale} href={product.href} aria-label={`${labels.viewDetail}: ${product.name}`}><ArrowUpRight size={19} aria-hidden="true" /><span className="sr-only">{labels.viewDetail}</span></Link></div>
  </article>;
}
