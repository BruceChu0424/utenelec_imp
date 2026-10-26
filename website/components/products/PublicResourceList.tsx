import { Download, FileText } from 'lucide-react';
import { getTranslations } from 'next-intl/server';
import { Link } from '@/i18n/navigation';
import { resourcePageHref, type queryPublicResources } from '@/lib/resources';

export async function PublicResourceList({ result, locale, baseHref }: { result: Awaited<ReturnType<typeof queryPublicResources>>; locale: string; baseHref: string }) {
  const [t, productT] = await Promise.all([
    getTranslations({ locale, namespace: 'Resources' }),
    getTranslations({ locale, namespace: 'Products' }),
  ]);
  const language = new Intl.DisplayNames([locale], { type: 'language' });
  const date = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });
  return <><div className="public-resource-list">{result.items.map(resource => <article key={resource.id}>
    <FileText size={24} aria-hidden="true" />
    <div><h3>{resource.title}</h3>{resource.description && <p>{resource.description}</p>}<dl>
      {resource.version && <div><dt>{t('fileVersion')}</dt><dd>{resource.version}</dd></div>}
      <div><dt>{t('fileLanguage')}</dt><dd>{language.of(resource.language) || resource.language}</dd></div>
      {resource.market && <div><dt>{t('fileMarket')}</dt><dd>{resource.market}</dd></div>}
      <div><dt>{t('fileUpdated')}</dt><dd><time dateTime={resource.updatedAt}>{date.format(new Date(resource.updatedAt))}</time></dd></div>
    </dl></div>
    <a href={resource.href} download className="public-text-link" aria-label={`${t('download')}: ${resource.title}`}><Download size={18} aria-hidden="true" /><span>{t('download')}<small>{new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(resource.sizeBytes / 1024)} KiB</small></span></a>
  </article>)}</div>{result.pages > 1 && <nav className="catalog-pagination" aria-label={productT('pagination')}>
    {result.page > 1 ? <Link locale={locale} href={resourcePageHref(baseHref, result.page - 1)} className="btn-outline" rel="prev">{productT('previousPage')}</Link> : <span className="pagination-disabled">{productT('previousPage')}</span>}
    <span>{result.page} / {result.pages}</span>
    {result.page < result.pages ? <Link locale={locale} href={resourcePageHref(baseHref, result.page + 1)} className="btn-outline" rel="next">{productT('nextPage')}</Link> : <span className="pagination-disabled">{productT('nextPage')}</span>}
  </nav>}</>;
}
