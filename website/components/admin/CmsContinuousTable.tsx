import type { ReactNode } from 'react';

/** Native table keeps every row action/focus mounted during continuous scrolling. */
export function CmsContinuousTable({ children, className, rowCount }: { children: ReactNode; className?: string; rowCount: number }) {
  return <table className={className} aria-rowcount={rowCount + 1} data-cms-continuous="true">{children}</table>;
}
