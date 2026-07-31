'use client';
import { useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { logout } from '@/app/admin/actions';
import {
  LayoutDashboard, Package, FolderTree, Newspaper, Building2,
  Briefcase, Inbox, Settings, LogOut, Menu, ExternalLink,
} from 'lucide-react';

const NAV = [
  { href: '/admin', label: '仪表盘', icon: LayoutDashboard },
  { href: '/admin/products', label: '产品管理', icon: Package },
  { href: '/admin/series', label: '产品系列', icon: FolderTree },
  { href: '/admin/news', label: '新闻资讯', icon: Newspaper },
  { href: '/admin/cases', label: '样板工程', icon: Building2 },
  { href: '/admin/jobs', label: '人才招聘', icon: Briefcase },
  { href: '/admin/inquiries', label: '客户留言', icon: Inbox },
  { href: '/admin/settings', label: '站点设置', icon: Settings },
];

export function AdminShell({ user, children }: { user: { username: string }; children: React.ReactNode }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const isActive = (h: string) => (h === '/admin' ? pathname === '/admin' : pathname.startsWith(h));

  return (
    <div className="min-h-screen bg-muted/30">
      <aside className={`fixed inset-y-0 left-0 z-40 w-60 bg-primary text-primary-foreground transition-transform lg:translate-x-0 ${open ? 'translate-x-0' : '-translate-x-full'}`}>
        <div className="flex h-16 items-center gap-2 border-b border-primary-foreground/10 px-5">
          <span className="grid h-8 w-8 place-items-center rounded-lg bg-accent font-heading font-bold text-accent-foreground">U</span>
          <span className="font-heading font-bold">优腾后台</span>
        </div>
        <nav className="p-3">
          {NAV.map((n) => (
            <Link key={n.href} href={n.href} onClick={() => setOpen(false)}
              className={`mb-1 flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm transition ${isActive(n.href) ? 'bg-accent font-medium text-accent-foreground' : 'text-primary-foreground/70 hover:bg-primary-foreground/10'}`}>
              <n.icon className="h-4 w-4" />{n.label}
            </Link>
          ))}
        </nav>
        <div className="absolute inset-x-0 bottom-0 space-y-1 border-t border-primary-foreground/10 p-3">
          <Link href="/" target="_blank" className="flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-primary-foreground/70 hover:bg-primary-foreground/10">
            <ExternalLink className="h-4 w-4" />查看前台
          </Link>
          <form action={logout}>
            <button type="submit" className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-sm text-primary-foreground/70 hover:bg-primary-foreground/10">
              <LogOut className="h-4 w-4" />退出登录
            </button>
          </form>
        </div>
      </aside>

      {open && <div className="fixed inset-0 z-30 bg-black/40 lg:hidden" onClick={() => setOpen(false)} />}

      <div className="lg:pl-60">
        <header className="sticky top-0 z-20 flex h-16 items-center justify-between border-b border-border bg-card/80 px-4 backdrop-blur lg:px-8">
          <button onClick={() => setOpen((o) => !o)} className="cursor-pointer lg:hidden" aria-label="菜单">
            <Menu className="h-5 w-5" />
          </button>
          <p className="text-sm text-muted-foreground">欢迎回来，<span className="font-medium text-foreground">{user.username}</span></p>
        </header>
        <main className="p-4 lg:p-8">{children}</main>
      </div>
    </div>
  );
}
