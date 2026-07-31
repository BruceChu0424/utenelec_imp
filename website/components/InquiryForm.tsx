'use client';
import { useState, useTransition, type FormEvent } from 'react';
import { submitInquiry } from '@/lib/actions';
import { useTranslations } from 'next-intl';
import { CheckCircle } from 'lucide-react';

export function InquiryForm({ source = 'contact' }: { source?: string }) {
  const t = useTranslations('Contact');
  const tc = useTranslations('Common');
  const [pending, start] = useTransition();
  const [done, setDone] = useState(false);
  const [err, setErr] = useState(false);

  const onSubmit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setErr(false);
    const fd = new FormData(e.currentTarget);
    start(async () => {
      const r = await submitInquiry(fd);
      if (r.ok) { setDone(true); e.currentTarget.reset(); }
      else setErr(true);
    });
  };

  if (done) {
    return (
      <div className="rounded-xl border border-accent/30 bg-accent/10 p-10 text-center">
        <CheckCircle className="mx-auto h-10 w-10 text-accent" />
        <p className="mt-3 font-medium text-accent">{tc('submitted')}</p>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <input type="hidden" name="source" value={source} />
      <div>
        <label className="label-uten">{t('name')} <span className="text-destructive">*</span></label>
        <input required name="name" className="input-uten" />
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label className="label-uten">{t('phone')}</label>
          <input name="phone" className="input-uten" />
        </div>
        <div>
          <label className="label-uten">{t('email')}</label>
          <input type="email" name="email" className="input-uten" />
        </div>
      </div>
      <div>
        <label className="label-uten">{t('company')}</label>
        <input name="company" className="input-uten" />
      </div>
      <div>
        <label className="label-uten">{t('message')} <span className="text-destructive">*</span></label>
        <textarea required name="message" rows={4} className="input-uten resize-none" />
      </div>
      {err && <p className="text-sm text-destructive">{tc('error')}</p>}
      <button type="submit" disabled={pending} className="btn-accent w-full">
        {pending ? tc('submitting') : tc('submit')}
      </button>
    </form>
  );
}
