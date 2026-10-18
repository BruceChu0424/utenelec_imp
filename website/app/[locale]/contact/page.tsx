import type { Metadata } from 'next';
import { setRequestLocale, getTranslations } from 'next-intl/server';
import { notFound } from 'next/navigation';
import { PublicPageIntro } from '@/components/layout/PublicPageIntro';
import { getSetting, getPublicInquiryContext } from '@/lib/queries';
import { pick } from '@/lib/content';
import { InquiryForm } from '@/components/InquiryForm';
import { Phone, Mail, MapPin, Globe } from 'lucide-react';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Contact' });
  return buildPageMetadata({ locale, path: '/contact', title: t('title'), description: t('intro') });
}

export default async function ContactPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ product?: string; productId?: string; variantId?: string; seriesId?: string; source?: string }>;
}) {
  const { locale } = await params;
  const resolvedSearchParams = await searchParams;
  setRequestLocale(locale);
  const t = await getTranslations('Contact');
  const cleanId = (value: unknown) => typeof value === 'string' ? value.trim().slice(0, 120) : '';
  const bound = await getPublicInquiryContext({ productId: cleanId(resolvedSearchParams.productId), variantId: cleanId(resolvedSearchParams.variantId), seriesId: cleanId(resolvedSearchParams.seriesId) }, locale);
  if (!bound) notFound();
  const product = bound.label || (typeof resolvedSearchParams.product === 'string' ? resolvedSearchParams.product.trim().slice(0, 160) : '');
  const source = resolvedSearchParams.source === 'studio' && bound.context.productId ? 'studio' : bound.context.productId ? 'product' : 'contact';
  const contact = pick<{ phone?: string; phone2?: string; email?: string; address?: string; company?: string }>(await getSetting('contact'), locale) || {};
  const titleLines = t('title').split(/\n+/).map((line) => line.trim()).filter(Boolean);

  const items = [
    { icon: Phone, label: t('phone'), values: [contact.phone, contact.phone2].filter((value): value is string => Boolean(value)).map((value) => ({ text: value, href: `tel:${value.replace(/[^+\d]/g, '')}` })) },
    { icon: Mail, label: t('email'), values: contact.email ? [{ text: contact.email, href: `mailto:${contact.email}` }] : [] },
    { icon: MapPin, label: t('address'), values: contact.address ? [{ text: contact.address }] : [] },
    { icon: Globe, label: t('export'), values: [{ text: t('exportValue') }] },
  ].filter((item) => item.values.length);

  return (
    <>
      <PublicPageIntro locale={locale} title={titleLines.join(' ')} description={t('intro')} />
  <div className="container-uten section-tight">
        <div className="grid gap-12 lg:grid-cols-[.8fr_1.2fr] lg:gap-20">
          <div>
            <div className="space-y-6">
              {items.map((item) => (
                <div key={item.label} className="flex items-start gap-4">
                  <span className="grid h-12 w-12 shrink-0 place-items-center rounded-xl bg-accent/10 text-accent">
                    <item.icon className="h-5 w-5" />
                  </span>
                  <div>
                    <p className="text-sm text-muted-foreground">{item.label}</p>
                    <div className="mt-1 flex flex-wrap gap-x-2 font-medium">
                      {item.values.map((value, index) => (
                        <span key={value.text} className="inline-flex items-center gap-2">
                          {index > 0 && <span className="text-muted-foreground" aria-hidden="true">/</span>}
                          {'href' in value && value.href ? <a href={value.href} className="transition hover:text-accent">{value.text}</a> : value.text}
                        </span>
                      ))}
                    </div>
                  </div>
                </div>
              ))}
            </div>
            <div className="mt-10 rounded-[1.5rem] bg-foreground p-7 text-background">
              <p className="eyebrow text-background/55">{t('globalSupport')}</p>
              <p className="mt-4 text-sm leading-7 text-background/75">{t('support')}</p>
            </div>
          </div>

          <div className="card-uten p-6 md:p-8">
            <h2 className="mb-5 font-heading text-xl font-bold">{t('formTitle')}</h2>
            <InquiryForm
              source={source}
              context={bound.context}
              contextLabel={bound.label}
              initialMessage={product ? t('productPrefill', { product }) : ''}
            />
          </div>
        </div>
      </div>
    </>
  );
}
