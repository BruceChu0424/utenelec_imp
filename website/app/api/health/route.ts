import { constants } from 'node:fs';
import { access } from 'node:fs/promises';
import { NextResponse } from 'next/server';
import { prisma } from '@/lib/db';
import { assertUploadsDirectoryReady } from '@/lib/upload-storage';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

const noStoreHeaders = {
  'Cache-Control': 'no-store, max-age=0',
};

export async function GET() {
  try {
    const [schemaRows, migrationRows] = await Promise.all([
      prisma.$queryRaw<Array<{ name: string }>>`
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name IN ('Series', 'Product', 'Setting', 'User', 'Inquiry', '_prisma_migrations')
      `,
      prisma.$queryRaw<Array<{ migration_name: string; finished_at: Date | null; rolled_back_at: Date | null }>>`
        SELECT migration_name, finished_at, rolled_back_at
        FROM _prisma_migrations
        ORDER BY migration_name
      `,
      access('/var/lib/uten-website/runtime/website.db', constants.R_OK | constants.W_OK),
      assertUploadsDirectoryReady(),
    ]);
    const requiredTables = new Set(['Series', 'Product', 'Setting', 'User', 'Inquiry', '_prisma_migrations']);
    for (const row of schemaRows) requiredTables.delete(row.name);
    if (requiredTables.size > 0) throw new Error('required website schema is incomplete');
    const baseline = migrationRows.find(
      (row) => row.migration_name === '20260812000000_initial_production_baseline',
    );
    if (!baseline?.finished_at || baseline.rolled_back_at) {
      throw new Error('required website Prisma baseline is not successfully applied');
    }
    if (migrationRows.some((row) => !row.finished_at && !row.rolled_back_at)) {
      throw new Error('website has an incomplete Prisma migration');
    }

    return NextResponse.json(
      { status: 'ok' },
      { status: 200, headers: noStoreHeaders },
    );
  } catch {
    // Keep the public probe deliberately opaque: monitoring needs a binary
    // readiness signal, not database paths or internal exception details.
    return NextResponse.json(
      { status: 'unavailable' },
      { status: 503, headers: noStoreHeaders },
    );
  }
}
