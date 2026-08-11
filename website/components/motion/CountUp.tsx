'use client';
import { useEffect, useRef, useState } from 'react';

/**
 * 数字滚动计数（进入视口触发）。value 支持前后缀，如 "25+"、"$20"。
 * 非数字 value（如 "全球"、"高新技术"）原样显示。
 */
export function CountUp({ value, duration = 1800 }: { value: string; duration?: number }) {
  const match = value.match(/^(\D*)(\d+(?:\.\d+)?)(.*)$/);
  const [, prefix = '', numStr = '', suffix = ''] = match || [];
  const target = numStr ? parseFloat(numStr) : NaN;

  const [n, setN] = useState(0);
  const ref = useRef<HTMLSpanElement>(null);
  const started = useRef(false);

  useEffect(() => {
    if (Number.isNaN(target)) return;
    const el = ref.current;
    if (!el) return;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce || typeof IntersectionObserver === 'undefined') { setN(target); return; }
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting && !started.current) {
          started.current = true;
          const start = performance.now();
          const tick = (now: number) => {
            const p = Math.min((now - start) / duration, 1);
            const eased = 1 - Math.pow(1 - p, 3);
            setN(target * eased);
            if (p < 1) requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
          io.disconnect();
        }
      });
    }, { threshold: 0.4 });
    io.observe(el);
    return () => io.disconnect();
  }, [target, duration]);

  if (Number.isNaN(target)) return <span ref={ref}>{value}</span>;
  const display = Number.isInteger(target) ? Math.round(n) : n.toFixed(1);
  return <span ref={ref}>{prefix}{display}{suffix}</span>;
}
