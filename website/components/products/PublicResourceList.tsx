import { Download, FileText } from 'lucide-react';
import { getTranslations } from 'next-intl/server';
import type { getPublicResources } from '@/lib/resources';

export async function PublicResourceList({ resources, locale }: { resources: Awaited<ReturnType<typeof getPublicResources>>; locale: string }) {
  const t = await getTranslations({ locale, namespace: 'Resources' });
  const language = new Intl.DisplayNames([locale], { type: 'language' });
  const date = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });
  return <div className="public-resource-list">{resources.map(resource => <article key={resource.id}>
    <FileText size={24} aria-hidden="true" />
    <div><h3>{resource.title}</h3>{resource.description && <p>{resource.description}</p>}<dl>
      {resource.version && <div><dt>{t('fileVersion')}</dt><dd>{resource.version}</dd></div>}
      <div><dt>{t('fileLanguage')}</dt><dd>{language.of(resource.language) || resource.language}</dd></div>
      {resource.market && <div><dt>{t('fileMarket')}</dt><dd>{resource.market}</dd></div>}
      <div><dt>{t('fileUpdated')}</dt><dd><time dateTime={resource.updatedAt}>{date.format(new Date(resource.updatedAt))}</time></dd></div>
    </dl></div>
    <a href={resource.href} download className="public-text-link" aria-label={`${t('download')}: ${resource.title}`}><Download size={18} aria-hidden="true" /><span>{t('download')}<small>{new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(resource.sizeBytes / 1024)} KiB</small></span></a>
  </article>)}</div>;
}
