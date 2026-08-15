import Image from 'next/image';
import { ArrowUpRight, Box } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import { Reveal } from '@/components/motion/Reveal';

export type FlagshipData = {
  image: string;
  name: string;
  series?: string;
  href: string;
  studioHref: string;
};

export type FlagshipLabels = {
  eyebrow: string;
  view: string;
  studio: string;
};

/**
 * 苹果式旗舰发布区：全屏暗色舞台上只讲一款最新产品。
 * 首页因此保持“橱窗”气质——一款主打，而不是产品清单。
 */
export function FlagshipSpotlight({
  flagship,
  labels,
  locale,
}: {
  flagship: FlagshipData;
  labels: FlagshipLabels;
  locale: string;
}) {
  return (
    <section className="panel-dark relative isolate overflow-hidden">
      <div className="absolute inset-0 bg-[radial-gradient(ellipse_62%_52%_at_50%_58%,hsl(var(--accent)/.20),transparent_66%)]" />
      <div className="absolute left-1/2 top-[54%] h-[46rem] w-[46rem] max-w-[120vw] -translate-x-1/2 -translate-y-1/2 rounded-full border border-primary-foreground/[.07]" />
      <div className="absolute left-1/2 top-[54%] h-[32rem] w-[32rem] max-w-[86vw] -translate-x-1/2 -translate-y-1/2 rounded-full border border-primary-foreground/[.09]" />

      <div className="container-uten relative flex min-h-[88vh] flex-col items-center justify-center py-16 text-center md:py-20">
        <Reveal>
          <p className="inline-flex items-center gap-3 text-[11px] font-bold uppercase tracking-[.26em] text-accent-soft">
            <span className="h-1.5 w-1.5 rounded-full bg-accent-soft" />
            {labels.eyebrow}
            <span className="h-1.5 w-1.5 rounded-full bg-accent-soft" />
          </p>
        </Reveal>

        <Reveal delay={90}>
          <h2 className="mt-6 max-w-[16ch] text-balance font-heading text-[clamp(2.9rem,7.5vw,6.5rem)] font-semibold leading-[1.02] tracking-[-.055em]">
            {flagship.name}
          </h2>
        </Reveal>

        {flagship.series && (
          <Reveal delay={160}>
            <p className="mt-5 text-sm font-semibold uppercase tracking-[.2em] text-primary-foreground/52 md:text-base">
              {flagship.series}
            </p>
          </Reveal>
        )}

        <Reveal delay={220} y={34} className="relative mt-4 w-full max-w-[560px] md:mt-2">
          <div className="absolute left-1/2 top-1/2 h-[68%] w-[74%] -translate-x-1/2 -translate-y-1/2 rounded-full bg-accent/22 blur-3xl" />
          <Link locale={locale} href={flagship.href} className="group relative block aspect-square" aria-label={flagship.name}>
            <div className="animate-float absolute inset-0">
              <Image
                src={flagship.image}
                alt={flagship.name}
                fill
                priority
                sizes="(max-width: 768px) 82vw, 560px"
                className="product-cutout object-contain p-[7%] transition duration-500 ease-out group-hover:scale-[1.03]"
              />
            </div>
          </Link>
        </Reveal>

        <Reveal delay={300}>
          <div className="flex flex-wrap items-center justify-center gap-3">
            <Link locale={locale} href={flagship.href} className="btn bg-primary-foreground text-primary hover:bg-primary-foreground/88">
              {labels.view}<ArrowUpRight className="h-4 w-4" />
            </Link>
            <Link locale={locale} href={flagship.studioHref} className="btn border border-primary-foreground/25 text-primary-foreground hover:bg-primary-foreground/8">
              <Box className="h-4 w-4" />{labels.studio}
            </Link>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
