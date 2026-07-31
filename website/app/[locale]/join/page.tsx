import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getSetting } from '@/lib/queries';
import { pick } from '@/lib/content';
import { InquiryForm } from '@/components/InquiryForm';
import { SectionHeading } from '@/components/SectionHeading';
import { Check } from 'lucide-react';

export default async function JoinPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Join');
  const join = pick<{ title: string; subtitle: string; advantages: string[]; cta: string }>(await getSetting('join'), locale)!;
  const process = locale === 'zh'
    ? ['提交申请', '资格审核', '实地考察', '签订协议', '开业支持']
    : ['Apply', 'Review', 'On-site Visit', 'Agreement', 'Launch Support'];

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-24">
        <div className="ambient-blob" style={{ width: 420, height: 420, background: 'hsl(174 100% 40%)', top: '-30%', left: '10%' }} />
        <div className="container-uten relative max-w-3xl">
          <span className="eyebrow">Partnership</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{join.title}</span></h1>
          <p className="mt-3 text-lg text-muted-foreground">{join.subtitle}</p>
        </div>
      </section>

      <section className="section">
        <div className="container-uten">
          <SectionHeading center title={t('advantage')} />
          <div className="mt-10 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
            {join.advantages.map((a, i) => (
              <div key={i} className="card-uten p-6">
                <span className="grid h-10 w-10 place-items-center rounded-lg bg-accent/15 text-accent"><Check className="h-5 w-5" /></span>
                <p className="mt-4 text-sm font-medium leading-relaxed">{a}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section bg-muted/40">
        <div className="container-uten">
          <SectionHeading center className="mb-10" title={t('process')} />
          <div className="flex flex-wrap items-center justify-center gap-3 md:gap-6">
            {process.map((p, i) => (
              <div key={p} className="flex items-center gap-3 md:gap-6">
                <div className="flex flex-col items-center">
                  <span className="grid h-12 w-12 place-items-center rounded-full bg-primary font-heading font-bold text-primary-foreground">{i + 1}</span>
                  <span className="mt-2 text-sm font-medium">{p}</span>
                </div>
                {i < process.length - 1 && <div className="hidden h-px w-10 bg-border md:block lg:w-16" />}
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container-uten max-w-xl">
          <SectionHeading center className="mb-8" title={t('formTitle')} subtitle={t('formSubtitle')} />
          <InquiryForm source="join" />
        </div>
      </section>
    </>
  );
}
