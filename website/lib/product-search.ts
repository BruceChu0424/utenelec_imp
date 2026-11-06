import { Prisma } from '@prisma/client';
import { PRODUCT_FUNCTION_TYPES } from './product-taxonomy';
import { literalSearchPattern, searchTerms } from './text-search';

type SearchDatabase = { $queryRaw<T>(query: Prisma.Sql): Promise<T> };
export type ProductSearchScope = {
  query: string;
  seriesIds?: string[];
  publicOnly?: boolean;
  studio?: boolean;
  internal?: boolean;
  locale?: string;
  functionType?: string | null;
  gangCount?: number | null;
  review?: string;
};

/** Fixed identifiers, bound values and explicit ESCAPE work in SQLite and PostgreSQL.
 * Public callers resolve the allowed series through publicSeriesWhere first and
 * hydrate page IDs through the existing publication guard; no broad ID list. */
function searchSql(scope: ProductSearchScope) {
  const terms = searchTerms(scope.query, scope.internal ? 120 : 80);
  const postgres = Boolean(process.env.DATABASE_URL?.startsWith('postgres'));
  const locale = scope.locale || 'zh';
  const name = (column: Prisma.Sql) => {
    // Match display names, never JSON keys or editorial fields. Malformed
    // imported JSON remains non-searchable, as in the existing display reader.
    const json = postgres ? Prisma.sql`CASE WHEN pg_input_is_valid(COALESCE(${column},''),'jsonb') THEN ${column}::jsonb ELSE '{}'::jsonb END`
      : Prisma.sql`CASE WHEN json_valid(${column}) THEN ${column} ELSE '{}' END`;
    const field = (language: string) => postgres ? Prisma.sql`jsonb_extract_path_text(${json},${language},'name')`
      : Prisma.sql`json_extract(${json},${`$."${language.replace(/[^a-zA-Z0-9-]/g, '')}".name`})`;
    const first = postgres ? Prisma.sql`(SELECT value->>'name' FROM jsonb_each(CASE WHEN jsonb_typeof(${json})='object' THEN ${json} ELSE '{}'::jsonb END) LIMIT 1)`
      : Prisma.sql`(SELECT CASE WHEN type='object' THEN json_extract(value,'$.name') END FROM json_each(${json}) LIMIT 1)`;
    return Prisma.sql`COALESCE(NULLIF(${field(locale)},''),${locale === 'zh' ? Prisma.empty : Prisma.sql`NULLIF(${field('en')},''),`}NULLIF(${field('zh')},''),${first},'')`;
  };
  const columns = [scope.publicOnly ? Prisma.sql`CASE WHEN p."classificationStatus"='VERIFIED' THEN p."model" END` : Prisma.sql`p."model"`, name(Prisma.sql`p."i18n"`)];
  if (scope.internal) columns.push(Prisma.sql`p."slug"`, Prisma.sql`p."category"`);
  if (scope.studio) columns.push(name(Prisma.sql`s."i18n"`));
  const match = (column: Prisma.Sql, pattern: string) => Prisma.sql`LOWER(COALESCE(${column}, '')) LIKE ${pattern} ESCAPE '\\'`;
  const variantWhere = Prisma.sql`v."productId"=p."id" ${scope.publicOnly ? Prisma.sql`AND v."published"=true` : Prisma.empty}
    ${scope.studio ? Prisma.sql`AND v."image" IS NOT NULL` : Prisma.empty}`;
  const matches = (pattern: string) => Prisma.sql`(${Prisma.join(columns.map(column => match(column, pattern)), ' OR ')}
    OR EXISTS (SELECT 1 FROM "ProductVariant" v WHERE ${variantWhere}
      AND (${scope.publicOnly ? Prisma.sql`false` : match(Prisma.sql`v."sku"`, pattern)} OR ${match(name(Prisma.sql`v."i18n"`), pattern)})))`;
  const base = [Prisma.sql`true`];
  if (scope.seriesIds) base.push(scope.seriesIds.length ? Prisma.sql`p."seriesId" IN (${Prisma.join(scope.seriesIds)})` : Prisma.sql`false`);
  if (scope.publicOnly) base.push(Prisma.sql`p."published"=true`);
  if (scope.studio) base.push(Prisma.sql`p."sceneEnabled"=true AND EXISTS (SELECT 1 FROM "ProductVariant" v WHERE ${variantWhere})`);
  const searched = [...base, ...terms.map(term => matches(`%${literalSearchPattern(term)}%`))];
  const selected = [...searched];
  if (scope.functionType === 'other') selected.push(Prisma.sql`(p."functionType" IS NULL OR p."functionType" NOT IN (${Prisma.join(PRODUCT_FUNCTION_TYPES.filter(value => value !== 'other'))}))`);
  else if (scope.functionType) selected.push(Prisma.sql`p."functionType"=${scope.functionType}`);
  if (scope.gangCount) selected.push(Prisma.sql`p."gangCount"=${scope.gangCount}`);
  if (scope.review) selected.push(Prisma.sql`p."classificationStatus"=${scope.review}`);
  const phrase = literalSearchPattern(terms.join(' '));
  return {
    from: Prisma.sql`FROM "Product" p LEFT JOIN "Series" s ON s."id"=p."seriesId"`,
    searched: Prisma.join(searched, ' AND '), selected: Prisma.join(selected, ' AND '),
    rank: terms.length ? Prisma.sql`CASE WHEN ${matches(phrase)} THEN 0 WHEN ${matches(`${phrase}%`)} THEN 1 ELSE 2 END` : Prisma.sql`0`,
  };
}

