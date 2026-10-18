import Image from 'next/image';
import { getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';

type Contact = { phone?: string; phone2?: string; email?: string; address?: string; icp?: string; company?: string };
type FooterContent = { about?: string; copyright?: string };
export async function SiteFooter({ locale, series, contact, content }: { locale: string; series: { code: string; name: string }[]; contact: Contact; content: FooterContent }) {
  const [t, nav, common, meta] = await Promise.all([getTranslations({ locale, namespace: 'Footer' }), getTranslations({ locale, namespace: 'Nav' }), getTranslations({ locale, namespace: 'Common' }), getTranslations({ locale, namespace: 'Meta' })]);
  return <footer className="public-footer"><div className="container-uten">
    <div className="public-footer-lead"><div><h2>{t('ctaTitle')}</h2><Link locale={locale} href="/contact" className="btn-primary">{common('contactUs')}</Link></div><address>{contact.phone && <a className="footer-phone" href={`tel:${contact.phone.replace(/[^+\d]/g, '')}`}>{contact.phone}</a>}{contact.email && <a href={`mailto:${contact.email}`}>{contact.email}</a>}</address></div>
    <div className="public-footer-grid"><div><Image src="/images/logo/logo_name.png" alt="UTEN ELEC" width={2240} height={361} className="w-40 h-auto" /><p>{content.about || t('brandStatement')}</p>{contact.address && <address>{contact.address}</address>}</div>
      <div><h3>{t('products')}</h3><Link locale={locale} href="/products">{nav('products')}</Link>{series.slice(0, 5).map(item => <Link locale={locale} key={item.code} href={`/products/${item.code}`}>{item.name}</Link>)}<Link locale={locale} href="/studio">{nav('studio')}</Link></div>
      <div><h3>{t('quickLinks')}</h3>{[['/about', nav('about')], ['/capabilities', nav('capabilities')], ['/news', nav('news')], ['/cases', nav('cases')], ['/careers', nav('careers')]].map(([href, label]) => <Link locale={locale} key={href} href={href}>{label}</Link>)}</div>
      <div><h3>{t('contact')}</h3>{[['/partners', nav('partners')], ['/resources', nav('resources')], ['/contact', nav('contact')], ['/privacy', t('privacy')]].map(([href, label]) => <Link locale={locale} key={href} href={href}>{label}</Link>)}{contact.phone2 && <a href={`tel:${contact.phone2.replace(/[^+\d]/g, '')}`}>{contact.phone2}</a>}</div>
    </div>
    <div className="public-footer-bottom"><p>{content.copyright || `© ${new Date().getFullYear()} ${contact.company || meta('company')}. ${t('rights')}.`}</p>{contact.icp && <p>{contact.icp}</p>}</div>
  </div></footer>;
}
