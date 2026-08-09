import Image from 'next/image';
import { ArrowUpRight, Mail, MapPin, Phone } from 'lucide-react';
import { getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';

type Contact = { phone?: string; phone2?: string; email?: string; address?: string; icp?: string; company?: string };
type FooterContent = { about?: string; copyright?: string };

export async function SiteFooter({
  locale,
  series,
  contact,
  content,
}: {
  locale: string;
  series: { code: string; name: string }[];
  contact: Contact;
  content: FooterContent;
}) {
  const t = await getTranslations({ locale, namespace: 'Footer' });
  const tn = await getTranslations({ locale, namespace: 'Nav' });
  const tc = await getTranslations({ locale, namespace: 'Common' });
  const tm = await getTranslations({ locale, namespace: 'Meta' });
  const year = new Date().getFullYear();
  const company = contact.company || tm('company');

  return (
    <footer className="panel-dark mt-10 overflow-hidden">
      <div className="container-uten border-b border-primary-foreground/15 py-16 md:py-24">
        <div className="grid items-end gap-10 lg:grid-cols-[1fr_auto]">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-[.24em] text-accent-soft">UTEN ELECTRICAL</p>
            <h2 className="mt-5 max-w-4xl text-balance text-4xl font-semibold leading-[1.05] tracking-[-.05em] md:text-7xl md:leading-[1.02]">{t('ctaTitle')}</h2>
          </div>
          <Link locale={locale} href="/contact" className="btn bg-primary-foreground text-primary hover:bg-primary-foreground/88">
            {tc('getAdvice')} <ArrowUpRight className="h-4 w-4" />
          </Link>
        </div>
      </div>

      <div className="container-uten grid gap-10 py-14 md:grid-cols-2 lg:grid-cols-[1.35fr_1fr_1fr_1.25fr]">
        <div>
          <Image src="/images/logo/logo_name.png" alt="UTEN ELEC" width={165} height={44} className="h-7 w-auto brightness-0 invert" />
          <p className="mt-5 max-w-sm text-sm leading-7 text-primary-foreground/58">{content.about || t('brandStatement')}</p>
        </div>

        <div>
          <h3 className="text-xs font-bold uppercase tracking-[.18em] text-accent-soft">{t('products')}</h3>
          <ul className="mt-5 space-y-2.5 text-sm">
            {series.slice(0, 6).map((entry) => (
              <li key={entry.code}><Link locale={locale} href={`/products/${entry.code}`} className="text-primary-foreground/62 transition hover:text-primary-foreground">{entry.name}</Link></li>
            ))}
          </ul>
        </div>

        <div>
          <h3 className="text-xs font-bold uppercase tracking-[.18em] text-accent-soft">{t('quickLinks')}</h3>
          <ul className="mt-5 space-y-2.5 text-sm">
            {[
              ['/', tn('home')], ['/studio', tn('studio')], ['/capabilities', tn('capabilities')],
              ['/partners', tn('partners')], ['/resources', tn('resources')], ['/about', tn('about')],
              ['/news', tn('news')], ['/careers', tn('careers')],
            ].map(([href, label]) => (
              <li key={href}><Link locale={locale} href={href} className="text-primary-foreground/62 transition hover:text-primary-foreground">{label}</Link></li>
            ))}
          </ul>
        </div>

        <div>
          <h3 className="text-xs font-bold uppercase tracking-[.18em] text-accent-soft">{t('contact')}</h3>
          <ul className="mt-5 space-y-4 text-sm text-primary-foreground/62">
            {contact.phone && <li className="flex gap-3"><Phone className="mt-0.5 h-4 w-4 shrink-0 text-accent-soft" /><span className="flex flex-wrap gap-x-2"><a href={`tel:${contact.phone.replace(/[^+\d]/g, '')}`} className="hover:text-primary-foreground">{contact.phone}</a>{contact.phone2 && <><span aria-hidden="true">/</span><a href={`tel:${contact.phone2.replace(/[^+\d]/g, '')}`} className="hover:text-primary-foreground">{contact.phone2}</a></>}</span></li>}
            {contact.email && <li className="flex gap-3"><Mail className="mt-0.5 h-4 w-4 shrink-0 text-accent-soft" /><a href={`mailto:${contact.email}`} className="hover:text-primary-foreground">{contact.email}</a></li>}
            {contact.address && <li className="flex gap-3"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-accent-soft" /><span>{contact.address}</span></li>}
          </ul>
        </div>
      </div>

      <div className="border-t border-primary-foreground/10">
        <div className="container-uten flex flex-col gap-2 py-5 text-xs text-primary-foreground/62 sm:flex-row sm:items-center sm:justify-between">
          <p>{content.copyright || `© ${year} ${company}. ${t('rights')}.`}</p>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
            <Link locale={locale} href="/privacy" className="transition hover:text-primary-foreground">{t('privacy')}</Link>
            {contact.icp && <p>{contact.icp}</p>}
          </div>
        </div>
      </div>
    </footer>
  );
}
