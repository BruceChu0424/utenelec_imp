import Image from 'next/image';
import type { CatalogFamilyImage } from '@/lib/catalog';

const PRODUCT_LAYOUTS: Record<number, string[]> = {
  1: ['left-[24%] top-[14%] h-[72%] w-[52%]'],
  2: [
    'left-[9%] top-[18%] h-[66%] w-[43%] -rotate-2',
    'right-[9%] top-[18%] h-[66%] w-[43%] rotate-2',
  ],
  3: [
    'left-[3%] top-[24%] h-[58%] w-[36%] -rotate-2',
    'left-[32%] top-[12%] z-10 h-[74%] w-[36%]',
    'right-[3%] top-[24%] h-[58%] w-[36%] rotate-2',
  ],
  4: [
    'left-[1%] top-[27%] h-[54%] w-[30%] -rotate-2',
    'left-[23%] top-[14%] z-10 h-[70%] w-[32%] -rotate-1',
    'right-[23%] top-[14%] z-10 h-[70%] w-[32%] rotate-1',
    'right-[1%] top-[27%] h-[54%] w-[30%] rotate-2',
  ],
};

export function SeriesCollage({
  images,
  name,
  priority = false,
  className = '',
}: {
  images: CatalogFamilyImage[];
  name: string;
  priority?: boolean;
  className?: string;
}) {
  const visible = images.slice(0, 4);
  if (!visible.length) {
    return (
      <div className={`relative grid place-items-center overflow-hidden bg-[linear-gradient(145deg,hsl(var(--muted)),hsl(var(--card)))] ${className}`}>
        <div className="absolute inset-0 bg-dots opacity-35" />
        <span className="relative text-7xl font-bold text-muted-foreground/20" aria-hidden="true">U</span>
      </div>
    );
  }

  // A curated cover/combination image is authoritative. It already represents
  // the family and should not be split into a decorative thumbnail grid.
  const editorialCover = visible.find((item) => item.kind === 'editorial');
  if (editorialCover) {
    return (
      <div className={`relative overflow-hidden bg-muted ${className}`}>
        <Image
          src={editorialCover.src}
          alt={name}
          fill
          priority={priority}
          sizes="(max-width: 768px) 92vw, (max-width: 1200px) 48vw, 42vw"
          className="object-cover"
        />
      </div>
    );
  }

  // Until the CMS has a curated cover, compose several source-backed product
  // fronts on one shared canvas. This is a cover fallback, not extra gallery
  // media and not an invented product render.
  const products = visible.filter((item) => item.kind === 'product');
  const layout = PRODUCT_LAYOUTS[products.length] || PRODUCT_LAYOUTS[4];

  return (
    <div
      className={`relative isolate overflow-hidden bg-[linear-gradient(145deg,hsl(var(--background-elevated)),hsl(var(--card))_72%)] ${className}`}
      role="img"
      aria-label={name}
    >
      <div className="absolute inset-0 bg-dots opacity-30" />
      <div className="absolute left-1/2 top-1/2 h-[72%] w-[64%] -translate-x-1/2 -translate-y-1/2 rounded-full bg-accent/10 blur-3xl" />
      <div className="absolute inset-x-[7%] bottom-[8%] h-px bg-gradient-to-r from-transparent via-foreground/15 to-transparent" />
      {products.map((item, index) => (
        <div key={`${item.src}-${index}`} className={`absolute ${layout[index] || layout[layout.length - 1]}`}>
          <Image
            src={item.src}
            alt=""
            fill
            priority={priority && index === 0}
            sizes="(max-width: 768px) 38vw, (max-width: 1200px) 22vw, 18vw"
            className="product-cutout object-contain mix-blend-multiply"
          />
        </div>
      ))}
    </div>
  );
}
