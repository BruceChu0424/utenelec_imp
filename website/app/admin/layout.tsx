import '@/app/globals.css';
import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: { default: '优腾官网管理后台', template: '%s · 优腾管理后台' },
  robots: { index: false, follow: false },
};

export default function AdminRootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh" suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
