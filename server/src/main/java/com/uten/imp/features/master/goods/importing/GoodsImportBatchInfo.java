package com.uten.imp.features.master.goods.importing;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 最近一次未撤回的导入批次摘要（撤回按钮入口用：展示「最近导入 N 条 / 时间」供确认）。
 */
public record GoodsImportBatchInfo(UUID id, OffsetDateTime createdAt, String filename, int rowCount) {}
