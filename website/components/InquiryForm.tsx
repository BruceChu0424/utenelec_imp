'use client';

import { CheckCircle } from 'lucide-react';
import { useLocale, useTranslations } from 'next-intl';
import { useRef, useState, useTransition, type FormEvent } from 'react';
import { routing } from '@/i18n/routing';
import { Link } from '@/i18n/navigation';
import { submitInquiry } from '@/lib/actions';

export function InquiryForm({
  source = 'contact',
  initialMessage = '',
  projectBrief = false,
}: {
  source?: string;
  initialMessage?: string;
  projectBrief?: boolean;
}) {
  const t = useTranslations('Contact');
  const tc = useTranslations('Common');
  const activeLocale = useLocale();
  const locale = routing.locales.find((candidate) => candidate === activeLocale) ?? routing.defaultLocale;
  const [pending, start] = useTransition();
  const [done, setDone] = useState(false);
  const [error, setError] = useState(false);
  const [contactError, setContactError] = useState(false);
  const phoneRef = useRef<HTMLInputElement>(null);

  const onSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(false);
    const form = event.currentTarget;
    const data = new FormData(form);
    const phone = String(data.get('phone') || '').trim();
    const email = String(data.get('email') || '').trim();
    if (!phone && !email) {
      setContactError(true);
      phoneRef.current?.focus();
      return;
    }
    setContactError(false);

    start(async () => {
      const result = await submitInquiry(data);
      if (result.ok) {
        setDone(true);
        form.reset();
      } else if ('reason' in result && result.reason === 'contact-required') {
        setContactError(true);
        phoneRef.current?.focus();
      } else {
        setError(true);
      }
    });
  };

  if (done) {
    return <div className="rounded-2xl border border-accent/30 bg-accent/10 p-10 text-center" role="status"><CheckCircle className="mx-auto h-10 w-10 text-accent" /><p className="mt-3 font-semibold text-foreground">{tc('submitted')}</p></div>;
  }

  return (
    <form onSubmit={onSubmit} className="space-y-5" aria-busy={pending}>
      <input type="hidden" name="source" value={source} />
      <input type="hidden" name="locale" value={locale} />
      <div className="absolute -left-[9999px]" aria-hidden="true"><label htmlFor="website">Website</label><input id="website" name="website" tabIndex={-1} autoComplete="off" /></div>
      <div>
        <label htmlFor="inquiry-name" className="label-uten">{t('name')} <span className="text-destructive">*</span></label>
        <input id="inquiry-name" required name="name" maxLength={80} autoComplete="name" className="input-uten" />
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <div><label htmlFor="inquiry-phone" className="label-uten">{t('phone')}</label><input ref={phoneRef} id="inquiry-phone" name="phone" maxLength={40} autoComplete="tel" inputMode="tel" aria-describedby="inquiry-contact-hint" aria-invalid={contactError || undefined} onChange={() => contactError && setContactError(false)} className="input-uten" /></div>
        <div><label htmlFor="inquiry-email" className="label-uten">{t('email')}</label><input id="inquiry-email" type="email" name="email" maxLength={160} autoComplete="email" aria-describedby="inquiry-contact-hint" aria-invalid={contactError || undefined} onChange={() => contactError && setContactError(false)} className="input-uten" /></div>
      </div>
      <p id="inquiry-contact-hint" className={`-mt-2 text-sm ${contactError ? 'font-medium text-destructive' : 'text-muted-foreground'}`} role={contactError ? 'alert' : undefined}>{t('phone')} / {t('email')} · {tc('required')}</p>
      <div><label htmlFor="inquiry-company" className="label-uten">{t('company')}</label><input id="inquiry-company" name="company" maxLength={160} autoComplete="organization" className="input-uten" /></div>
      {projectBrief && (
        <fieldset className="space-y-4 rounded-2xl border border-border bg-background-elevated/45 p-4 sm:p-5">
          <legend className="px-2 text-sm font-bold text-accent">{t('projectBriefTitle')}</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <div><label htmlFor="inquiry-market" className="label-uten">{t('countryMarket')} <span className="text-destructive">*</span></label><input id="inquiry-market" required name="market" maxLength={120} autoComplete="country-name" className="input-uten" /></div>
            <div><label htmlFor="inquiry-customer-type" className="label-uten">{t('customerType')} <span className="text-destructive">*</span></label><select id="inquiry-customer-type" required name="customerType" defaultValue="" className="input-uten"><option value="" disabled>—</option>{(['distributor', 'project', 'oem', 'designer', 'other'] as const).map((value) => <option key={value} value={value}>{t(`customerTypes.${value}`)}</option>)}</select></div>
          </div>
          <div><label htmlFor="inquiry-standard" className="label-uten">{t('standard')}</label><input id="inquiry-standard" name="requiredStandard" maxLength={160} className="input-uten" /></div>
          <div><label htmlFor="inquiry-product-interest" className="label-uten">{t('productInterest')} <span className="text-destructive">*</span></label><input id="inquiry-product-interest" required name="productInterest" maxLength={240} className="input-uten" /></div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div><label htmlFor="inquiry-request-type" className="label-uten">{t('requestType')} <span className="text-destructive">*</span></label><select id="inquiry-request-type" required name="requestType" defaultValue="" className="input-uten"><option value="" disabled>—</option>{(['quotation', 'sample', 'technical', 'partnership', 'other'] as const).map((value) => <option key={value} value={value}>{t(`requestTypes.${value}`)}</option>)}</select></div>
            <div><label htmlFor="inquiry-quantity" className="label-uten">{t('estimatedQuantity')}</label><input id="inquiry-quantity" name="estimatedQuantity" maxLength={120} className="input-uten" /></div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div><label htmlFor="inquiry-schedule" className="label-uten">{t('targetSchedule')}</label><input id="inquiry-schedule" name="targetSchedule" maxLength={120} className="input-uten" /></div>
            <div><label htmlFor="inquiry-contact-method" className="label-uten">{t('preferredContact')}</label><input id="inquiry-contact-method" name="preferredContact" maxLength={80} className="input-uten" /></div>
          </div>
        </fieldset>
      )}
      <div><label htmlFor="inquiry-message" className="label-uten">{t('message')} <span className="text-destructive">*</span></label><textarea id="inquiry-message" required name="message" rows={5} maxLength={3000} defaultValue={initialMessage} className="input-uten resize-y" /></div>
      <label className="flex items-start gap-3 text-sm leading-6 text-muted-foreground"><input type="checkbox" required name="consent" value="yes" className="mt-1 h-4 w-4 accent-[hsl(var(--accent))]" /><span>{t('consent')}. {t('privacyPrefix')} <Link href="/privacy" className="font-semibold text-foreground underline decoration-border underline-offset-4 hover:text-accent">{t('privacyLink')}</Link>.</span></label>
      {error && <p className="text-sm font-medium text-destructive" role="alert" aria-live="polite">{tc('error')}</p>}
      <button type="submit" disabled={pending} className="btn-accent w-full">{pending ? tc('submitting') : tc('submit')}</button>
    </form>
  );
}
