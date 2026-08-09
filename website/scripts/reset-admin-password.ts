import { loadEnvConfig } from '@next/env';
import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';
import { requireStrongAdminSeedPassword } from '../lib/admin-security';

loadEnvConfig(process.cwd());

const prisma = new PrismaClient();

async function main() {
  const username = process.env.ADMIN_USERNAME?.trim();
  if (!username) throw new Error('ADMIN_USERNAME 未配置；未修改任何账号');
  const password = requireStrongAdminSeedPassword(process.env.ADMIN_PASSWORD);

  const result = await prisma.user.updateMany({
    where: { username },
    data: { password: await bcrypt.hash(password, 12) },
  });
  if (result.count !== 1) {
    throw new Error('未找到唯一的 ADMIN_USERNAME 对应账号；未创建新账号');
  }

  console.log(`✓ 管理员密码已安全轮换: ${username}`);
}

main()
  .catch((error) => {
    console.error(error instanceof Error ? error.message : '管理员密码轮换失败');
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
