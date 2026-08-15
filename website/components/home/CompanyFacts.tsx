import { ArrowUpRight } from 'lucide-react';
import { Link } from '@/i18n/navigation';
import { Reveal } from '@/components/motion/Reveal';

export type CompanyFact = { value: string; label: string };

export type CompanyFactsLabels = {
  eyebrow: string;
  title: string;
  body: string;
  cta: string;
};

/**
 * 公司实力条：创立积累、生产基地、认证体系等硬事实，
 * 用大数字排版呈现，服务“门户网站”的公司推广诉求。
 */
export function CompanyFacts({
  facts,
  labels,
  locale,
}: {
  facts: CompanyFact[];
  labels: CompanyFactsLabels;
  locale: string;
}) {
  return (
    <section className="section border-b border-border">
      <div className="container-uten">
        <div className="grid items-end gap-8 lg:grid-cols-[1.05fr_.95fr] lg:gap-16">
          <Reveal>
            <p className="eyebrow">{labels.eyebrow}</p>
            <h2 className="section-title mt-7 max-w-3xl text-balance">{labels.title}</h2>
          </Reveal>
          <Reveal delay={110}>
            <p className="max-w-xl text-pretty text-base leading-8 text-muted-foreground md:text-lg lg:justify-self-end">
              {labels.body}
            </p>
          </Reveal>
        </div>

        <div className="mt-12 grid grid-cols-2 gap-px overflow-hidden rounded-[1.5rem] border border-border bg-border lg:grid-cols-4">
          {facts.map((fact, index) => (
            <Reveal key={fact.label} delay={index * 70} className="h-full">
              <div className="flex h-full flex-col justify-between bg-card p-6 md:p-8">
                <p className="text-[10px] font-bold uppercase tracking-[.2em] text-accent">{String(index + 1).padStart(2, '0')}</p>
                <div className="mt-10">
                  <p className="font-heading text-3xl font-bold tracking-[-.045em] md:text-[2.6rem] md:leading-none">{fact.value}</p>
                  <p className="mt-3 text-sm leading-6 text-muted-foreground">{fact.label}</p>
                </div>
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal delay={200}>
          <div className="mt-9">
            <Link locale={locale} href="/about" className="btn-outline">
              {labels.cta}<ArrowUpRight className="h-4 w-4" />
            </Link>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
