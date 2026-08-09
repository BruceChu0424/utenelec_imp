import { articleParagraphs, cleanLegacyArticleText, pickLocale } from './content';

export const NEWS_CATEGORIES = ['company', 'industry', 'guide'] as const;

export type NewsCategory = (typeof NEWS_CATEGORIES)[number];

export type LocalizedNewsContent = {
  title?: string;
  summary?: string;
  content?: string;
};

export type DirectNewsContent = LocalizedNewsContent & {
  title: string;
  content: string;
};

export type NewsContentBlock =
  | { type: 'heading'; text: string }
  | { type: 'paragraph'; text: string }
  | { type: 'list'; items: string[] };

export function isNewsCategory(value: string): value is NewsCategory {
  return (NEWS_CATEGORIES as readonly string[]).includes(value);
}

/**
 * Return only content authored for the requested locale. Public indexes use
 * this to avoid presenting a Chinese legacy story as if it were translated.
 */
export function getDirectNewsContent(
  i18n: string | null | undefined,
  locale: string,
): DirectNewsContent | null {
  const direct = pickLocale<LocalizedNewsContent>(i18n, locale);
  if (!direct?.title?.trim() || !direct.content?.trim()) return null;
  return { ...direct, title: direct.title, content: direct.content };
}

/**
 * Parse the small, intentionally limited article syntax supported by the CMS.
 * The renderer emits React text nodes only; this parser never accepts HTML.
 */
export function parseNewsContent(
  text: string | null | undefined,
  title?: string,
): NewsContentBlock[] {
  const cleaned = cleanLegacyArticleText(text, title);
  if (!cleaned) return [];

  const hasStructuredSyntax = /(^|\n)\s*(?:##\s+|-\s+)/u.test(cleaned);
  const hasParagraphBreaks = /\n\s*\n/u.test(cleaned);
  if (!hasStructuredSyntax && !hasParagraphBreaks) {
    return articleParagraphs(cleaned, title).map((paragraph) => ({
      type: 'paragraph' as const,
      text: paragraph,
    }));
  }

  const blocks: NewsContentBlock[] = [];
  let paragraphLines: string[] = [];
  let listItems: string[] = [];

  const flushParagraph = () => {
    const paragraph = paragraphLines.join(' ').trim();
    if (paragraph) blocks.push({ type: 'paragraph', text: paragraph });
    paragraphLines = [];
  };
  const flushList = () => {
    if (listItems.length) blocks.push({ type: 'list', items: listItems });
    listItems = [];
  };

  for (const rawLine of cleaned.split('\n')) {
    const line = rawLine.trim();
    if (!line) {
      flushParagraph();
      flushList();
      continue;
    }

    const heading = line.match(/^##\s+(.+)$/u);
    if (heading) {
      flushParagraph();
      flushList();
      blocks.push({ type: 'heading', text: heading[1].trim() });
      continue;
    }

    const listItem = line.match(/^-\s+(.+)$/u);
    if (listItem) {
      flushParagraph();
      listItems.push(listItem[1].trim());
      continue;
    }

    flushList();
    paragraphLines.push(line);
  }

  flushParagraph();
  flushList();
  return blocks;
}
