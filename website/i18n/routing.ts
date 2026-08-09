import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  // 覆盖主要全球市场；内容缺失时由 lib/content.ts 逐字段回退英文/中文。
  locales: ['zh', 'en', 'es', 'fr', 'de', 'pt', 'ar', 'ru', 'ja', 'ko'],
  // 不受支持的浏览器语言回退英语；中文浏览器仍会自动命中 zh。
  defaultLocale: 'en',
  localePrefix: 'always',
  localeDetection: true,
  // Explicit locale prefixes preserve manual choices without a response cookie,
  // so public HTML remains cacheable at the CDN/edge. The bare root still uses
  // Accept-Language detection before redirecting to the matching locale.
  localeCookie: false,
});

export type Locale = (typeof routing.locales)[number];
