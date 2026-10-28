'use client';
import { useEffect, useRef, useState } from 'react';
import { Building2, ShieldCheck } from 'lucide-react';

export function ImpEntry() {
  const entry = useRef<{ code: string; verifier: string } | null>(null);
  const [person, setPerson] = useState('');
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  useEffect(() => {
    const hash = new URLSearchParams(window.location.hash.slice(1));
    const code = hash.get('code'), verifier = hash.get('verifier');
    // React strict-effects replay must not discard the already captured entry.
    if (!entry.current && code && verifier) entry.current = { code, verifier };
    // Keep the router's navigation state: replacing it with null can remount
    // this page after the fragment was cleared, losing the one-use credentials.
    window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
    if (!entry.current) { setError('入口已失效。请返回 IMP 工作台重新打开官网管理。'); return; }
    let active = true;
    fetch('/api/imp/entry/inspect', { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(entry.current), cache: 'no-store', credentials: 'same-origin' })
      .then(async response => {
        if (!response.ok) throw new Error();
        const value = await response.json(); if (active) setPerson(value.displayName);
      }).catch(() => { if (active) setError('登录授权已过期或无法验证。请返回 IMP 重新进入。'); });
    return () => { active = false; };
  }, []);
  async function enter() {
    if (pending || !entry.current || !person) return;
    setPending(true); setError('');
    try {
      const response = await fetch('/api/imp/entry/consume', { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(entry.current), credentials: 'same-origin', cache: 'no-store' });
      if (!response.ok) throw new Error();
      const { destination } = await response.json();
      if (typeof destination !== 'string' || !/^\/admin(?:\/[^/]|\?|$)/.test(destination) || destination.includes('\\')) throw new Error();
      entry.current = null; window.location.replace(destination);
    } catch { setError('这次授权未能完成。请返回 IMP 重新打开，已保存的官网内容不受影响。'); setPending(false); }
  }
  return <main className="min-h-screen bg-background-elevated px-5 py-16">
    <section className="mx-auto max-w-lg rounded-xl border border-border bg-card p-8 sm:p-12">
      <Building2 className="mb-7 h-9 w-9 text-accent" />
      <h1 className="text-3xl font-semibold tracking-tight">进入官网管理</h1>
      <p className="mt-4 text-sm leading-7 text-muted-foreground">请确认当前员工身份。官网管理权限由 IMP 提供，内容保存和发布都会留下操作记录。</p>
      {person && <div className="my-7 flex items-center gap-3 border-y border-border py-5"><ShieldCheck className="h-5 w-5 text-accent" /><span>当前员工：<strong>{person}</strong></span></div>}
      {!person && !error && <p className="my-7 text-sm" role="status">正在验证员工授权…</p>}
      {error && <p className="my-6 text-sm text-destructive" role="alert">{error}</p>}
      <button type="button" onClick={enter} disabled={!person || pending || !!error} className="btn-accent mt-6 w-full">{pending ? '正在进入…' : '确认身份并进入'}</button>
      <p className="mt-5 text-xs leading-6 text-muted-foreground">若显示的身份不是你，请关闭此页并回到 IMP 切换账号。该入口短时有效，使用一次后失效。</p>
    </section>
  </main>;
}
