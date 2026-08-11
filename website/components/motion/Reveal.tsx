import type { CSSProperties, ReactNode } from 'react';
import { cn } from '@/lib/utils';

/**
 * 渐进增强的一次性进入动画。HTML 默认可见；没有 JavaScript、打印和
 * 长页面截图都不会因 IntersectionObserver 尚未触发而丢失内容。
 */
export function Reveal({
  children, className, delay = 0, y = 24,
}: {
  children: ReactNode; className?: string; delay?: number; y?: number;
}) {
  return (
    <div
      className={cn('animate-reveal', className)}
      style={{ '--reveal-y': `${y}px`, animationDelay: `${delay}ms` } as CSSProperties}
    >
      {children}
    </div>
  );
}
