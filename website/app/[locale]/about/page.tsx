import { setRequestLocale, getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { ArrowRight } from 'lucide-react';
import { getSetting } from '@/lib/queries';
import { pick, trArr } from '@/lib/content';
import { SectionHeading } from '@/components/SectionHeading';

export default async function AboutPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('About');
  const tc = await getTranslations('Common');
  const about = pick<{ title: string; subtitle: string; body: string; cta: string }>(await getSetting('about'), locale)!;
  const stats = trArr<{ value: string; label: string }>(await getSetting('stats'), locale);
  const craft = trArr<{ title: string; desc: string }>(await getSetting('craft'), locale);

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-24">
        <div className="ambient-blob" style={{ width: 420, height: 420, background: 'hsl(174 100% 40%)', top: '-30%', left: '10%' }} />
        <div className="container-uten relative max-w-3xl">
          <span className="eyebrow">{about.subtitle}</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{about.title}</span></h1>
        </div>
      </section>

      <section className="section">
        <div className="container-uten max-w-3xl">
          <p className="text-lg leading-loose text-muted-foreground">{about.body}</p>
        </div>
      </section>

      <section className="border-y border-border bg-card">
        <div className="container-uten grid grid-cols-2 gap-6 py-10 md:grid-cols-4">
          {stats.map((s) => (
            <div key={s.label} className="text-center">
              <p className="font-heading text-3xl font-bold text-accent md:text-4xl">{s.value}</p>
              <p className="mt-1 text-sm text-muted-foreground">{s.label}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="section bg-muted/40">
        <div className="container-uten">
          <SectionHeading center eyebrow={t('craft')} title={locale === 'zh' ? '核心工艺实力' : 'Core Craftsmanship'} />
          <div className="mt-10 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
            {craft.map((c, i) => (
              <div key={c.title} className="card-uten p-6">
                <div className="grid h-12 w-12 place-items-center rounded-xl bg-accent/10 font-heading text-lg font-bold text-accent">{String(i + 1).padStart(2, '0')}</div>
                <h3 className="mt-4 font-semibold">{c.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{c.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <div className="rounded-3xl bg-primary p-10 text-center text-primary-foreground md:p-16">
            <h2 className="mx-auto max-w-2xl text-balance font-heading text-2xl font-bold md:text-3xl">
              {locale === 'zh' ? '管理完善 · 团队专业 · 服务全球' : 'Complete Management · Professional Team · Global Service'}
            </h2>
            <p className="mx-auto mt-4 max-w-xl text-primary-foreground/75">
              {locale === 'zh' ? '生产、研发、检验检测、销售、企划及客户服务中心等完备部门，精英团队人均行业经验5年以上。' : 'Complete departments across production, R&D, testing, sales, planning and customer service — an elite team with 5+ years average experience.'}
            </p>
            <Link href="/contact" className="btn-accent mt-7">{tc('contactUs')}<ArrowRight className="h-4 w-4" /></Link>
          </div>
        </div>
      </section>
    </>
  );
}
