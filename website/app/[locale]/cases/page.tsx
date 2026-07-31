import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getCases } from '@/lib/queries';
import { tr } from '@/lib/content';

export default async function CasesPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Cases');
  const cases = await getCases();

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-20">
        <div className="ambient-blob" style={{ width: 380, height: 380, background: 'hsl(174 100% 40%)', top: '-40%', right: '5%' }} />
        <div className="container-uten relative">
          <span className="eyebrow">Projects</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{t('title')}</span></h1>
          <p className="mt-3 text-muted-foreground">{t('subtitle')}</p>
        </div>
      </section>
      <div className="container-uten py-12">
        {cases.length === 0 ? (
          <p className="py-20 text-center text-muted-foreground">{locale === 'zh' ? '暂无内容' : 'No content yet'}</p>
        ) : (
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {cases.map((c) => {
              const ct = tr<{ title: string; location?: string; content?: string }>(c.i18n, locale);
              return (
                <div key={c.slug} className="card-uten overflow-hidden">
                  <div className="grid h-44 place-items-center bg-gradient-to-br from-primary to-primary-hover text-primary-foreground">
                    <span className="font-heading text-6xl font-bold opacity-25">{(ct.title || 'U')[0]}</span>
                  </div>
                  <div className="p-6">
                    {ct.location && <p className="text-xs uppercase tracking-wider text-accent">{ct.location}</p>}
                    <h2 className="mt-1 font-heading text-xl font-bold">{ct.title}</h2>
                    {ct.content && <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{ct.content}</p>}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
