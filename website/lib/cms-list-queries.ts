import type { Prisma, PrismaClient } from '@prisma/client';
import { PRODUCT_FUNCTION_TYPES } from './product-taxonomy';
import { completeProductSearchIds, orderSearchPage } from './product-search';
import { cmsCaptionJson, completeCmsRows, readCmsSnapshot } from './cms-read';

const cursorPage=(afterId:string|undefined,take:number)=>({take,...(afterId?{cursor:{id:afterId},skip:1}:{})});

export type CmsProductScope = { q: string; seriesId: string; functionType: string; review: string };
export async function readCmsProducts(db: PrismaClient, scope: CmsProductScope) {
  const { q, seriesId, functionType, review } = scope;
  const where: Prisma.ProductWhereInput = {
    ...(seriesId ? { seriesId } : {}),
    ...(functionType === 'other' ? { OR: [{ functionType: null }, { functionType: { notIn: PRODUCT_FUNCTION_TYPES.filter(value => value !== 'other') } }] }
      : functionType ? { functionType } : {}),
    ...(review ? { classificationStatus: review } : {}),
  };
  const searchedScope = { query: q, internal: true, seriesIds: seriesId ? [seriesId] : undefined, functionType, review };
  return readCmsSnapshot(db, async tx => {
    const searchKeys=q?await completeProductSearchIds(tx,searchedScope):null;
    const products = await completeCmsRows({
      count: () => searchKeys ? Promise.resolve(searchKeys.length) : tx.product.count({ where }),
      readBatch: async (skip, take, afterId) => {
        const ids=searchKeys?searchKeys.slice(skip,skip+take):null;
        const rows = await tx.product.findMany({
          where: ids ? { AND: [where, { id: { in: ids } }] } : where,
          orderBy: [{ featured: 'desc' }, { sortOrder: 'asc' }, { id: 'asc' }], ...(ids?{take}:cursorPage(afterId,take)),
          select: { id: true, i18n: true, image: true, model: true, functionType: true, classificationStatus: true, published: true, sceneEnabled: true,
            series: { select: { i18n: true } },
            variants: { where: { image: { not: null } }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }, { id: 'asc' }], take: 1, select: { image: true } } },
        });
        const counts=await tx.productVariant.groupBy({by:['productId'],where:{productId:{in:rows.map(row=>row.id)}},_count:{_all:true}});
        const variantsByProduct=new Map(counts.map(row=>[row.productId,row._count._all]));
        return (ids ? orderSearchPage(rows, ids) : rows).map(row => ({ ...row, _count:{variants:variantsByProduct.get(row.id)??0}, i18n: cmsCaptionJson(row.i18n, ['name']),
          series: row.series ? { i18n: cmsCaptionJson(row.series.i18n, ['name']) } : null }));
      },
    });
    const seriesOptions = await completeCmsRows({ count: () => tx.series.count(),
      readBatch: async (_skip, take, afterId) => (await tx.series.findMany({ orderBy: [{ sortOrder: 'asc' }, { code: 'asc' }, { id: 'asc' }], ...cursorPage(afterId,take), select: { id: true, code: true, i18n: true } }))
        .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['name']) })),
    });
    return { products, total: products.length, seriesOptions };
  });
}

