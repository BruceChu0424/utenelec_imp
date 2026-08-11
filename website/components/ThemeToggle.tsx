'use client';
import { useEffect, useState } from 'react';
import { Moon, Sun } from 'lucide-react';
import { useTranslations } from 'next-intl';

export function ThemeToggle() {
  const [dark, setDark] = useState(false);
  const t = useTranslations('Theme');
  useEffect(() => {
    setDark(document.documentElement.classList.contains('dark'));
  }, []);
  const toggle = () => {
    const next = !dark;
    setDark(next);
    document.documentElement.classList.toggle('dark', next);
    try { localStorage.setItem('theme', next ? 'dark' : 'light'); } catch {}
  };
  return (
    <button onClick={toggle} aria-label={t('toggle')}
      className="inline-flex h-9 w-9 items-center justify-center rounded-lg text-foreground/70 transition hover:bg-muted hover:text-foreground cursor-pointer">
      {dark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
    </button>
  );
}

// 内联到 <head>, 默认深色(Cinema Dark), 用户选 light 才切浅色, 避免闪烁 (FOUC)
export const themeInitScript = `(function(){try{var t=localStorage.getItem('theme');if(t!=='light')document.documentElement.classList.add('dark');}catch(e){document.documentElement.classList.add('dark');}})();`;
