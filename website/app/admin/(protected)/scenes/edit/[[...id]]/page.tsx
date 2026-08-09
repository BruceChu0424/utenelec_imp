import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { STUDIO_DEFAULT_PLACEMENT, normalizeStudioPlacement } from '@/lib/studio-config';
import { SceneForm, type ScenePlacement } from './SceneForm';

function parseSceneConfig(config: string | null): { defaultVariantId: string; placement: ScenePlacement } {
  const fallback = { defaultVariantId: '', placement: { ...STUDIO_DEFAULT_PLACEMENT } };
  if (!config) return fallback;
  try {
    const parsed = JSON.parse(config) as {
      defaultVariantId?: unknown;
      placement?: { x?: unknown; y?: unknown; scale?: unknown; rotation?: unknown };
    };
    return {
      defaultVariantId: typeof parsed.defaultVariantId === 'string' ? parsed.defaultVariantId : '',
      placement: normalizeStudioPlacement(parsed.placement),
    };
  } catch {
    return fallback;
  }
}

export default async function SceneEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const [scene, variants] = await Promise.all([
    id ? prisma.scenePreset.findUnique({ where: { id } }) : Promise.resolve(null),
    prisma.productVariant.findMany({
      where: { published: true, image: { not: null }, product: { sceneEnabled: true, published: true } },
      include: { product: true },
      orderBy: [{ productId: 'asc' }, { sortOrder: 'asc' }],
    }),
  ]);
  if (id && !scene) notFound();

  const variantOptions = variants.map((variant) => ({
    id: variant.id,
    label: `${tr<{ name?: string }>(variant.product.i18n, 'zh').name || '未命名产品'} · ${tr<{ name?: string }>(variant.i18n, 'zh').name || '未命名款式'}`,
    image: variant.image || '',
  }));
  const parsedConfig = parseSceneConfig(scene?.config || null);
  const config = { ...parsedConfig, defaultVariantId: scene?.defaultVariantId || parsedConfig.defaultVariantId };

  return <SceneForm scene={scene} variants={variantOptions} config={config} />;
}
