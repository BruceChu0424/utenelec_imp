/* eslint-disable @next/next/no-img-element */
import Link from 'next/link';
import { Plus } from 'lucide-react';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteScenePreset } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';

export default async function ScenesAdminPage() {
  const scenes = await prisma.scenePreset.findMany({
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
  });

  return (
    <div>
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">Scene presets</p>
          <h1 className="mt-1 font-heading text-2xl font-bold">场景试装</h1>
          <p className="mt-1 text-sm text-muted-foreground">管理墙面背景、默认产品款式与初始安装位置。</p>
        </div>
        <Link href="/admin/scenes/edit" className="btn-accent btn-sm min-h-11">
          <Plus className="h-4 w-4" />新增场景
        </Link>
      </div>

      {scenes.length ? (
        <div className="mt-6 card-uten overflow-x-auto">
          <table className="w-full min-w-[760px] text-sm">
            <thead className="bg-muted text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="p-3">背景</th>
                <th className="p-3">名称</th>
                <th className="p-3">网址标识</th>
                <th className="p-3">排序</th>
                <th className="p-3">状态</th>
                <th className="p-3 text-right">操作</th>
              </tr>
            </thead>
            <tbody>
              {scenes.map((scene) => {
                const content = tr<{ name?: string; description?: string }>(scene.i18n, 'zh');
                return (
                  <tr key={scene.id} className="border-t border-border align-middle hover:bg-muted/30">
                    <td className="p-3">
                      <img src={scene.backgroundImage} alt={content.name || '场景背景'} className="h-16 w-24 rounded-lg border border-border object-cover" />
                    </td>
                    <td className="max-w-xs p-3">
                      <p className="font-medium">{content.name || '未命名场景'}</p>
                      {content.description && <p className="mt-1 line-clamp-2 text-xs leading-relaxed text-muted-foreground">{content.description}</p>}
                    </td>
                    <td className="p-3 font-mono text-xs text-accent">{scene.slug}</td>
                    <td className="p-3 tabular-nums text-muted-foreground">{scene.sortOrder}</td>
                    <td className="p-3">
                      <span className={scene.published ? 'text-accent' : 'text-muted-foreground'}>{scene.published ? '已发布' : '未发布'}</span>
                    </td>
                    <td className="whitespace-nowrap p-3 text-right">
                      <Link href={`/admin/scenes/edit/${scene.id}`} className="inline-flex min-h-11 items-center text-accent hover:underline">编辑</Link>
                      <span className="mx-2 text-border">|</span>
                      <DeleteButton action={deleteScenePreset.bind(null, scene.id)} confirmText="确认删除这个场景预设？此操作不可恢复。" />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="mt-6 card-uten flex min-h-52 flex-col items-center justify-center p-8 text-center">
          <p className="font-medium">还没有场景预设</p>
          <p className="mt-1 text-sm text-muted-foreground">先创建一张墙面背景，再配置默认产品款式与安装位置。</p>
          <Link href="/admin/scenes/edit" className="btn-accent btn-sm mt-5 min-h-11">创建第一个场景</Link>
        </div>
      )}
    </div>
  );
}
