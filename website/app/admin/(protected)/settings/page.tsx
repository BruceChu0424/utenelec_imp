import { prisma } from '@/lib/db';
import { readAdminI18nLocale } from '@/lib/admin-i18n';
import {
  SiteSettingsForm,
  type SiteSettingKey,
  type SiteSettingsInitial,
} from '@/components/admin/SiteSettingsForm';

const SETTING_KEYS: SiteSettingKey[] = ['hero', 'contact', 'about', 'stats', 'craft', 'join', 'capabilities', 'partners', 'resources', 'careers', 'footer'];

function isSettingKey(value: unknown): value is SiteSettingKey {
  return typeof value === 'string' && SETTING_KEYS.includes(value as SiteSettingKey);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function stringFields(value: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries(Object.entries(value).flatMap(([key, field]) => typeof field === 'string' ? [[key, field]] : []));
}

export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const [records, query] = await Promise.all([
    prisma.setting.findMany({
      where: { key: { in: SETTING_KEYS } },
      select: { key: true, i18n: true },
    }),
    searchParams,
  ]);
  const byKey = new Map(records.map((record) => [record.key, record.i18n]));
  const errors: Partial<Record<SiteSettingKey, string>> = {};

  const objectLocale = (key: SiteSettingKey, locale: 'zh' | 'en') => {
    try {
      const value = readAdminI18nLocale<unknown>(byKey.get(key), locale);
      if (value === null) return {};
      if (!isRecord(value)) throw new Error(`${locale} 内容应为对象`);
      return value;
    } catch (error) {
      errors[key] ||= error instanceof Error ? error.message : 'JSON 格式异常';
      return {};
    }
  };

  const rowsLocale = (key: 'stats' | 'craft', locale: 'zh' | 'en', fields: readonly string[]) => {
    try {
      const value = readAdminI18nLocale<unknown>(byKey.get(key), locale);
      if (value === null) return [];
      if (!Array.isArray(value)) throw new Error(`${locale} 内容应为列表`);
      return value.map((item, index) => {
        if (!isRecord(item) || fields.some((field) => typeof item[field] !== 'string')) {
          throw new Error(`${locale} 第 ${index + 1} 项缺少 ${fields.join(' / ')}`);
        }
        return Object.fromEntries(fields.map((field) => [field, item[field] as string]));
      });
    } catch (error) {
      errors[key] ||= error instanceof Error ? error.message : 'JSON 格式异常';
      return [];
    }
  };

  const joinLocale = (locale: 'zh' | 'en') => {
    const value = objectLocale('join', locale);
    const advantages = value.advantages;
    if (advantages !== undefined && (!Array.isArray(advantages) || advantages.some((item) => typeof item !== 'string'))) {
      errors.join ||= `${locale} advantages 应为文字列表`;
    }
    return {
      ...stringFields(value),
      advantages: Array.isArray(advantages) ? advantages.filter((item): item is string => typeof item === 'string') : [],
    };
  };

  const initial: SiteSettingsInitial = {
    hero: { zh: stringFields(objectLocale('hero', 'zh')), en: stringFields(objectLocale('hero', 'en')) },
    contact: { zh: stringFields(objectLocale('contact', 'zh')), en: stringFields(objectLocale('contact', 'en')) },
    about: { zh: stringFields(objectLocale('about', 'zh')), en: stringFields(objectLocale('about', 'en')) },
    stats: { zh: rowsLocale('stats', 'zh', ['value', 'label']), en: rowsLocale('stats', 'en', ['value', 'label']) },
    craft: { zh: rowsLocale('craft', 'zh', ['title', 'desc']), en: rowsLocale('craft', 'en', ['title', 'desc']) },
    join: { zh: joinLocale('zh'), en: joinLocale('en') },
    capabilities: { zh: stringFields(objectLocale('capabilities', 'zh')), en: stringFields(objectLocale('capabilities', 'en')) },
    partners: { zh: stringFields(objectLocale('partners', 'zh')), en: stringFields(objectLocale('partners', 'en')) },
    resources: { zh: stringFields(objectLocale('resources', 'zh')), en: stringFields(objectLocale('resources', 'en')) },
    careers: { zh: stringFields(objectLocale('careers', 'zh')), en: stringFields(objectLocale('careers', 'en')) },
    footer: { zh: stringFields(objectLocale('footer', 'zh')), en: stringFields(objectLocale('footer', 'en')) },
  };

  const saved = Array.isArray(query.saved) ? query.saved[0] : query.saved;
  const setting = Array.isArray(query.setting) ? query.setting[0] : query.setting;
  const error = Array.isArray(query.error) ? query.error[0] : query.error;
  const feedback = isSettingKey(saved)
    ? { key: saved, kind: 'success' as const, message: '已保存并刷新公开页面缓存' }
    : isSettingKey(setting) && error
      ? {
          key: setting,
          kind: 'error' as const,
          message: (error === 'unknown-setting' ? '未知的站点设置类型' : error).slice(0, 600),
        }
      : undefined;

  return <SiteSettingsForm initial={initial} errors={errors} feedback={feedback} />;
}
