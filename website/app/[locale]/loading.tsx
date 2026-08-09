'use client';

import { useTranslations } from 'next-intl';

export default function Loading() {
  const t = useTranslations('Common');
  return (
    <div className="container-uten py-16" role="status" aria-live="polite" aria-busy="true">
      <span className="sr-only">{t('loading')}</span>
      <div className="animate-pulse space-y-10" aria-hidden="true">
        <div className="space-y-4">
          <div className="h-3 w-32 rounded-full bg-muted" />
          <div className="h-14 max-w-2xl rounded-2xl bg-muted md:h-20" />
          <div className="h-5 max-w-xl rounded-full bg-muted" />
        </div>
        <div className="grid gap-5 md:grid-cols-3">
          {[0, 1, 2].map((item) => <div key={item} className="aspect-[4/3] rounded-[1.5rem] bg-muted" />)}
        </div>
      </div>
    </div>
  );
}
