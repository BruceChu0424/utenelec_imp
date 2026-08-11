import { cn } from '@/lib/utils';

export function SectionHeading({
  eyebrow, title, subtitle, center, className,
}: {
  eyebrow?: string; title: string; subtitle?: string; center?: boolean; className?: string;
}) {
  return (
    <div className={cn('max-w-2xl', center && 'mx-auto text-center', className)}>
      {eyebrow && <span className="eyebrow">{eyebrow}</span>}
      <h2 className="mt-3 text-balance font-heading text-3xl font-bold tracking-tight md:text-4xl">{title}</h2>
      {subtitle && <p className="mt-3 text-muted-foreground">{subtitle}</p>}
    </div>
  );
}