async function orderedProductSearchIds(db: SearchDatabase, scope: ProductSearchScope, bounds?: { skip: number; take: number }): Promise<string[]> {
  const sql = searchSql(scope);
  const rows = await db.$queryRaw<Array<{ id: string }>>(Prisma.sql`SELECT p."id" ${sql.from} WHERE ${sql.selected}
    ORDER BY ${scope.internal ? Prisma.sql`p."featured" DESC,` : Prisma.empty} ${sql.rank}, p."sortOrder" ASC,
      ${scope.internal ? Prisma.empty : Prisma.sql`p."createdAt" DESC,`} p."id" ASC
      ${bounds ? Prisma.sql`LIMIT ${bounds.take} OFFSET ${bounds.skip}` : Prisma.empty}`);
  return rows.map(row => row.id);
}

/** Existing public/card pagination remains bounded. */
export function productSearchIds(db: SearchDatabase, scope: ProductSearchScope, skip: number, take: number): Promise<string[]> {
  return orderedProductSearchIds(db, scope, { skip, take });
}

/** Only for an owner already returning every authorized matching summary.
 * Rank these lightweight matching identities once in the caller's snapshot;
 * hydrate at most100 IDs per query. This never expands the authorized scope. */
export function completeProductSearchIds(db: SearchDatabase, scope: ProductSearchScope): Promise<string[]> {
  return orderedProductSearchIds(db, scope);
}

export async function productSearchPage(db: SearchDatabase, scope: ProductSearchScope, skip: number, take: number, facets = false) {
  const sql = searchSql(scope);
  const [rows, counts, groups] = await Promise.all([
    productSearchIds(db, scope, skip, take),
    db.$queryRaw<Array<{ total: bigint | number }>>(Prisma.sql`SELECT COUNT(*) AS total ${sql.from} WHERE ${sql.selected}`),
    facets ? db.$queryRaw<Array<{ functionType: string | null; gangCount: number | null; total: bigint | number }>>(
      Prisma.sql`SELECT p."functionType", p."gangCount", COUNT(*) AS total ${sql.from} WHERE ${sql.searched} GROUP BY p."functionType",p."gangCount"`) : Promise.resolve([]),
  ]);
  return { ids: rows, total: Number(counts[0].total),
    groups: groups.map(row => ({ functionType: row.functionType, gangCount: row.gangCount, _count: { _all: Number(row.total) } })) };
}

export function orderSearchPage<T extends { id: string }>(rows: T[], ids: string[]): T[] {
  const byId = new Map(rows.map(row => [row.id, row]));
  return ids.flatMap(id => { const row = byId.get(id); return row ? [row] : []; });
}