export const readCmsCases = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.caseItem.count(),
  readBatch: async (_skip, take, afterId) => (await tx.caseItem.findMany({ orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }], ...cursorPage(afterId,take), select: { id: true, i18n: true } }))
    .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['title', 'location']) })),
}));
export const readCmsJobs = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.job.count(),
  readBatch: async (_skip, take, afterId) => (await tx.job.findMany({ orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }], ...cursorPage(afterId,take), select: { id: true, i18n: true, department: true, location: true } }))
    .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['title']) })),
}));
export const readCmsNews = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.news.count(),
  readBatch: async (_skip, take, afterId) => (await tx.news.findMany({ orderBy: [{ publishedAt: 'desc' }, { id: 'asc' }], ...cursorPage(afterId,take), select: { id: true, i18n: true, category: true, publishedAt: true } }))
    .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['title']) })),
}));
export const readCmsSeries = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.series.count(),
  readBatch: async (_skip, take, afterId) => {
    const rows=await tx.series.findMany({ orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }], ...cursorPage(afterId,take),
      select: { id: true, code: true, publicSlug: true, catalogRole: true, published: true, rowVersion: true, i18n: true } });
    const ids=rows.map(row=>row.id);
    const products=await tx.product.groupBy({by:['seriesId'],where:{seriesId:{in:ids}},_count:{_all:true}});
    const media=await tx.seriesMedia.groupBy({by:['seriesId'],where:{seriesId:{in:ids}},_count:{_all:true}});
    const productCounts=new Map(products.map(row=>[row.seriesId,row._count._all]));
    const mediaCounts=new Map(media.map(row=>[row.seriesId,row._count._all]));
    return rows.map(row => ({ ...row, _count:{products:productCounts.get(row.id)??0,media:mediaCounts.get(row.id)??0},i18n: cmsCaptionJson(row.i18n, ['name']) }));
  },
}));
export const readCmsScenes = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.scenePreset.count(),
  readBatch: async (_skip, take, afterId) => (await tx.scenePreset.findMany({ orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }], ...cursorPage(afterId,take),
    select: { id: true, slug: true, i18n: true, backgroundImage: true, sortOrder: true, published: true } }))
    .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['name', 'description']) })),
}));
export const readCmsResources = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.resourceDocument.count(),
  readBatch: async (_skip, take, afterId) => (await tx.resourceDocument.findMany({ orderBy: [{ updatedAt: 'desc' }, { id: 'asc' }], ...cursorPage(afterId,take),
    select: { id: true, slug: true, i18n: true, language: true, version: true, published: true, asset: { select: { originalName: true } } } }))
    .map(row => ({ ...row, i18n: cmsCaptionJson(row.i18n, ['title']) })),
}));
export const readCmsInquiries = (db: PrismaClient) => readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.inquiry.count(),
  readBatch: (_skip, take, afterId) => tx.inquiry.findMany({ orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], ...cursorPage(afterId,take),
    select: { id: true, name: true, company: true, email: true, phone: true, message: true, createdAt: true, productInterest: true,
      delivery: { select: { state: true, erpInquiryId: true } } } }),
}));
export function readCmsReleases(db: PrismaClient, allowed: readonly string[], status?: string) {
  if (!allowed.length) return Promise.resolve([]);
  const where = { entityType: { in: [...allowed] }, ...(status ? { status } : {}) };
  return readCmsSnapshot(db, tx => completeCmsRows({ count: () => tx.cmsRevision.count({ where }),
    readBatch: (_skip, take, afterId) => tx.cmsRevision.findMany({ where, orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], ...cursorPage(afterId,take),
      select: { id: true, title: true, operation: true, entityType: true, status: true, createdAt: true } }),
  }));
}
export function readCmsMedia(db: PrismaClient, archive: boolean) {
  return readCmsSnapshot(db, tx => archive
    ? completeCmsRows({ count: () => tx.legacyMediaAsset.count({ where: { publicPath: { not: null } } }),
      readBatch: async (_skip, take, afterId) => (await tx.legacyMediaAsset.findMany({ where: { publicPath: { not: null } }, orderBy: { id: 'asc' }, ...cursorPage(afterId,take),
        select: { id: true, publicPath: true, bytes: true } })).map(row => ({ id: row.id, publicPath: row.publicPath!, sizeBytes: row.bytes })),
    })
    : completeCmsRows({ count: () => tx.websiteMediaObject.count({ where: { state: 'COMMITTED' } }),
      readBatch: async (_skip, take, afterId) => (await tx.websiteMediaObject.findMany({ where: { state: 'COMMITTED' }, orderBy: [{ createdAt: 'desc' }, { publicPath: 'asc' }], take,...(afterId?{cursor:{publicPath:afterId},skip:1}:{}),
        select: { publicPath: true, sizeBytes: true } })).map(row => ({ ...row, id: row.publicPath })),
    }));
}
