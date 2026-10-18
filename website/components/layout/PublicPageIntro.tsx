import type { ReactNode } from 'react';
import { Link } from '@/i18n/navigation';

export function PublicPageIntro({ title, description, locale, trail, children }: { title: string; description?: string; locale: string; trail?: Array<{ label: string; href?: string }>; children?: ReactNode }) {
  return <header className="public-page-intro container-uten">
    {trail?.length ? <nav className="public-breadcrumb" aria-label={locale === 'zh' ? '页面路径' : 'Breadcrumb'}>{trail.map((item, index) => <span key={`${item.label}-${index}`}>{index > 0 && <span aria-hidden="true">/</span>}{item.href ? <Link locale={locale} href={item.href}>{item.label}</Link> : <span aria-current="page">{item.label}</span>}</span>)}</nav> : null}
    <h1>{title}</h1>{description && <p>{description}</p>}{children}
  </header>;
}
