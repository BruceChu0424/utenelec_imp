import { redirect } from 'next/navigation';
import { getSession, hasCmsPermission } from '@/lib/auth';
import { AdminShell } from '@/components/admin/AdminShell';

export default async function ProtectedLayout({ children }: { children: React.ReactNode }) {
  const session = await getSession();
  if (!session || !hasCmsPermission(session, 'website:view')) redirect('/admin/login');
  return <AdminShell user={session}>{children}</AdminShell>;
}
