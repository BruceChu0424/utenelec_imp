import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

const localized = (zh: Record<string, unknown>, en: Record<string, unknown>) => JSON.stringify({ zh, en });

async function main() {
  const products = await prisma.product.findMany({ include: { variants: true, series: true } });
  let variantsCreated = 0;

  for (const product of products) {
    if (!product.variants.length && product.image) {
      await prisma.productVariant.create({
        data: {
          productId: product.id,
          i18n: localized({ name: '标准款' }, { name: 'Standard' }),
          image: product.image,
          sortOrder: 0,
          published: true,
        },
      });
      variantsCreated += 1;
    }

    const canPreviewOnWall = product.image && product.series?.code !== 'floor-socket';
    if (canPreviewOnWall && !product.sceneEnabled) {
      await prisma.product.update({ where: { id: product.id }, data: { sceneEnabled: true } });
    }
  }

  const scenes = [
    {
      slug: 'warm-plaster',
      backgroundImage: '/images/scenes/warm-plaster.webp',
      sortOrder: 10,
      i18n: localized(
        { name: '暖调客厅', description: '暖色矿物涂料与柔和自然光' },
        { name: 'Warm living', description: 'Warm mineral plaster and soft daylight' },
      ),
    },
    {
      slug: 'mineral-gallery',
      backgroundImage: '/images/scenes/mineral-gallery.webp',
      sortOrder: 20,
      i18n: localized(
        { name: '矿物灰空间', description: '克制的微水泥与冷调光线' },
        { name: 'Mineral gallery', description: 'Restrained microcement and cool daylight' },
      ),
    },
    {
      slug: 'walnut-suite',
      backgroundImage: '/images/scenes/walnut-suite.webp',
      sortOrder: 30,
      i18n: localized(
        { name: '胡桃木套房', description: '深色木饰面与暖调间接光' },
        { name: 'Walnut suite', description: 'Dark walnut and warm indirect light' },
      ),
    },
  ];

  for (const scene of scenes) {
    await prisma.scenePreset.upsert({
      where: { slug: scene.slug },
      update: {
        i18n: scene.i18n,
        backgroundImage: scene.backgroundImage,
        sortOrder: scene.sortOrder,
      },
      create: {
        ...scene,
        config: JSON.stringify({ schemaVersion: 1, placement: { x: 52, y: 47, scale: 1, rotation: 0 } }),
        published: true,
      },
    });
  }

  console.log(`Website v2 backfill complete: ${variantsCreated} default variants created, ${scenes.length} scenes upserted.`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => prisma.$disconnect());
