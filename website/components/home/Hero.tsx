import Image from 'next/image';
import { ArrowDownRight, ArrowUpRight, MoveUpRight } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import { Reveal } from '@/components/motion/Reveal';

type HeroData = { title: string; subtitle: string; cta1: string; cta2: string };
type Featured = { image: string; name: string; series?: string; href: string } | null;
type HeroLabels = {
  eyebrow: string;
  experience: string;
  collections: string;
  global: string;
  featured: string;
};

export function Hero({
  hero,
  featured,
  labels,
  collectionCount,
}: {
  hero: HeroData;
  featured: Featured;
  labels: HeroLabels;
  collectionCount: number;
}) {
  const titleParts = hero.title.split(/\s*[·•]\s*/).filter(Boolean);

  return (
    <section className="relative isolate min-h-[640px] overflow-hidden border-b border-border/70 lg:min-h-[720px]">
      <div className="absolute inset-0 bg-grid opacity-50" />
      <div className="absolute inset-0 bg-[radial-gradient(circle_at_78%_25%,hsl(var(--accent)/.16),transparent_28%),linear-gradient(115deg,hsl(var(--background)),hsl(var(--background-elevated)/.72))]" />
      <div className="absolute -right-[12vw] top-[-26vw] h-[62vw] w-[62vw] rounded-full border border-foreground/[.065]" />
      <div className="absolute -right-[4vw] top-[-18vw] h-[46vw] w-[46vw] rounded-full border border-foreground/[.08]" />

      <div className="container-uten relative grid min-h-[640px] items-center gap-10 py-14 lg:min-h-[720px] lg:grid-cols-[1.12fr_.88fr] lg:gap-8 lg:py-16">
        <div className="relative z-10">
          <Reveal><p className="eyebrow">{labels.eyebrow}</p></Reveal>
          <Reveal delay={90}>
            <h1 className="display-title mt-7 max-w-[10.5ch]" aria-label={hero.title}>
              {titleParts.length === 2 ? (
                <span aria-hidden="true"><span className="block">{titleParts[0]} ·</span><span className="block">{titleParts[1]}</span></span>
              ) : hero.title}
            </h1>
          </Reveal>
          <Reveal delay={170}>
            <p className="mt-6 max-w-xl text-pretty text-base leading-8 text-muted-foreground md:text-lg">{hero.subtitle}</p>
          </Reveal>
          <Reveal delay={250}>
            <div className="mt-7 flex flex-wrap gap-3">
              <Link href="/products" className="btn-primary">{hero.cta1}<ArrowUpRight className="h-4 w-4" /></Link>
              <Link href="/contact" className="btn-outline">{hero.cta2}<MoveUpRight className="h-4 w-4" /></Link>
            </div>
          </Reveal>

          <Reveal delay={330}>
            <dl className="mt-10 grid max-w-2xl grid-cols-3 border-y border-border/80 py-5 lg:mt-12">
              {[
                ['R&D', labels.experience],
                [String(collectionCount), labels.collections],
                ['GLOBAL', labels.global],
              ].map(([value, label]) => (
                <div key={label} className="border-e border-border/80 px-3 first:ps-0 last:border-e-0 last:pe-0 md:px-5">
                  <dt className="text-lg font-bold tracking-[-.03em] md:text-2xl">{value}</dt>
                  <dd className="mt-1 text-[10px] font-semibold uppercase tracking-[.13em] text-muted-foreground md:text-xs">{label}</dd>
                </div>
              ))}
            </dl>
          </Reveal>
        </div>

        <Reveal delay={160} y={30} className="relative mx-auto w-full max-w-[520px]">
          <div className="relative aspect-square">
            <div className="absolute inset-[8%] rounded-full border border-foreground/10" />
            <div className="animate-orbit absolute inset-[16%] rounded-full border border-dashed border-foreground/16" />
            <div className="absolute inset-[25%] rounded-full bg-accent/13 blur-3xl" />
            <div className="absolute left-[12%] top-[17%] h-2.5 w-2.5 rounded-full bg-accent shadow-glow" />
            <div className="absolute bottom-[20%] right-[8%] h-16 w-16 rounded-full border border-foreground/13" />

            {featured?.image ? (
              <Link href={featured.href} className="group absolute inset-[24%] z-10 grid place-items-center" aria-label={featured.name}>
                <div className="animate-float relative h-full w-full">
                  <Image
                    src={featured.image}
                    alt={featured.name}
                    fill
                    priority
                    sizes="(max-width: 1024px) 62vw, 34vw"
                    className="product-cutout object-contain p-[5%] transition duration-300 group-hover:scale-[1.025]"
                  />
                </div>
              </Link>
            ) : (
              <div className="absolute inset-[25%] grid place-items-center rounded-[2rem] bg-primary text-7xl font-bold text-primary-foreground">U</div>
            )}

            {featured && (
              <div className="glass absolute bottom-[8%] start-[2%] z-20 max-w-[240px] rounded-2xl p-4 shadow-lg">
                <p className="text-[10px] font-bold uppercase tracking-[.18em] text-accent">{labels.featured}</p>
                <p className="mt-1 font-semibold">{featured.name}</p>
                {featured.series && <p className="mt-1 text-xs text-muted-foreground">{featured.series}</p>}
              </div>
            )}

            <div className="scan-line pointer-events-none absolute inset-x-[18%] top-1/2 h-px overflow-hidden bg-foreground/10" />
          </div>
        </Reveal>

        <a href="#latest-products" className="absolute bottom-6 left-1/2 hidden -translate-x-1/2 items-center gap-2 text-[10px] font-bold uppercase tracking-[.2em] text-muted-foreground lg:flex">
          {labels.featured} <ArrowDownRight className="h-3.5 w-3.5" />
        </a>
      </div>
    </section>
  );
}
