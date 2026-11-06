import { Prisma, type PrismaClient } from '@prisma/client';
import { tr } from './content';

export const CMS_READ_BATCH_SIZE = 100;

/** One fresh database snapshot, with no cross-request data cache. */
export function readCmsSnapshot<T>(db: PrismaClient, read: (tx: Prisma.TransactionClient) => Promise<T>): Promise<T> {
  return db.$transaction(read, { isolationLevel: Prisma.TransactionIsolationLevel.Serializable, maxWait: 5_000, timeout: 60_000 });
}

/** Current authorized scope is applied by the caller before count and each batch. */
export async function completeCmsRows<T extends { id: string }>({ count, readBatch }: {
  count: () => Promise<number>;
  readBatch: (skip: number, take: number, afterId: string | undefined) => Promise<T[]>;
}): Promise<T[]> {
  const total = await count();
  if (!Number.isSafeInteger(total) || total < 0) throw new Error('资料总数无效，请刷新后重试');
  const rows: T[] = [], identities = new Set<string>();
  let afterId: string | undefined;
  for (let skip = 0; skip < total; skip += CMS_READ_BATCH_SIZE) {
    const batch = await readBatch(skip, CMS_READ_BATCH_SIZE, afterId);
    if (batch.length !== Math.min(CMS_READ_BATCH_SIZE, total - skip)) throw new Error('资料在读取期间已变化，请刷新后重新读取完整结果');
    for (const row of batch) {
      const id = row.id;
      if (!id || identities.has(id)) throw new Error('资料身份缺失或重复，请刷新后重新读取完整结果');
      identities.add(id); rows.push(row);
    }
    afterId = batch.at(-1)?.id;
  }
  return rows;
}

/** Only list captions survive the summary read; original editable JSON stays in the database. */
export function cmsCaptionJson(value: string, fields: readonly string[]): string {
  const localized = tr<Record<string, unknown>>(value, 'zh');
  return JSON.stringify({ zh: Object.fromEntries(fields.filter(key => localized[key] !== undefined).map(key => [key, localized[key]])) });
}
