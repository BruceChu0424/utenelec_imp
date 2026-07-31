import { Link } from '@/i18n/navigation';
import { ArrowRight } from 'lucide-react';
import { Reveal } from '@/components/motion/Reveal';

type HeroData = { title: string; subtitle: string; cta1: string; cta2: string };

export function Hero({ hero, locale }: { hero: HeroData; locale: string }) {
  return (
    <section className="relative flex min-h-[92vh] items-center overflow-hidden bg-background">
      {/* 环境光斑 */}
      <div className="ambient-blob animate-blob" style={{ width: 560, height: 560, background: 'hsl(174 100% 40%)', top: '-12%', left: '-8%' }} />
      <div className="ambient-blob animate-blob" style={{ width: 440, height: 440, background: 'hsl(192 85% 45%)', bottom: '-15%', right: '5%', animationDelay: '-7s' }} />
      {/* 网格 + 蒙版 */}
      <div className="absolute inset-0 bg-grid opacity-[0.35] mask-fade-b" />
      <div className="absolute inset-0 bg-gradient-to-b from-background/40 via-transparent to-background" />

      <div className="container-uten relative grid items-center gap-12 py-28 lg:grid-cols-[1.25fr_1fr] lg:py-32">
        <div>
          <Reveal>
            <span className="eyebrow">Uten Electrical · 优腾电器</span>
          </Reveal>
          <Reveal delay={120}>
            <h1 className="mt-7 font-heading text-hero font-bold text-balance">
              <span className="text-gradient">{hero.title}</span>
            </h1>
          </Reveal>
          <Reveal delay={240}>
            <p className="mt-7 max-w-xl text-lg leading-relaxed text-muted-foreground">{hero.subtitle}</p>
          </Reveal>
          <Reveal delay={360}>
            <div className="mt-10 flex flex-wrap gap-3">
              <Link href="/products" className="btn-accent">
                {hero.cta1}<ArrowRight className="h-4 w-4" />
              </Link>
              <Link href="/contact" className="btn-outline">{hero.cta2}</Link>
            </div>
          </Reveal>

          {/* 信任徽章 */}
          <Reveal delay={480}>
            <div className="mt-12 flex flex-wrap items-center gap-x-8 gap-y-3 text-xs text-muted-foreground">
              <span className="flex items-center gap-2"><span className="h-1.5 w-1.5 rounded-full bg-accent" />{locale === 'zh' ? '25 年行业深耕' : '25 Years'}</span>
              <span className="flex items-center gap-2"><span className="h-1.5 w-1.5 rounded-full bg-accent" />{locale === 'zh' ? '高新技术企业' : 'Hi-Tech Enterprise'}</span>
              <span className="flex items-center gap-2"><span className="h-1.5 w-1.5 rounded-full bg-accent" />{locale === 'zh' ? '产品远销全球' : 'Global Export'}</span>
            </div>
          </Reveal>
        </div>

        {/* 右侧品牌 IP 形象 */}
        <Reveal delay={280} y={40} className="relative hidden lg:block">
          <div className="relative mx-auto max-w-md">
            <div className="absolute inset-8 rounded-full bg-accent/25 blur-3xl animate-pulse-glow" />
            <div className="absolute inset-0 -m-4 rounded-[2rem] border border-white/5" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src="/images/logo/logo_ip.png"
              alt="Uten 品牌形象"
              className="relative z-10 w-full animate-float drop-shadow-2xl"
            />
          </div>
        </Reveal>
      </div>

      {/* 滚动指示 */}
      <div className="absolute bottom-7 left-1/2 hidden -translate-x-1/2 flex-col items-center gap-2 text-muted-foreground/60 md:flex">
        <span className="text-[10px] uppercase tracking-[0.3em]">{locale === 'zh' ? '向下探索' : 'Scroll'}</span>
        <span className="flex h-9 w-5 justify-center rounded-full border border-border p-1">
          <span className="h-2 w-1 animate-bounce rounded-full bg-accent" />
        </span>
      </div>
    </section>
  );
}
