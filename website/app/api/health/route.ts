import { access } from 'node:fs/promises';
import path from 'node:path';
import { NextResponse } from 'next/server';
import { prisma } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

const noStoreHeaders = {
  'Cache-Control': 'no-store, max-age=0',
};

export async function GET() {
  try {
    await Promise.all([
      prisma.$queryRaw`SELECT 1`,
      access(path.join(process.cwd(), 'public', 'uploads')),
    ]);

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
