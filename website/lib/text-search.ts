/** Deliberately literal search: every distinct word must match a visible field. */
export function searchTerms(query: string | undefined, limit = 120): string[] {
  return [...new Set((query || '').normalize('NFKC').trim().slice(0, limit).toLowerCase().split(/\s+/u).filter(Boolean))];
}

export function literalSearchPattern(value: string): string {
  return value.replace(/[\\%_]/g, '\\$&');
}

export function textSearchRank(fields: Array<string | null | undefined>, terms: string[]): number {
  if (!terms.length) return 0;
  const values = fields.map(value => (value || '').normalize('NFKC').toLowerCase());
  if (!terms.every(term => values.some(value => value.includes(term)))) return -1;
  const phrase = terms.join(' ');
  return values.some(value => value === phrase) ? 0 : values.some(value => value.startsWith(phrase)) ? 1 : 2;
}
