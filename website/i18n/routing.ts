import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  // 默认提供中英双语; 结构支持随时扩展更多语言 (外贸)
  // 扩展示例: 加入 'es','pt','ar','fr','ru','de' 后在 messages/ 增加对应 json 即可
  locales: ['zh', 'en'],
  defaultLocale: 'zh',
  localePrefix: 'always',
});

export type Locale = (typeof routing.locales)[number];
