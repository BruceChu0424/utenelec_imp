import { PrismaClient } from '@prisma/client';
import { PrismaClient as PostgresqlClient } from '../generated/postgresql';

const globalForPrisma = globalThis as unknown as { prisma?: PrismaClient };

export const prisma =
  globalForPrisma.prisma ??
  (process.env.DATABASE_URL?.startsWith('postgres') ? new PostgresqlClient({
    log: process.env.NODE_ENV === 'development' ? ['error', 'warn'] : ['error'],
  }) as unknown as PrismaClient : new PrismaClient({
    log: process.env.NODE_ENV === 'development' ? ['error', 'warn'] : ['error'],
  }));

if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma;
