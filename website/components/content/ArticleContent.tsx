import React from 'react';
import { parseNewsContent } from '@/lib/news-content';

/** Shared CMS article rendering. Content remains React text, never raw HTML. */
export function ArticleContent({ text, title, emptyLabel }: { text?: string; title?: string; emptyLabel: string }) {
  const blocks = parseNewsContent(text, title);
  if (!blocks.length) return <p className="text-muted-foreground">{emptyLabel}</p>;
  return <div className="space-y-7 text-base leading-8 text-foreground/86 md:text-lg md:leading-9">
    {blocks.map((block, index) => {
      if (block.type === 'heading') return <h2 key={`${index}-${block.text.slice(0, 18)}`} className="pt-4 text-2xl font-semibold leading-tight tracking-[-.025em] text-foreground first:pt-0 md:text-3xl">{block.text}</h2>;
      if (block.type === 'list') return <ul key={`${index}-${block.items[0]?.slice(0, 18)}`} className="list-disc space-y-3 ps-6 marker:text-accent">
        {block.items.map((item, itemIndex) => <li key={`${itemIndex}-${item.slice(0, 18)}`} className="ps-1">{item}</li>)}
      </ul>;
      return <p key={`${index}-${block.text.slice(0, 18)}`}>{block.text}</p>;
    })}
  </div>;
}
