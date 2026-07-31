import { createNavigation } from 'next-intl/navigation';
import { routing } from './routing';

// next-intl 3.22+ 标准导航 API: Link/usePathname/useRouter 自动处理 locale 前缀
export const { Link, redirect, usePathname, useRouter, getPathname } = createNavigation(routing);
