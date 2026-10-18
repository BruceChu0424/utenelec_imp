import Image from 'next/image';
import type { CatalogFamilyImage } from '@/lib/catalog';

export function SeriesCollage({ images, name, priority = false, className = '' }: { images: CatalogFamilyImage[]; name: string; priority?: boolean; className?: string }) {
  const visible = images.slice(0, 4);
  const editorial = visible.find(image => image.kind === 'editorial');
  if (editorial) return <div className={`relative bg-muted ${className}`}><Image src={editorial.src} alt={name} fill priority={priority} sizes="(max-width: 700px) 90vw, 48vw" className="object-contain p-4" /></div>;
  return <div className={`series-cover-products ${className}`}>{visible.length ? visible.map((image, index) => <div key={`${image.src}-${index}`}><Image src={image.src} alt={`${name} ${index + 1}`} fill priority={priority && index === 0} sizes="(max-width: 700px) 28vw, 180px" className="object-contain" /></div>) : <span aria-hidden="true">UTEN</span>}</div>;
}
