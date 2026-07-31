'use client';
import { useState, useTransition, type FormEvent } from 'react';
import { login } from '@/app/admin/actions';

export default function LoginPage() {
  const [pending, start] = useTransition();
  const [err, setErr] = useState('');
  const onSubmit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setErr('');
    const fd = new FormData(e.currentTarget);
    start(async () => {
      const r = await login(fd);
      if (r && r.error) setErr(r.error);
    });
  };
  return (
    <div className="grid min-h-screen place-items-center bg-primary p-4">
      <form onSubmit={onSubmit} className="w-full max-w-sm rounded-2xl bg-card p-8 shadow-2xl">
        <div className="mb-6 flex flex-col items-center">
          <span className="grid h-12 w-12 place-items-center rounded-xl bg-accent font-heading text-xl font-bold text-accent-foreground">U</span>
          <h1 className="mt-3 font-heading text-xl font-bold">优腾官网管理后台</h1>
          <p className="text-sm text-muted-foreground">Uten Website Admin</p>
        </div>
        {err && <div className="mb-4 rounded-lg bg-destructive/10 px-3 py-2 text-sm text-destructive">{err}</div>}
        <label className="label-uten">用户名</label>
        <input name="username" required autoFocus className="input-uten mb-3" placeholder="admin" />
        <label className="label-uten">密码</label>
        <input name="password" type="password" required className="input-uten mb-5" placeholder="••••••" />
        <button type="submit" disabled={pending} className="btn-accent w-full">
          {pending ? '登录中…' : '登录'}
        </button>
      </form>
    </div>
  );
}
