import { Link } from '@/i18n/navigation';
import { getTranslations } from 'next-intl/server';
import { Phone, Mail, MapPin } from 'lucide-react';

type Contact = { phone?: string; phone2?: string; email?: string; address?: string; icp?: string; company?: string };

export async function SiteFooter({ series, contact }: { series: { code: string; name: string }[]; contact: Contact }) {
  const t = await getTranslations('Footer');
  const tn = await getTranslations('Nav');
  const year = new Date().getFullYear();

  return (
    <footer className="border-t border-border bg-primary text-primary-foreground">
      <div className="container-uten grid gap-10 py-14 md:grid-cols-2 lg:grid-cols-4">
        <div>
          <div className="flex items-center gap-2">
            <span className="grid h-9 w-9 place-items-center rounded-lg bg-accent font-heading font-bold text-accent-foreground">U</span>
            <span className="font-heading text-lg font-bold">优腾 UTEN</span>
          </div>
          <p className="mt-4 max-w-xs text-sm leading-relaxed text-primary-foreground/70">
            {contact.company || '中山市优腾电器有限公司'}
          </p>
          <p className="mt-3 max-w-xs text-xs leading-relaxed text-primary-foreground/50">
            25 years focused on safe wall switches and sockets. Hi-tech enterprise. Exported worldwide.
          </p>
        </div>

        <div>
          <h4 className="mb-4 text-sm font-semibold uppercase tracking-wider text-accent">{t('products')}</h4>
          <ul className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            {series.slice(0, 10).map(s => (
              <li key={s.code}>
                <Link href={`/products/${s.code}`} className="text-primary-foreground/70 transition hover:text-primary-foreground">{s.name}</Link>
              </li>
            ))}
          </ul>
        </div>

        <div>
          <h4 className="mb-4 text-sm font-semibold uppercase tracking-wider text-accent">{t('quickLinks')}</h4>
          <ul className="space-y-2 text-sm">
            {[['/about', tn('about')], ['/news', tn('news')], ['/cases', tn('cases')], ['/join', tn('join')], ['/careers', tn('careers')]].map(([h, l]) => (
              <li key={h}><Link href={h} className="text-primary-foreground/70 transition hover:text-primary-foreground">{l}</Link></li>
            ))}
          </ul>
        </div>

        <div>
          <h4 className="mb-4 text-sm font-semibold uppercase tracking-wider text-accent">{t('contact')}</h4>
          <ul className="space-y-3 text-sm text-primary-foreground/70">
            {contact.phone && <li className="flex items-start gap-2"><Phone className="mt-0.5 h-4 w-4 shrink-0 text-accent" /><span>{contact.phone}{contact.phone2 ? ` / ${contact.phone2}` : ''}</span></li>}
            {contact.email && <li className="flex items-start gap-2"><Mail className="mt-0.5 h-4 w-4 shrink-0 text-accent" /><span>{contact.email}</span></li>}
            {contact.address && <li className="flex items-start gap-2"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-accent" /><span>{contact.address}</span></li>}
          </ul>
        </div>
      </div>

      <div className="border-t border-primary-foreground/10">
        <div className="container-uten flex flex-col items-center justify-between gap-2 py-5 text-xs text-primary-foreground/50 sm:flex-row">
          <p>© {year} {contact.company || '中山市优腾电器有限公司'} {t('rights')}.</p>
          {contact.icp && <p>{contact.icp}</p>}
        </div>
      </div>
    </footer>
  );
}
