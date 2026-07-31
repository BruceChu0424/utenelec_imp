import { setRequestLocale, getTranslations } from 'next-intl/server';
import { getSetting } from '@/lib/queries';
import { pick } from '@/lib/content';
import { InquiryForm } from '@/components/InquiryForm';
import { Phone, Mail, MapPin, Globe } from 'lucide-react';

export default async function ContactPage({ params }: { params: { locale: string } }) {
  const { locale } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Contact');
  const contact = pick<{ phone?: string; phone2?: string; email?: string; address?: string; company?: string }>(await getSetting('contact'), locale) || {};

  const items = [
    { icon: Phone, label: t('phone'), value: [contact.phone, contact.phone2].filter(Boolean).join(' / ') },
    { icon: Mail, label: t('email'), value: contact.email },
    { icon: MapPin, label: t('address'), value: contact.address },
    { icon: Globe, label: locale === 'zh' ? '外贸出口' : 'Export', value: locale === 'zh' ? '产品远销海外多国' : 'Products sold worldwide' },
  ].filter((i) => i.value);

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-16 md:py-20">
        <div className="ambient-blob" style={{ width: 380, height: 380, background: 'hsl(174 100% 40%)', top: '-40%', right: '5%' }} />
        <div className="container-uten relative">
          <span className="eyebrow">Contact</span>
          <h1 className="mt-4 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{t('title')}</span></h1>
        </div>
      </section>

      <div className="container-uten py-12">
        <div className="grid gap-12 lg:grid-cols-2">
          <div>
            <div className="space-y-6">
              {items.map((it) => (
                <div key={it.label} className="flex items-start gap-4">
                  <span className="grid h-12 w-12 shrink-0 place-items-center rounded-xl bg-accent/10 text-accent">
                    <it.icon className="h-5 w-5" />
                  </span>
                  <div>
                    <p className="text-sm text-muted-foreground">{it.label}</p>
                    <p className="mt-0.5 font-medium">{it.value}</p>
                  </div>
                </div>
              ))}
            </div>
            <div className="mt-8 overflow-hidden rounded-2xl border border-border bg-muted/40 p-6">
              <p className="text-sm leading-relaxed text-muted-foreground">
                {locale === 'zh'
                  ? '我们期待与全球经销商、工程方及采购商合作。请填写右侧表单或直接致电，我们将尽快回复。'
                  : 'We welcome dealers, project developers and buyers worldwide. Fill in the form or call us directly — we will reply soon.'}
              </p>
            </div>
          </div>

          <div className="card-uten p-6 md:p-8">
            <h2 className="mb-5 font-heading text-xl font-bold">{t('formTitle')}</h2>
            <InquiryForm source="contact" />
          </div>
        </div>
      </div>
    </>
  );
}
