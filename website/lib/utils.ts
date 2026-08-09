import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function slugify(s: string): string {
  return s
    .toString()
    .trim()
    .toLowerCase()
    .replace(/[\s_]+/g, '-')
    .replace(/[^\w-]+/g, '')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80) || `item-${Math.random().toString(36).slice(2, 8)}`;
}

export function formatDate(d: Date | string, locale = 'zh'): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  const dateLocales: Record<string, string> = {
    zh: 'zh-CN', en: 'en', es: 'es', fr: 'fr', de: 'de',
    pt: 'pt', ar: 'ar', ru: 'ru', ja: 'ja', ko: 'ko',
  };
  return new Intl.DateTimeFormat(dateLocales[locale] || 'en', {
    year: 'numeric', month: 'long', day: 'numeric',
  }).format(date);
}

export function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n).trimEnd() + '…' : s;
}
