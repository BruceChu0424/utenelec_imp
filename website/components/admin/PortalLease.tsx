'use client';
import { useEffect, useState } from 'react';
export function PortalLease() {
  const [expired, setExpired] = useState(false);
  useEffect(() => {
    let active = true, inFlight = false;
    const refresh = async () => {
      if (inFlight) return; inFlight = true;
      try {
        const response = await fetch('/api/imp/session/refresh', { method: 'POST', credentials: 'same-origin', cache: 'no-store' });
        if (active) setExpired(!response.ok);
      } catch { if (active) setExpired(true); } finally { inFlight = false; }
    };
    const interval = setInterval(refresh, 60_000); window.addEventListener('focus', refresh);
    return () => { active = false; clearInterval(interval); window.removeEventListener('focus', refresh); };
  }, []);
  if (!expired) return null;
  return <div role="alert" className="border-b border-amber-200 bg-amber-50 px-6 py-3 text-sm text-amber-900">暂时无法续期 IMP 授权。请先保留正在编辑的内容，连接恢复后重试；若授权已过期，请从 IMP 工作台重新进入。服务端会阻止未授权的保存和发布。</div>;
}
