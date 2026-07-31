import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getJobs, getSetting } from '@/lib/queries';
import { tr, pick } from '@/lib/content';

export default async function CareersPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Careers');
  const meta = pick<{ title: string; subtitle: string; body: string }>(await getSetting('careers'), locale)!;
  const jobs = await getJobs();

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-24">
        <div className="ambient-blob" style={{ width: 420, height: 420, background: 'hsl(174 100% 40%)', top: '-30%', left: '10%' }} />
        <div className="container-uten relative max-w-3xl">
          <span className="eyebrow">Careers</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{meta.title}</span></h1>
          <p className="mt-3 text-lg text-muted-foreground">{meta.subtitle}</p>
          <p className="mt-4 max-w-2xl leading-relaxed text-muted-foreground/80">{meta.body}</p>
        </div>
      </section>

      <div className="container-uten py-12">
        {jobs.length === 0 ? (
          <p className="py-20 text-center text-muted-foreground">{t('empty')}</p>
        ) : (
          <div className="mx-auto max-w-3xl space-y-4">
            {jobs.map((j) => {
              const jd = tr<{ title: string; requirements?: string; description?: string }>(j.i18n, locale);
              return (
                <div key={j.slug} className="card-uten p-6">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <h2 className="font-heading text-xl font-bold">{jd.title}</h2>
                      <div className="mt-1 flex flex-wrap gap-3 text-sm text-muted-foreground">
                        {j.department && <span>{t('department')}: {j.department}</span>}
                        {j.location && <span>{t('location')}: {j.location}</span>}
                      </div>
                    </div>
                  </div>
                  {jd.description && <p className="mt-3 text-sm text-muted-foreground">{jd.description}</p>}
                  {jd.requirements && (
                    <div className="mt-4">
                      <p className="mb-2 text-xs font-semibold uppercase tracking-wider text-accent">{t('requirements')}</p>
                      <p className="whitespace-pre-line text-sm leading-relaxed text-muted-foreground">{jd.requirements}</p>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
